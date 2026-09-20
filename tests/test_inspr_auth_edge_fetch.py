#!/usr/bin/env python3
"""NIX-526: deterministic retry and fail-closed coverage for the T58 probe."""

import contextlib
import hashlib
import http.client
import importlib.util
import io
from pathlib import Path
import ssl
import unittest
from unittest.mock import Mock, call, patch
import urllib.error


SPEC = importlib.util.spec_from_file_location(
    "inspr_auth_edge", Path(__file__).with_name("T58-inspr-auth-edge.py")
)
EDGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EDGE)

SOURCE = "https://www.cloudflare.com/ips-v4"
IPV4 = b"192.0.2.0/24\n"
IPV6 = b"2001:db8::/32\n"


def response(payload=IPV4, *, read_error=None, status=200):
    result = Mock(status=status)
    result.read.return_value = payload
    result.read.side_effect = read_error
    manager = Mock()
    manager.__enter__ = Mock(return_value=result)
    manager.__exit__ = Mock(return_value=False)
    return manager


def contract():
    return {
        "source": {
            "ipv4": SOURCE,
            "ipv6": "https://www.cloudflare.com/ips-v6",
            "ipv4Sha256": hashlib.sha256(IPV4).hexdigest(),
            "ipv6Sha256": hashlib.sha256(IPV6).hexdigest(),
        },
        "cloudflareRanges": ["192.0.2.0/24", "2001:db8::/32"],
    }


