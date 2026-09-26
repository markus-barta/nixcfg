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

    def test_grok_uses_bound_notifier_and_own_receipt_only(self):
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
            status_response.status = 200
            receipt = {
                'message_id': 'fixture-message', 'project_id': 17, 'address': 'grok_bot:amy',
                'state': 'handed_off', 'effective_level': 'simple',
                'handed_off_at': '2026-09-12T17:00:00Z',
                'effective_target_id': '4f73e08c-f98d-4dfd-a86c-6a9393f05db4',
                'effective_target_version': 1,
            }
            status_response.read.return_value = json.dumps(receipt).encode()
            opener.open.side_effect = [response, status_response]
            with mock.patch.object(delivery.urllib.request, 'build_opener', return_value=opener):
                self.assertTrue(send('CONTROLLED TEST. Paper Gateway recovered.', 'event123'))
            request = opener.open.call_args_list[0].args[0]
            self.assertEqual(request.full_url, 'https://pm.barta.cm/api/machine-notifier/messages')
            self.assertEqual(request.get_header('Idempotency-key'), 'hostd59-event123')
            self.assertEqual(request.get_header('User-agent'), delivery.USER_AGENT)
            self.assertEqual(opener.open.call_args_list[1].args[0].get_header('User-agent'), delivery.USER_AGENT)
            self.assertEqual(opener.open.call_args_list[1].args[0].full_url,
                             'https://pm.barta.cm/api/machine-notifier/messages/fixture-message/receipt')
            self.assertIsNone(request.get_header('X-paimos-agent-name'))
            self.assertIsNone(request.get_header('X-paimos-session-id'))
            body = json.loads(request.data)
            self.assertEqual(set(body), {'body'})
            self.assertIn('SendToUser', body['body'])
            self.assertNotIn('issue_id', body)
            self.assertNotIn(key.read_text(), body['body'])
            # A successful HTTP request is not delivery evidence for a different
            # message, project, recipient, target generation, or delivery level.
            for field, invalid in [
                ('message_id', 'another-message'), ('project_id', 20),
                ('address', 'another-receiver'), ('state', 'queued'),
                ('effective_level', 'control'), ('handed_off_at', ''),
                ('effective_target_id', 'another-target'), ('effective_target_version', 2),
                ('effective_target_version', True),
            ]:
                with self.subTest(field=field, invalid=invalid):
                    status_response.read.return_value = json.dumps({**receipt, field: invalid}).encode()
                    opener.open.side_effect = [response, status_response]
                    with mock.patch.object(delivery.urllib.request, 'build_opener', return_value=opener):
                        self.assertFalse(send('Paper Gateway needs attention.', 'event123'))

            opener.open.reset_mock()
            opener.open.side_effect = delivery.urllib.error.HTTPError(request.full_url, 401, 'Unauthorized', {}, None)
            with mock.patch.object(delivery.urllib.request, 'build_opener', return_value=opener):
                self.assertFalse(send('Paper Gateway needs attention.', 'event123'))
            self.assertEqual(opener.open.call_count, 1)  # no privileged legacy fallback

            with mock.patch.object(delivery.urllib.request, 'build_opener') as unused:
                self.assertFalse(send('Paper Gateway needs attention.', 'bad\r\nheader'))
                unused.assert_not_called()
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

    def test_declared_senders_skips_unenrolled_key_with_one_notice(self):
        config = {
            'schema_version': 1,
            'email': {'from': 'monitor@example.invalid', 'to': 'operator@example.invalid'},
            'grok': {'project_id': 17, 'to': 'grok_bot:amy'},
        }
        with tempfile.TemporaryDirectory() as directory:
            for key in (Path(directory) / 'not-enrolled', Path(directory) / 'missing-parent' / 'key'):
                with self.subTest(key=key.name), \
                        mock.patch.object(delivery, 'private_config', return_value=config), \
                        mock.patch('builtins.print') as notice:
                    senders = delivery.declared_senders('config.json', '/bin/docker', str(key))
                    self.assertEqual(set(senders), {'email'})
                    notice.assert_called_once_with(
                        'grok notification not enrolled: PAI-1018 key absent, chat channel skipped')

    def test_declared_senders_keeps_channel_for_directory_and_symlink(self):
        config = {
            'schema_version': 1,
            'email': {'from': 'monitor@example.invalid', 'to': 'operator@example.invalid'},
            'grok': {'project_id': 17, 'to': 'grok_bot:amy'},
        }
        with tempfile.TemporaryDirectory() as directory:
            regular = Path(directory) / 'empty-fixture'
            regular.touch()
            link = Path(directory) / 'link'
            link.symlink_to(regular)
            for key in (Path(directory), link):
                with self.subTest(key=key.name), \
                        mock.patch.object(delivery, 'private_config', return_value=config), \
                        mock.patch('builtins.print') as notice:
                    senders = delivery.declared_senders('config.json', '/bin/docker', str(key))
                    self.assertEqual(set(senders), {'email', 'grok'})
                    notice.assert_not_called()
                    if key == Path(directory):
                        with mock.patch.object(delivery.urllib.request, 'build_opener') as opener:
                            self.assertFalse(senders['grok']('Paper Gateway needs attention.', 'event123'))
                            opener.assert_not_called()

    def test_declared_senders_keeps_channel_when_key_metadata_is_unreadable(self):
        config = {
            'schema_version': 1,
            'email': {'from': 'monitor@example.invalid', 'to': 'operator@example.invalid'},
            'grok': {'project_id': 17, 'to': 'grok_bot:amy'},
        }
        with mock.patch.object(delivery, 'private_config', return_value=config), \
                mock.patch.object(delivery.os, 'lstat', side_effect=PermissionError), \
                mock.patch('builtins.print') as notice:
            senders = delivery.declared_senders('config.json', '/bin/docker', '/unreadable-key')
            self.assertEqual(set(senders), {'email', 'grok'})
            notice.assert_not_called()

    def test_declared_senders_enrolls_regular_key_without_reading_it(self):
        config = {
            'schema_version': 1,
            'email': {'from': 'monitor@example.invalid', 'to': 'operator@example.invalid'},
            'grok': {'project_id': 17, 'to': 'grok_bot:amy'},
        }
        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory) / 'empty-fixture'
            key.touch()
            with mock.patch.object(delivery, 'private_config', return_value=config), \
                    mock.patch.object(delivery.os, 'open', side_effect=AssertionError('key opened')) as opened, \
                    mock.patch('builtins.open', side_effect=AssertionError('key opened')) as builtin_opened, \
                    mock.patch('builtins.print') as notice:
                senders = delivery.declared_senders('config.json', '/bin/docker', str(key))
            self.assertEqual(set(senders), {'email', 'grok'})
            opened.assert_not_called()
            builtin_opened.assert_not_called()
            notice.assert_not_called()

    def test_declared_senders_keeps_invalid_grok_target_unavailable(self):
        config = {
            'schema_version': 1,
            'email': {'from': 'monitor@example.invalid', 'to': 'operator@example.invalid'},
            'grok': {'project_id': 20, 'to': 'invented'},
        }
        with mock.patch.object(delivery, 'private_config', return_value=config), \
                mock.patch.object(delivery.os, 'lstat') as metadata, \
                mock.patch('builtins.print') as notice:
            senders = delivery.declared_senders('config.json', '/bin/docker', '/not-enrolled')
            self.assertEqual(set(senders), {'email', 'grok'})
            notice.assert_not_called()
            self.assertFalse(senders['grok']('Paper Gateway needs attention.', 'event123'))
            notice.assert_called_once_with(
                'grok notification unavailable: configuration or receiver missing')
            metadata.assert_not_called()

    def test_email_only_notifications_ignore_pending_unenrolled_chat(self):
        import test_ib_gateway_notification_state as fixture
        notifications, engine = fixture.notification_state, fixture.engine
        with tempfile.TemporaryDirectory() as directory:
            state_directory = str(Path(directory) / 'alerts.channels')
            delivering_sender = mock.Mock(return_value=True)
            unavailable_sender = mock.Mock(return_value=False)
            problem = 'Paper Gateway needs attention.'
            now = 1_800_000_000.0
            self.assertEqual(notifications.run_notifications(
                state_directory, now, False, True, problem,
                {'email': delivering_sender, 'grok': unavailable_sender}), engine.EXIT_UNDELIVERED)
            chat_state = Path(state_directory) / 'grok' / 'state.json'
            pending_chat = chat_state.read_bytes()

            senders = {'email': delivering_sender}
            self.assertEqual(notifications.run_notifications(
                state_directory, now + 300, False, True, problem, senders), engine.EXIT_PROBLEMS)
            self.assertEqual(notifications.run_notifications(
                state_directory, now + 600, True, False, problem, senders), engine.EXIT_CLEAN)
            self.assertEqual(delivering_sender.call_count, 2)  # problem and recovery
            self.assertEqual(unavailable_sender.call_count, 1)
            self.assertEqual(chat_state.read_bytes(), pending_chat)

    def test_pending_notifier_enrollment_does_not_block_email(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'config.json'
            config.write_text(json.dumps({
                'schema_version': 1,
                'email': {'from': 'monitor@example.invalid', 'to': 'operator@example.invalid'},
                'grok': {'project_id': 17, 'to': 'grok_bot:amy'},
            }))
            config.chmod(0o600)
            senders = delivery.declared_senders(str(config), '/bin/docker', str(Path(directory) / 'not-enrolled'))
            with mock.patch.object(delivery.subprocess, 'run', return_value=mock.Mock(returncode=0)) as relay:
                self.assertTrue(senders['email']('Paper Gateway needs attention.', 'event123'))
            self.assertEqual(relay.call_count, 1)
            self.assertNotIn('grok', senders)


AEON_BINDING = {
    'backend': 'aeon', 'tenant': 'ppm',
    'recipient_principal_id': '11111111-1111-4111-8111-111111111111',
    'target_id': '22222222-2222-4222-8222-222222222222', 'target_version': 3,
    'adapter': 'grok_bot_routine', 'address': 'grok_bot:amy', 'effective_level': 'simple',
}
MESSAGE_ID = '33333333-3333-4333-8333-333333333333'
SENDER_ID = '44444444-4444-4444-8444-444444444444'


def _response(status, document):
    response = mock.MagicMock()
    response.__enter__.return_value = response
    response.status = status
    response.read.return_value = json.dumps(document).encode()
    return response


def _message(**override):
    return {'id': MESSAGE_ID, 'sender_principal_id': SENDER_ID,
            'recipient_principal_id': AEON_BINDING['recipient_principal_id'],
            'idempotency_key': 'hostd59-event123', 'body': 'x', **override}


def _receipt(**override):
    return {'message_id': MESSAGE_ID, 'idempotency_key': 'hostd59-event123', 'tenant': 'ppm',
            'sender_principal_id': SENDER_ID,
            'recipient_principal_id': AEON_BINDING['recipient_principal_id'],
            'target_id': AEON_BINDING['target_id'], 'target_version': 3,
            'adapter': 'grok_bot_routine', 'address': 'grok_bot:amy', 'effective_level': 'simple',
            'state': 'handed_off', 'handed_off_at': '2026-09-26T09:00:00Z', 'failure_reason': '',
            **override}


class AeonDeliveryTests(unittest.TestCase):
    """OPS-232: Aeon inbox + sender receipt; no real network calls."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.key = Path(self.directory.name) / 'aeon-key'
        self.key.write_text('test-fixture-not-a-real-credential')
        self.key.chmod(0o600)
        self.sleeps = []
        self.now = [0.0]

        def sleep(seconds):
            self.sleeps.append(seconds)
            self.now[0] += seconds
        self.send = delivery.aeon_sender(dict(AEON_BINDING), str(self.key), sleep=sleep,
                                         clock=lambda: self.now[0])

    def tearDown(self):
        self.directory.cleanup()

    def run_send(self, *responses):
        opener = mock.Mock()
        opener.open.side_effect = list(responses)
        with mock.patch.object(delivery.urllib.request, 'build_opener', return_value=opener), \
                mock.patch('builtins.print'):
            result = self.send('Paper Gateway needs attention.', 'event123')
        return result, opener

    def test_handed_off_after_queued_uses_fixed_origin_and_own_receipt(self):
        result, opener = self.run_send(_response(201, _message()),
                                       _response(200, _receipt(state='queued', handed_off_at=None)),
                                       _response(200, _receipt()))
        self.assertTrue(result)
        post = opener.open.call_args_list[0].args[0]
        self.assertEqual(post.full_url, 'https://aeon.barta.cm/api/inbox/messages')
        body = json.loads(post.data)
        self.assertEqual(set(body), {'recipient_principal_id', 'body', 'idempotency_key'})
        self.assertEqual(body['idempotency_key'], 'hostd59-event123')
        self.assertIn('SendToUser', body['body'])
        self.assertNotIn(self.key.read_text(), body['body'])
        for call in opener.open.call_args_list[1:]:
            self.assertEqual(call.args[0].full_url,
                             f'https://aeon.barta.cm/api/inbox/messages/{MESSAGE_ID}/receipt')
        self.assertNotIn('pm.barta.cm', ' '.join(c.args[0].full_url for c in opener.open.call_args_list))
        self.assertEqual(self.sleeps, [delivery.AEON_RECEIPT_POLL_SECONDS])

    def test_replay_of_same_key_returns_original_message(self):
        result, _ = self.run_send(_response(200, _message()), _response(200, _receipt()))
        self.assertTrue(result)

    def test_accepted_but_never_handed_off_is_not_delivery(self):
        queued = [_response(200, _receipt(state='queued', handed_off_at=None)) for _ in range(20)]
        result, opener = self.run_send(_response(201, _message()), *queued)
        self.assertFalse(result)
        self.assertLessEqual(sum(self.sleeps), delivery.AEON_RECEIPT_WAIT_SECONDS)
        self.assertLess(opener.open.call_count, 21)

    def test_failed_receipt_stops_without_echoing_reason(self):
        with mock.patch('builtins.print') as printed:
            opener = mock.Mock()
            opener.open.side_effect = [_response(201, _message()),
                                       _response(200, _receipt(state='failed', handed_off_at=None,
                                                               failure_reason='receiver-secret-detail'))]
            with mock.patch.object(delivery.urllib.request, 'build_opener', return_value=opener):
                self.assertFalse(self.send('Paper Gateway needs attention.', 'event123'))
        self.assertNotIn('receiver-secret-detail', str(printed.call_args_list))
        self.assertEqual(self.sleeps, [])

    def test_receipt_must_match_every_binding(self):
        for field, invalid in [
            ('message_id', '55555555-5555-4555-8555-555555555555'), ('idempotency_key', 'hostd59-other'),
            ('tenant', 'other'), ('sender_principal_id', '66666666-6666-4666-8666-666666666666'),
            ('recipient_principal_id', '77777777-7777-4777-8777-777777777777'),
            ('target_id', '88888888-8888-4888-8888-888888888888'),
            ('target_version', 2), ('target_version', True), ('target_version', '3'),
            ('adapter', 'other'), ('address', 'grok_bot:other'), ('effective_level', 'control'),
            ('handed_off_at', ''), ('handed_off_at', None),
        ]:
            with self.subTest(field=field, invalid=invalid):
                result, _ = self.run_send(_response(201, _message()), _response(200, _receipt(**{field: invalid})))
                self.assertFalse(result)

    def test_inbox_response_must_match_recipient_and_key(self):
        for override in [{'recipient_principal_id': '77777777-7777-4777-8777-777777777777'},
                         {'idempotency_key': 'hostd59-other'}, {'id': 'not-a-uuid'},
                         {'sender_principal_id': None}]:
            with self.subTest(override=override):
                result, opener = self.run_send(_response(201, _message(**override)))
                self.assertFalse(result)
                self.assertEqual(opener.open.call_count, 1)

    def test_old_key_refused_and_foreign_receipt_404_and_conflict(self):
        for code, calls in [(401, 1), (403, 1), (409, 1)]:
            with self.subTest(code=code):
                error = delivery.urllib.error.HTTPError('https://aeon.barta.cm', code, 'x', {}, None)
                result, opener = self.run_send(error)
                self.assertFalse(result)
                self.assertEqual(opener.open.call_count, calls)
        not_found = delivery.urllib.error.HTTPError('https://aeon.barta.cm', 404, 'x', {}, None)
        result, _ = self.run_send(_response(201, _message()), not_found)
        self.assertFalse(result)

    def test_binding_refusals(self):
        for override in [{'backend': 'classic'}, {'tenant': 'Bad Tenant'},
                         {'recipient_principal_id': 'grok_bot:amy'}, {'target_id': 'x'},
                         {'target_version': 0}, {'target_version': True}, {'adapter': ''},
                         {'origin': 'https://evil.invalid'}]:
            with self.subTest(override=override), self.assertRaises(ValueError):
                delivery.aeon_sender({**AEON_BINDING, **override}, str(self.key))
        missing = dict(AEON_BINDING)
        missing.pop('address')
        with self.assertRaises(ValueError):
            delivery.aeon_sender(missing, str(self.key))

    def test_declared_senders_selects_backend_from_private_binding(self):
        base = {'schema_version': 1, 'email': {'from': 'monitor@example.invalid', 'to': 'operator@example.invalid'}}
        with mock.patch.object(delivery, 'private_config', return_value={**base, 'grok': dict(AEON_BINDING)}), \
                mock.patch.object(delivery, 'aeon_sender', wraps=delivery.aeon_sender) as aeon, \
                mock.patch.object(delivery, 'grok_sender') as classic:
            senders = delivery.declared_senders('c.json', '/bin/docker', '/classic-key', str(self.key))
        self.assertEqual(set(senders), {'email', 'grok'})
        aeon.assert_called_once_with(AEON_BINDING, str(self.key))
        classic.assert_not_called()
        # Aeon selected but no Aeon key: chat is skipped, never sent with the classic key.
        with mock.patch.object(delivery, 'private_config', return_value={**base, 'grok': dict(AEON_BINDING)}), \
                mock.patch('builtins.print') as notice:
            senders = delivery.declared_senders('c.json', '/bin/docker', str(self.key), '')
        self.assertEqual(set(senders), {'email'})
        notice.assert_called_once_with('grok notification not enrolled: Aeon notifier key absent, chat channel skipped')
        # Classic binding stays on the classic path.
        with mock.patch.object(delivery, 'private_config',
                               return_value={**base, 'grok': {'project_id': 17, 'to': 'grok_bot:amy'}}), \
                mock.patch.object(delivery, 'aeon_sender') as aeon:
            senders = delivery.declared_senders('c.json', '/bin/docker', str(self.key), str(self.key))
        aeon.assert_not_called()
        self.assertEqual(set(senders), {'email', 'grok'})


if __name__ == '__main__':
    unittest.main()
