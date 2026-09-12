#!/usr/bin/env python3
"""HOSTD-59 private destinations; managed email relay and existing chat hook.

Destination addresses and credentials are read only from the configured private
runtime JSON. They are never included in logs, state files, or exception output.
"""
from __future__ import annotations

import json
import os
import re
import stat
import subprocess
import urllib.request
import urllib.error
from email.message import EmailMessage
from email.policy import SMTP
from pathlib import Path
from typing import Callable

Sender = Callable[[str, str], bool]
USER_AGENT = "inspr-paper-gateway-notifier/1"
ADDRESS = re.compile(r"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")


def private_config(path: str) -> dict:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        metadata = os.fstat(descriptor)
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
                or metadata.st_mode & 0o077 or metadata.st_nlink != 1
                or metadata.st_size > 16384):
            raise ValueError("private notification config custody refused")
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            raw = handle.read(16385)
        if len(raw) > 16384:
            raise ValueError("notification config too large")
        document = json.loads(raw)
        if not isinstance(document, dict) or document.get("schema_version") != 1:
            raise ValueError("notification config schema refused")
        return document
    finally:
        os.close(descriptor)


def unavailable(channel: str) -> Sender:
    def send(_text: str, _identifier: str) -> bool:
        print(f"{channel} notification unavailable: configuration or receiver missing")
        return False
    return send


def email_sender(config: dict, docker_bin: str) -> Sender:
    sender, recipient = config.get("from"), config.get("to")
    if not all(isinstance(value, str) and ADDRESS.fullmatch(value) for value in (sender, recipient)):
        raise ValueError("email destination invalid")
    container = config.get("relay_container", "docker-smtp-1")
    if container != "docker-smtp-1":
        raise ValueError("unmanaged mail relay refused")

    def send(text: str, identifier: str) -> bool:
        if not re.fullmatch(r"[a-zA-Z0-9_-]{1,80}", identifier):
            return False
        message = EmailMessage(policy=SMTP)
        message["From"] = sender
        message["To"] = recipient
        subject = "Paper Gateway recovery" if "Paper Gateway recovered" in text else "Paper Gateway needs attention"
        message["Subject"] = ("[TEST] " if text.startswith("CONTROLLED TEST") else "") + subject
        message["Message-ID"] = f"<hostd59-{identifier}@{sender.rsplit('@', 1)[1]}>"
        message["X-INSPR-Event-ID"] = identifier
        message.set_content(text)
        try:
            result = subprocess.run(
                [docker_bin, "exec", "-i", container, "/usr/sbin/sendmail", "-i", "-f", sender, "-t"],
                input=message.as_bytes(), capture_output=True, timeout=20, check=False,
            )
            # sendmail acceptance means queued at the existing managed relay;
            # do not claim final inbox delivery from this result alone.
            return result.returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            print("email notification failed: managed relay unavailable")
            return False

    return send


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, _req, _fp, _code, _msg, _headers, _newurl):
        return None


def grok_sender(config: dict, key_file: str) -> Sender:
    # Receiver-owned webhook and its secret remain in Paimos. This uses the
    # existing PHAROS agent-bus target, not a fabricated HOSTD agent identity.
    if config != {"project_id": 17, "to": "grok_bot:amy"}:
        raise ValueError("existing agent-bus target required")

    def send(text: str, identifier: str) -> bool:
        if not re.fullmatch(r"[a-zA-Z0-9_-]{1,80}", identifier):
            return False
        try:
            descriptor = os.open(key_file, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            try:
                metadata = os.fstat(descriptor)
                if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
                        or metadata.st_mode & 0o077 or metadata.st_nlink != 1
                        or metadata.st_size > 8192):
                    raise ValueError("API credential custody refused")
                with os.fdopen(descriptor, "rb", closefd=False) as handle:
                    token = handle.read(8193).decode("ascii").strip()
            finally:
                os.close(descriptor)
            if not token or any(character.isspace() for character in token):
                raise ValueError("API credential format refused")
            message = (
                "HOSTD-59 paper Gateway notification. Please SendToUser this concise notice "
                "to Markus in this existing Grok chat. This is notification only: do not trade, "
                "restart anything, or change account settings. Event " + identifier + ": " + text
            )
            request = urllib.request.Request(
                "https://pm.barta.cm/api/machine-notifier/messages",
                data=json.dumps({"body": message}).encode(),
                headers={"Authorization": "Bearer " + token, "Content-Type": "application/json",
                         "Accept": "application/json", "User-Agent": USER_AGENT,
                         "Idempotency-Key": "hostd59-" + identifier},
                method="POST",
            )
            with urllib.request.build_opener(NoRedirect()).open(request, timeout=10) as response:
                raw = response.read(65537)
                if len(raw) > 65536:
                    return False
                body = json.loads(raw)
                if not 200 <= response.status < 300 or not isinstance(body, dict) or not body.get("message_id"):
                    return False
                message_id = body["message_id"]
                if not isinstance(message_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,100}", message_id):
                    return False
            status_request = urllib.request.Request(
                "https://pm.barta.cm/api/machine-notifier/messages/" + message_id + "/receipt",
                headers={"Authorization": "Bearer " + token, "Accept": "application/json", "User-Agent": USER_AGENT},
            )
            with urllib.request.build_opener(NoRedirect()).open(status_request, timeout=10) as response:
                raw = response.read(65537)
                if not 200 <= response.status < 300 or len(raw) > 65536:
                    return False
                receipt = json.loads(raw)
            if not isinstance(receipt, dict):
                return False
            handed_off = (
                receipt.get("message_id") == message_id
                and type(receipt.get("project_id")) is int
                and receipt.get("project_id") == 17
                and receipt.get("address") == "grok_bot:amy"
                and receipt.get("state") == "handed_off"
                and receipt.get("effective_level") == "simple"
                and bool(receipt.get("handed_off_at"))
                and receipt.get("effective_target_id") == "4f73e08c-f98d-4dfd-a86c-6a9393f05db4"
                and type(receipt.get("effective_target_version")) is int
                and receipt.get("effective_target_version") == 1
            )
            # A webhook handoff still does not prove Amy's SendToUser output.
            print(f"grok notification {'handed_off' if handed_off else 'pending-or-failed'}: message_id={message_id} event_id={identifier}")
            return handed_off
        except urllib.error.HTTPError as error:
            print(f"grok notification failed: agent-bus HTTP {error.code}")
            return False
        except (OSError, ValueError, TypeError, urllib.error.URLError):
            print("grok notification failed: agent-bus request unavailable")
            return False

    return send


def declared_senders(path: str, docker_bin: str, key_file: str) -> dict[str, Sender]:
    try:
        config = private_config(path)
    except (OSError, ValueError, TypeError):
        return {name: unavailable(name) for name in ("email", "grok")}
    try:
        mail = email_sender(config.get("email", {}), docker_bin)
    except (ValueError, TypeError, AttributeError):
        mail = unavailable("email")
    try:
        chat = grok_sender(config.get("grok", {}), key_file)
    except (ValueError, TypeError, AttributeError):
        chat = unavailable("grok")
    return {"email": mail, "grok": chat}