class FetchTests(unittest.TestCase):
    def setUp(self):
        self.open = self.enterContext(patch.object(EDGE.urllib.request, "urlopen"))
        self.sleep = self.enterContext(patch.object(EDGE.time, "sleep"))
        self.diagnostics = self.enterContext(contextlib.redirect_stderr(io.StringIO()))

    def test_success_returns_original_bytes_without_retry(self):
        reply = response()
        self.open.return_value = reply
        self.assertEqual(EDGE.fetch(SOURCE), IPV4)
        self.open.assert_called_once()
        request = self.open.call_args.args[0]
        self.assertEqual(request.full_url, SOURCE)
        self.assertEqual(request.get_header("User-agent"), "nixcfg-NIX-400-drift-gate")
        self.assertEqual(self.open.call_args.kwargs, {"timeout": 10})
        reply.__exit__.assert_called_once()
        self.sleep.assert_not_called()
        self.assertEqual(self.diagnostics.getvalue(), "")

    def test_transient_transport_errors_recover(self):
        for error in (
            ConnectionResetError("reset"),
            ConnectionAbortedError("aborted"),
            TimeoutError("timeout"),
            urllib.error.URLError(ConnectionResetError("wrapped reset")),
            urllib.error.URLError("temporary DNS failure"),
        ):
            with self.subTest(error=type(error).__name__):
                self.open.reset_mock()
                self.sleep.reset_mock()
                self.open.side_effect = [error, response()]
                self.assertEqual(EDGE.fetch(SOURCE), IPV4)
                self.assertEqual(self.open.call_count, 2)
                self.sleep.assert_called_once_with(1)
        self.assertIn("retrying attempt 2/3 in 1s", self.diagnostics.getvalue())
        self.assertNotIn("temporary DNS failure", self.diagnostics.getvalue())

    def test_retryable_http_statuses_close_the_error_response(self):
        for status in (429, 500, 502, 503, 504, 599):
            with self.subTest(status=status):
                self.open.reset_mock()
                self.sleep.reset_mock()
                body = io.BytesIO(b"not needed")
                error = urllib.error.HTTPError(SOURCE, status, "failure", {}, body)
                self.open.side_effect = [error, response()]
                self.assertEqual(EDGE.fetch(SOURCE), IPV4)
                self.assertEqual(self.open.call_count, 2)
                self.sleep.assert_called_once_with(1)
                self.assertTrue(body.closed)
                self.assertIn(f"HTTP {status}", self.diagnostics.getvalue())

    def test_nonretryable_http_errors_fail_once(self):
        for status in (400, 401, 403, 404, 408):
            with self.subTest(status=status):
                self.open.reset_mock()
                body = io.BytesIO(b"not needed")
                error = urllib.error.HTTPError(SOURCE, status, "failure", {}, body)
                self.open.side_effect = [error, response()]
                with self.assertRaises(urllib.error.HTTPError) as raised:
                    EDGE.fetch(SOURCE)
                self.assertIs(raised.exception, error)
                self.open.assert_called_once()
                self.sleep.assert_not_called()
                self.assertTrue(body.closed)
        self.assertEqual(self.diagnostics.getvalue(), "")

    def test_exhausted_retries_propagate_the_final_failure(self):
        last = urllib.error.URLError("still unavailable")
        self.open.side_effect = [ConnectionResetError(), TimeoutError(), last, response()]
        with self.assertRaises(urllib.error.URLError) as raised:
            EDGE.fetch(SOURCE)
        self.assertIs(raised.exception, last)
        self.assertEqual(self.open.call_count, 3)
        self.assertEqual(self.sleep.call_args_list, [call(1), call(2)])
        self.assertEqual(len(self.diagnostics.getvalue().splitlines()), 2)
        self.assertIn("retrying attempt 3/3 in 2s", self.diagnostics.getvalue())

    def test_success_on_final_attempt_has_no_extra_delay(self):
        self.open.side_effect = [TimeoutError(), ConnectionResetError(), response()]
        self.assertEqual(EDGE.fetch(SOURCE), IPV4)
        self.assertEqual(self.open.call_count, 3)
        self.assertEqual(self.sleep.call_args_list, [call(1), call(2)])

    def test_read_failure_closes_response_and_refetches_whole_payload(self):
        for error in (ConnectionResetError(), http.client.IncompleteRead(b"partial", 12)):
            with self.subTest(error=type(error).__name__):
                self.open.reset_mock()
                self.sleep.reset_mock()
                broken = response(read_error=error)
                self.open.side_effect = [broken, response()]
                self.assertEqual(EDGE.fetch(SOURCE), IPV4)
                broken.__exit__.assert_called_once()
                self.assertEqual(self.open.call_count, 2)
                self.sleep.assert_called_once_with(1)

    def test_tls_errors_are_not_retried(self):
        for error in (
            ssl.SSLCertVerificationError("untrusted certificate"),
            urllib.error.URLError(ssl.SSLCertVerificationError("untrusted certificate")),
            urllib.error.URLError(ssl.SSLError("TLS configuration error")),
        ):
            with self.subTest(error=type(error).__name__):
                self.open.reset_mock()
                self.open.side_effect = [error, response()]
                with self.assertRaises((ssl.SSLError, urllib.error.URLError)) as raised:
                    EDGE.fetch(SOURCE)
                self.assertIs(raised.exception, error)
                self.open.assert_called_once()
                self.sleep.assert_not_called()

    def test_unexpected_response_status_fails_once(self):
        self.open.return_value = response(status=204)
        with self.assertRaisesRegex(EDGE.ContractError, "HTTP 204"):
            EDGE.fetch(SOURCE)
        self.open.assert_called_once()
        self.sleep.assert_not_called()

    def test_both_matching_families_pass(self):
        self.open.side_effect = [response(IPV4), response(IPV6)]
        EDGE.verify_online_pin(contract())
        self.assertEqual(self.open.call_count, 2)
        self.sleep.assert_not_called()

    def test_each_family_has_its_own_retry_budget(self):
        self.open.side_effect = [
            TimeoutError(), TimeoutError(), response(IPV4),
            ConnectionResetError(), ConnectionResetError(), response(IPV6),
        ]
        EDGE.verify_online_pin(contract())
        self.assertEqual(self.open.call_count, 6)
        self.assertEqual(self.sleep.call_args_list, [call(1), call(2), call(1), call(2)])

    def test_pin_mismatch_is_never_retried(self):
        for replies, family in (
            ([response(b"changed IPv4")], "ipv4"),
            ([response(IPV4), response(b"changed IPv6")], "ipv6"),
        ):
            with self.subTest(family=family):
                self.open.reset_mock()
                self.open.side_effect = replies + [response()]
                with self.assertRaisesRegex(EDGE.ContractError, f"{family} source hash changed"):
                    EDGE.verify_online_pin(contract())
                self.assertEqual(self.open.call_count, len(replies))
                self.sleep.assert_not_called()

    def test_recovered_fetch_still_fails_a_bad_pin_immediately(self):
        self.open.side_effect = [TimeoutError(), response(b"changed"), response()]
        with self.assertRaisesRegex(EDGE.ContractError, "ipv4 source hash changed"):
            EDGE.verify_online_pin(contract())
        self.assertEqual(self.open.call_count, 2)
        self.sleep.assert_called_once_with(1)

    def test_range_mismatch_is_not_retried(self):
        self.open.side_effect = [response(IPV4), response(IPV6), response()]
        bad = contract()
        bad["cloudflareRanges"] = []
        with self.assertRaisesRegex(EDGE.ContractError, "official Cloudflare ranges changed"):
            EDGE.verify_online_pin(bad)
        self.assertEqual(self.open.call_count, 2)
        self.sleep.assert_not_called()


if __name__ == "__main__":
    unittest.main()
