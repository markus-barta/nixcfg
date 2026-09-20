"""Synthetic-only recovery boundary tests; never read a real credential file."""

import contextlib
import importlib.util
import io
import json
import tempfile
import threading
import tomllib
import unittest
import urllib.parse
import urllib.request
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "consent", Path(__file__).parents[1] / "scripts/mailbridge-consent.py"
)
consent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(consent)
CLIENT = {
    "installed": {
        "project_id": "mailbridge-barta",
        "client_id": "fixture",
        "client_secret": "synthetic-secret",
    }
}
CONFIG = (
    "# preserve this comment\nSecrets = "
    + json.dumps(json.dumps(CLIENT))
    + "\nTokens = '''{\"refresh_token\":\"old-fixture\"}'''\n"
    + '[[Imap]]\nAddress = "mail.hover.com:993"\nPassword = "synthetic-password"\n'
).encode()


class ConsentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "config.toml"
        self.path.write_bytes(CONFIG)
        self.path.chmod(0o600)

    def recovery(self):
        recovery = consent.Recovery(self.path, CONFIG)
        recovery.origin = "http://127.0.0.1:1234"
        return recovery

    def test_only_root_tokens_change_and_comment_survives(self):
        updated = consent.replace_tokens(CONFIG, {"refresh_token": 'new"\\fixture'})
        before, after = tomllib.loads(CONFIG.decode()), tomllib.loads(updated.decode())
        self.assertEqual(before["Secrets"], after["Secrets"])
        self.assertEqual(before["Imap"], after["Imap"])
        self.assertTrue(updated.startswith(b"# preserve this comment"))
        self.assertEqual(
            json.loads(after["Tokens"]), {"refresh_token": 'new"\\fixture'}
        )

    def test_ambiguous_token_assignment_rejected(self):
        for source in (
            CONFIG.replace(b"Tokens =", b"Other ="),
            CONFIG + b'\nTokens = "nested"\n',
        ):
            with self.assertRaises(ValueError):
                consent.replace_tokens(source, {})

    def test_private_file_rejects_world_readable_or_symlink(self):
        self.path.chmod(0o644)
        with self.assertRaises(ValueError):
            consent.private_file(self.path)
        self.path.chmod(0o600)
        link = self.path.with_name("alias")
        link.symlink_to(self.path)
        with self.assertRaises(ValueError):
            consent.private_file(link)

    def test_authorization_is_scoped_offline_with_pkce(self):
        recovery = self.recovery()
        url = urllib.parse.urlsplit(recovery.auth_url())
        query = urllib.parse.parse_qs(url.query)
        self.assertEqual(url.netloc, "accounts.google.com")
        self.assertEqual(query["scope"], [consent.SCOPE])
        self.assertEqual(query["access_type"], ["offline"])
        self.assertEqual(query["code_challenge_method"], ["S256"])
        self.assertNotIn(recovery.verifier, recovery.auth_url())
        self.assertNotIn("synthetic-secret", recovery.auth_url())

    def test_wrong_duplicate_missing_state_never_exchanges(self):
        recovery = self.recovery()
        with patch.object(consent, "exchange") as exchange:
            for query in (
                "code=canary",
                "state=wrong&code=canary",
                "state=" + recovery.state + "&state=wrong&code=canary",
            ):
                self.assertFalse(recovery.callback(query))
            exchange.assert_not_called()
        self.assertFalse(recovery.finished)
        self.assertEqual(self.path.read_bytes(), CONFIG)

    def test_denial_or_provider_error_never_printed_or_written(self):
        for query, error in (
            ("error=CANARY", None),
            ("code=CANARY", RuntimeError("SECRET_CANARY")),
        ):
            recovery = self.recovery()
            output = io.StringIO()
            with (
                patch.object(consent, "exchange", side_effect=error),
                contextlib.redirect_stdout(output),
                contextlib.redirect_stderr(output),
            ):
                self.assertTrue(
                    recovery.callback("state=" + recovery.state + "&" + query)
                )
            self.assertFalse(recovery.success)
            self.assertEqual(output.getvalue(), "")
            self.assertEqual(self.path.read_bytes(), CONFIG)

    def test_success_private_backup_and_callback_replay(self):
        recovery = self.recovery()
        token = {"refresh_token": "new-fixture"}
        with patch.object(consent, "exchange", return_value=token) as exchange:
            query = "state=" + recovery.state + "&code=synthetic"
            self.assertTrue(recovery.callback(query))
            self.assertFalse(recovery.callback(query))
            exchange.assert_called_once()
        self.assertTrue(recovery.success)
        self.assertTrue(recovery.issued_at.endswith("Z"))
        self.assertEqual(
            json.loads(tomllib.loads(self.path.read_text())["Tokens"]), token
        )
        backups = list(self.path.parent.glob("*.before-oauth-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), CONFIG)
        self.assertEqual(self.path.stat().st_mode & 0o077, 0)
        self.assertEqual(backups[0].stat().st_mode & 0o077, 0)

    def test_concurrent_change_preserved(self):
        self.path.write_bytes(CONFIG + b"# changed\n")
        with self.assertRaises(ValueError):
            consent.save(self.path, CONFIG, {}, "2026-09-20T15:00:00Z")
        self.assertTrue(self.path.read_bytes().endswith(b"# changed\n"))

    def test_exchange_rejects_missing_refresh_broader_scope_and_oversize(self):
        good = {
            "access_token": "fixture",
            "refresh_token": "fixture",
            "token_type": "Bearer",
            "scope": consent.SCOPE,
            "expires_in": 3600,
        }

        class Response:
            status = 200

            def __init__(self, raw):
                self.raw = raw

            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def read(self, limit):
                return self.raw[:limit]

        for value in (
            dict(good, refresh_token=""),
            dict(good, scope=consent.SCOPE + " extra"),
            dict(good, expires_in=-1),
        ):
            with patch.object(consent.urllib.request, "build_opener") as opener:
                opener.return_value.open.return_value = Response(
                    json.dumps(value).encode()
                )
                with self.assertRaises(ValueError):
                    consent.exchange(
                        CLIENT["installed"],
                        "code",
                        "verifier",
                        "http://127.0.0.1:1/callback",
                    )
        with patch.object(consent.urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value = Response(json.dumps(good).encode())
            result = consent.exchange(
                CLIENT["installed"], "code", "verifier", "http://127.0.0.1:1/callback"
            )
            self.assertEqual(
                set(result), {"access_token", "refresh_token", "token_type", "expiry"}
            )
            request = opener.return_value.open.call_args.args[0]
            self.assertEqual(request.full_url, consent.TOKEN_URL)
            self.assertEqual(
                urllib.parse.parse_qs(request.data.decode())["code_verifier"],
                ["verifier"],
            )
            opener.return_value.open.return_value = Response(b"x" * (consent.LIMIT + 1))
            with self.assertRaises(ValueError):
                consent.exchange(
                    CLIENT["installed"],
                    "code",
                    "verifier",
                    "http://127.0.0.1:1/callback",
                )

    def test_loopback_listener_rejects_wrong_host_and_does_not_log_query(self):
        recovery = self.recovery()
        output = io.StringIO()
        with consent.CallbackServer(
            ("127.0.0.1", 0), consent.handler(recovery)
        ) as server:
            recovery.origin = "http://127.0.0.1:" + str(server.server_port)
            with contextlib.redirect_stderr(output):
                for request in (
                    urllib.request.Request(
                        recovery.origin, headers={"Host": "evil.example"}
                    ),
                    urllib.request.Request(
                        recovery.origin + "/oauth2callback?code=CANARY&state=wrong"
                    ),
                ):
                    thread = threading.Thread(target=server.handle_request)
                    thread.start()
                    with self.assertRaises(urllib.error.HTTPError) as error:
                        urllib.request.urlopen(request, timeout=3)
                    self.assertEqual(error.exception.code, 400)
                    thread.join(3)
        self.assertNotIn("CANARY", output.getvalue())
        self.assertFalse(recovery.finished)


if __name__ == "__main__":
    unittest.main()
