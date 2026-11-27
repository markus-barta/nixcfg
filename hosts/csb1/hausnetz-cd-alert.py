"""OPS-705: one bounded stdin message using csb1's existing notification target."""

from pathlib import Path
import re
import sys
import urllib.parse
import urllib.request


NOTIFICATION_ENV = "@NOTIFICATION_ENV@"


def send(message, credential_path):
    # No shell evaluation, subprocesses, credential argv, or exception logging.
    if not message or len(message) > 2048 or any(not c.isprintable() for c in message):
        return False
    try:
        values = []
        for line in Path(credential_path).read_text().splitlines():
            line = line.strip().removeprefix("export ").lstrip()
            key, separator, value = line.partition("=")
            if separator and key.strip() == "WATCHTOWER_NOTIFICATION_URL":
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
                    value = value[1:-1]
                values.append(value)
        if len(values) != 1:
            return False
        target = urllib.parse.urlsplit(values[0])
        if target.scheme != "telegram" or target.hostname != "telegram" or "@" not in target.netloc:
            return False
        token = urllib.parse.unquote(target.netloc.rsplit("@", 1)[0])
        if not re.fullmatch(r"[0-9]+:[A-Za-z0-9_-]+", token):
            return False
        query = urllib.parse.parse_qs(target.query)
        recipients = [item.strip() for value in (query.get("chats") or query.get("channels") or [])
                      for item in value.split(",")]
        if not recipients or not all(re.fullmatch(r"-?[0-9]+", chat) for chat in recipients):
            return False
        # Disable proxies and redirects: only this literal Telegram host receives
        # the in-process credential. Responses and exceptions never reach logs.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                return None

        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        delivered = True
        for chat in recipients:
            body = urllib.parse.urlencode({"chat_id": chat, "text": message}).encode()
            request = urllib.request.Request("https://api.telegram.org/bot" + token + "/sendMessage", data=body)
            try:
                with opener.open(request, timeout=10) as response:
                    delivered = response.status == 200 and delivered
            except Exception:
                delivered = False
        return delivered
    except Exception:
        return False


def main():
    if len(sys.argv) != 1 or NOTIFICATION_ENV.startswith("@"):
        return 1
    message = sys.stdin.read(2049).rstrip("\n")
    return 0 if send(message, NOTIFICATION_ENV) else 1


if __name__ == "__main__":
    raise SystemExit(main())
