"""HOSTD-59 delivery contracts; no real mail, broker, or chat calls."""
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('notification_delivery', ROOT / 'modules/ib-gateway-session/notification_delivery.py')
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)


class DeliveryTests(unittest.TestCase):
    def test_managed_mail_uses_stdin_and_stable_message_identity(self):
        send = delivery.email_sender({'from': 'monitor@example.invalid', 'to': 'operator@example.invalid'}, '/bin/docker')
        with mock.patch.object(delivery.subprocess, 'run', return_value=mock.Mock(returncode=0)) as run:
            self.assertTrue(send('Paper Gateway needs attention. Test only.', 'event123'))
        args, kwargs = run.call_args
        self.assertEqual(args[0][:6], ['/bin/docker', 'exec', '-i', 'docker-smtp-1', '/usr/sbin/sendmail', '-i'])
        self.assertIn(b'Message-ID: <hostd59-event123@example.invalid>', kwargs['input'])
        self.assertNotIn('Paper Gateway', ' '.join(args[0]))
        self.assertEqual(kwargs['timeout'], 20)

    def test_email_rejects_header_injection_and_other_container(self):
        for config in [
            {'from': 'a@example.invalid\nBcc: b@example.invalid', 'to': 'b@example.invalid'},
            {'from': 'a@example.invalid', 'to': 'b@example.invalid', 'relay_container': 'ib-gateway'},
        ]:
            with self.assertRaises(ValueError):
                delivery.email_sender(config, '/bin/docker')

    def test_private_config_refuses_permissions_symlinks_and_hardlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config.json'
            path.write_text('{"schema_version":1}')
            path.chmod(0o600)
            self.assertEqual(delivery.private_config(str(path))['schema_version'], 1)
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                delivery.private_config(str(path))
            path.chmod(0o600)
            link = Path(directory) / 'link'
            link.symlink_to(path)
            with self.assertRaises(OSError):
                delivery.private_config(str(link))
            hard = Path(directory) / 'hard'
            os.link(path, hard)
            with self.assertRaises(ValueError):
                delivery.private_config(str(path))

    def test_grok_posts_only_to_existing_paimos_target(self):
        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory) / 'ppm-key'
            key.write_text('test-fixture-not-a-real-credential')
            key.chmod(0o600)
            send = delivery.grok_sender({'project_id': 17, 'to': 'grok_bot:amy'}, str(key))
            response = mock.MagicMock()
            response.__enter__.return_value = response
            response.status = 201
            response.read.return_value = b'{"message_id":"fixture-message"}'
            opener = mock.Mock()
            status_response = mock.MagicMock()
            status_response.__enter__.return_value = status_response
            status_response.read.return_value = json.dumps({'deliveries': [{
                'message_id': 'fixture-message', 'address': 'grok_bot:amy',
                'state': 'handed_off', 'effective_level': 'simple',
                'handed_off_at': '2026-09-12T17:00:00Z',
                'effective_target_id': '4f73e08c-f98d-4dfd-a86c-6a9393f05db4',
                'effective_target_version': 1,
            }]}).encode()
            opener.open.side_effect = [response, status_response]
            with mock.patch.object(delivery.urllib.request, 'build_opener', return_value=opener):
                self.assertTrue(send('CONTROLLED TEST. Paper Gateway recovered.', 'event123'))
            request = opener.open.call_args_list[0].args[0]
            self.assertEqual(request.full_url, 'https://pm.barta.cm/api/v2/projects/17/messages')
            self.assertEqual(request.get_header('Idempotency-key'), 'hostd59-event123')
            body = json.loads(request.data)
            self.assertEqual(body['to'], 'grok_bot:amy')
            self.assertEqual(body['delivery_level'], 'simple')
            self.assertIn('SendToUser', body['body'])
            self.assertNotIn('issue_id', body)
            self.assertNotIn(key.read_text(), body['body'])
        with self.assertRaises(ValueError):
            delivery.grok_sender({'project_id': 20, 'to': 'invented'}, '/none')

    def test_supervisor_waits_then_notifies_and_only_real_readiness_clears(self):
        import test_ib_gateway_session_supervisor as fixture
        sup = fixture.sup
        with tempfile.TemporaryDirectory() as directory:
            config = fixture.cfg(Path(directory), alert_enable=True, alert_transport="email-agent-bus")
            sent = {"email": [], "grok": []}
            senders = {name: (lambda text, event, name=name: sent[name].append((text, event)) or True) for name in sent}
            state = sup.SupervisorState(unhealthy_since=fixture.NOW, last_restart_at=fixture.NOW,
                                        restarts_this_outage=1, operator_clear_required=True)
            first, _ = sup.run_cycle(fixture.obs(now=fixture.NOW + 599), config, state,
                                    notification_senders=senders)
            self.assertEqual(sent["email"], [])
            second, _ = sup.run_cycle(fixture.obs(now=fixture.NOW + 600), config, first.persist,
                                     notification_senders=senders)
            self.assertEqual(len(sent["email"]), 1)
            self.assertEqual(len(sent["grok"]), 1)
            unknown, _ = sup.run_cycle(fixture.obs(now=fixture.NOW + 900, probe_unknown=True),
                                      config, second.persist, notification_senders=senders)
            self.assertEqual(len(sent["email"]), 1)
            sup.run_cycle(fixture.obs(now=fixture.NOW + 1200, api_listening=True,
                                     pusher=fixture.pusher(gateway=True, observed_at=fixture.NOW + 1200)),
                          config, unknown.persist, notification_senders=senders)
            self.assertEqual(len(sent["email"]), 2)
            self.assertIn("recovered", sent["email"][1][0])

    def test_redirect_is_not_followed_with_credential(self):
        self.assertIsNone(delivery.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://other.invalid'))


if __name__ == '__main__':
    unittest.main()
