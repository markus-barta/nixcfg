#!/usr/bin/env python3
"""Attended OPS-196 recovery. Run yourself, never in an agent transcript.

Python 3.11+. Reads the existing private TOML, requests only gmail.insert,
and atomically replaces Tokens after a fresh offline grant. Does not launch
a browser, encrypt, deploy, move mail, or print credentials/provider errors.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import html
import http.server
import json
import os
import re
import secrets
import ssl
import stat
import sys
import tempfile
import time
import tomllib
import urllib.parse
import urllib.request
from pathlib import Path

SCOPE = "https://www.googleapis.com/auth/gmail.insert"
TOKEN_URL = "https://oauth2.googleapis.com/token"
LIMIT = 1024 * 1024
TOKEN_FIELD = re.compile(
    r"^[ \t]*Tokens[ \t]*=[ \t]*(?:'''[\s\S]*?'''|\"\"\"[\s\S]*?\"\"\"|"
    r'"(?:[^"\\\n]|\\.)*"|\'[^\'\n]*\')[ \t]*(?:#[^\n]*)?$',
    re.MULTILINE,
)


def require(condition: bool) -> None:
    if not condition:
        raise ValueError("recovery precondition failed")


def private_file(path: Path) -> bytes:
    require(not path.is_symlink())
    info = path.stat()
    parent = path.parent.stat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid())
    require(info.st_mode & 0o077 == 0 and parent.st_mode & 0o077 == 0)
    require(parent.st_uid == os.getuid() and info.st_size <= LIMIT)
    return path.read_bytes()


def replace_tokens(original: bytes, tokens: dict) -> bytes:
    text = original.decode("utf-8")
    before = tomllib.loads(text)
    require(isinstance(before.get("Tokens"), str))
    matches = list(TOKEN_FIELD.finditer(text))
    require(len(matches) == 1)
    match = matches[0]
    replacement = "Tokens = " + json.dumps(json.dumps(tokens))
    updated = text[: match.start()] + replacement + text[match.end() :]
    expected = dict(before, Tokens=json.dumps(tokens))
    require(tomllib.loads(updated) == expected)
    return updated.encode("utf-8")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def exchange(client: dict, code: str, verifier: str, redirect: str) -> dict:
    request = urllib.request.Request(
        TOKEN_URL,
        data=urllib.parse.urlencode(
            {
                "grant_type": "authorization_code",
                "client_id": client["client_id"],
                "client_secret": client["client_secret"],
                "code": code,
                "code_verifier": verifier,
                "redirect_uri": redirect,
            }
        ).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    # Fixed Google destination, normal TLS verification, no redirects or proxy.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.load_default_certs()  # No SSLKEYLOGFILE or unverified-context override.
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPSHandler(context=context),
        NoRedirect(),
    )
    with opener.open(request, timeout=30) as response:
        require(response.status == 200)
        raw = response.read(LIMIT + 1)
    require(len(raw) <= LIMIT)
    token = json.loads(raw)
    require(isinstance(token, dict))
    for field in ("access_token", "refresh_token", "token_type"):
        require(isinstance(token.get(field), str) and bool(token[field]))
    require(token["token_type"].lower() == "bearer")
    require(set(token.get("scope", "").split()) == {SCOPE})
    require(
        isinstance(token.get("expires_in"), int) and 0 < token["expires_in"] < 86400
    )
    expiry = dt.datetime.now(dt.UTC) + dt.timedelta(seconds=token["expires_in"])
    # Match golang.org/x/oauth2.Token's JSON contract; no provider extras.
    return {k: token[k] for k in ("access_token", "refresh_token", "token_type")} | {
        "expiry": expiry.isoformat().replace("+00:00", "Z")
    }


def save(path: Path, original: bytes, tokens: dict, stamp: str) -> None:
    updated = replace_tokens(original, tokens)
    require(private_file(path) == original)
    # Keep one private rollback copy; never overwrite a previous recovery.
    backup = path.with_name(path.name + ".before-oauth-" + stamp.replace(":", ""))
    with open(backup, "xb") as handle:
        os.chmod(backup, 0o600)
        handle.write(original)
        handle.flush()
        os.fsync(handle.fileno())
    with tempfile.NamedTemporaryFile(
        dir=path.parent, prefix=".oauth-", delete=False
    ) as handle:
        temporary = Path(handle.name)
        handle.write(updated)
        handle.flush()
        os.fsync(handle.fileno())
    require(private_file(path) == original)
    os.replace(temporary, path)


class CallbackServer(http.server.HTTPServer):
    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(3)
        return connection, address

    def handle_error(self, request, client_address):
        # HTTPServer's default prints exception tracebacks, potentially secrets.
        pass


class Recovery:
    def __init__(self, path: Path, original: bytes):
        self.path, self.original = path, original
        cfg = tomllib.loads(original.decode())
        self.client = json.loads(cfg["Secrets"])["installed"]
        require(self.client.get("project_id") == "mailbridge-barta")
        for field in ("client_id", "client_secret"):
            require(
                isinstance(self.client.get(field), str) and bool(self.client[field])
            )
        # Validate replacement compatibility before asking for any new consent.
        replace_tokens(original, {"preflight": True})
        self.state, self.verifier = secrets.token_urlsafe(32), secrets.token_urlsafe(64)
        self.finished, self.success, self.viewed = False, False, False
        self.issued_at = ""
        self.origin = ""

    def auth_url(self) -> str:
        challenge = base64.urlsafe_b64encode(
            hashlib.sha256(self.verifier.encode()).digest()
        )
        return "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode(
            {
                "client_id": self.client["client_id"],
                "redirect_uri": self.origin + "/oauth2callback",
                "response_type": "code",
                "scope": SCOPE,
                "access_type": "offline",
                "prompt": "consent select_account",
                "state": self.state,
                "code_challenge": challenge.decode().rstrip("="),
                "code_challenge_method": "S256",
            }
        )

    def callback(self, query: str) -> bool:
        if self.finished or len(query) > 8192:
            return False
        try:
            values = urllib.parse.parse_qs(query, max_num_fields=20)
            if values.get("state") != [self.state]:
                return False
            self.finished = True
            require("error" not in values and len(values.get("code", [])) == 1)
            tokens = exchange(
                self.client,
                values["code"][0],
                self.verifier,
                self.origin + "/oauth2callback",
            )
            stamp = (
                dt.datetime.now(dt.UTC)
                .isoformat(timespec="seconds")
                .replace("+00:00", "Z")
            )
            save(self.path, self.original, tokens, stamp)
            self.issued_at, self.success = stamp, True
        except Exception:  # noqa: BLE001, S110 -- raw exceptions may contain credentials
            # Never render or print raw errors, URLs, token responses or config.
            pass
        return self.finished


def handler(recovery: Recovery):
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send_error(self, code, message=None, explain=None):
            self.reply(400, "Request rejected.")

        def reply(self, status, body, location=None):
            payload = (
                "<!doctype html><meta charset=utf-8><title>Mailbridge consent</title>"
                + body
            ).encode()
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header(
                "Content-Security-Policy",
                "default-src 'none'; frame-ancestors 'none'; base-uri 'none'",
            )
            if location:
                self.send_header("Location", location)
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):
            if (
                self.headers.get("Host")
                != urllib.parse.urlsplit(recovery.origin).netloc
            ):
                self.reply(400, "Request rejected.")
                return
            target = urllib.parse.urlsplit(self.path)
            if target.path == "/" and not target.query and not recovery.finished:
                self.reply(
                    200,
                    '<h1>Renew your personal mail bridge</h1><p>Select the existing target Gmail account. Only Gmail import permission is requested.</p><p><a href="'
                    + html.escape(recovery.auth_url(), quote=True)
                    + '">Continue to Google</a></p>',
                )
            elif target.path == "/oauth2callback" and recovery.callback(target.query):
                self.reply(303, "Return to the terminal.", "/done")
            elif target.path == "/done" and recovery.finished:
                recovery.viewed = True
                self.reply(
                    200,
                    "<p>Consent saved privately. Return to the terminal.</p>"
                    if recovery.success
                    else "<p>Consent was not saved. Return to the terminal.</p>",
                )
            else:
                self.reply(400, "Request rejected.")

    return Handler


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path)
    args = parser.parse_args()
    if not sys.stdin.isatty():
        print(
            "Run this yourself in an interactive terminal; never capture its session in an agent."
        )
        return 1
    os.umask(0o077)
    try:
        path = args.config.expanduser().absolute()
        recovery = Recovery(path, private_file(path))
        with CallbackServer(("127.0.0.1", 0), handler(recovery)) as server:
            server.timeout = 1
            recovery.origin = "http://127.0.0.1:" + str(server.server_port)
            print("Open this in your existing Helium window on the MacBook display:")
            print(recovery.origin + "/", flush=True)
            deadline = time.monotonic() + 600
            finished_at = None
            while time.monotonic() < deadline and not recovery.viewed:
                server.handle_request()
                if recovery.finished:
                    finished_at = finished_at or time.monotonic()
                    if time.monotonic() - finished_at > 5:
                        break
        if recovery.success:
            print(
                "Saved privately; tokens were not printed. GRANT_ISSUED_AT="
                + recovery.issued_at
            )
            print(
                "Encryption and host deployment are still required. Tell the agent only this timestamp."
            )
            return 0
    except (Exception, KeyboardInterrupt):  # noqa: BLE001, S110 -- private recovery boundary
        pass
    print(
        "Recovery did not complete. No credentials or provider errors were printed; check private files before retrying."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
