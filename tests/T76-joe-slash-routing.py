#!/usr/bin/env python3
"""NIX-463: JoeDesk canonical-slash and anonymous-auth routing smoke."""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


REPO = pathlib.Path(__file__).resolve().parents[1]
COMPOSE_SPEC = REPO / "hosts/csb0/docker/compose-spec.nix"
REDIRECT_STATUSES = {308}
AUTH_FAILURE_STATUSES = {302, 303, 307, 401, 403}


class ContractError(AssertionError):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(
        self,
        request: urllib.request.Request,
        file_pointer: Any,
        code: int,
        message: str,
        headers: Any,
        new_url: str,
    ) -> None:
        return None


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def load_joe_labels() -> dict[str, str]:
    result = subprocess.run(
        [
            "nix",
            "eval",
            "--json",
            "--file",
            str(COMPOSE_SPEC),
            "--apply",
            'spec: spec.services."joe-board".labels',
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    require(result.returncode == 0, f"compose evaluation failed: {result.stderr}")
    labels = json.loads(result.stdout)
    require(isinstance(labels, list), "joe-board labels must evaluate to a list")
    mapped: dict[str, str] = {}
    for label in labels:
        require(isinstance(label, str), "every joe-board label must be a string")
        key, separator, value = label.partition("=")
        require(separator == "=", f"label has no value: {key}")
        require(key not in mapped, f"duplicate joe-board label: {key}")
        mapped[key] = value
    return mapped


def verify_rendered_contract(labels: dict[str, str]) -> None:
    main = "traefik.http.routers.joe-csb0."
    bare = "traefik.http.routers.joe-csb0-slash."
    inbox = "traefik.http.routers.joe-inbox-csb0."
    host = "Host(`cs0.barta.cm`)"
    require(
        labels.get(main + "rule") == host + " && PathPrefix(`/joe/`)",
        "canonical UI/data/assets must stay in the protected router",
    )
    require(
        labels.get(main + "middlewares") == "hostdash-auth-csb0@docker",
        "canonical router must require OAuth without an internal rewrite",
    )
    require(
        labels.get(bare + "rule") == host + " && Path(`/joe`)",
        "unauthenticated route must match only the exact canonical host/bare path",
    )
    require(bare + "middlewares" not in labels, "bare path must reach app 308 directly")
    require(
        labels.get(bare + "service") == labels.get(main + "service") == "joe-board-csb0",
        "both routes must reach the same independently pinned JoeDesk app",
    )
    for router in (bare, main):
        require(labels.get(router + "entrypoints") == "web-secure", "HTTPS required")
        require(labels.get(router + "tls") == "true", "TLS required")
    require(
        not any(key.startswith("traefik.http.middlewares.joe-csb0-") for key in labels),
        "obsolete Joe rewrite/301 middleware must be removed",
    )
    require(
        int(labels[bare + "priority"]) > int(labels[inbox + "priority"])
        > int(labels[main + "priority"]),
        "exact redirect and inbox routes must outrank the protected prefix",
    )
    require(
        labels.get(inbox + "rule") == host + " && Path(`/joe/inbox`)",
        "inbox route must remain exact",
    )
    require(inbox + "middlewares" not in labels, "inbox token contract changed")


def request_without_redirects(opener: Any, url: str) -> tuple[int, Any]:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "nixcfg-NIX-463-joe-slash-smoke"},
    )
    try:
        with opener.open(request, timeout=10) as response:
            return response.status, response.headers
    except urllib.error.HTTPError as error:
        return error.code, error.headers


def verify_live() -> None:
    # This deployment smoke contacts only its canonical public endpoint.
    origin = "https://cs0.barta.cm"
    parsed_base = urllib.parse.urlsplit(origin)
    opener = urllib.request.build_opener(NoRedirect())

    for suffix in ("", "?desk=j&view=wide"):
        source = f"{origin}/joe{suffix}"
        status, headers = request_without_redirects(opener, source)
        require(status in REDIRECT_STATUSES, f"{source} returned HTTP {status}")
        location = headers.get("Location")
        require(location is not None, f"{source} redirect omitted Location")
        actual = urllib.parse.urljoin(source, location)
        expected = f"{origin}/joe/{suffix}"
        require(actual == expected, f"{source} redirected to {actual}, not {expected}")

    for path in ("/joe/", "/joe/data.json", "/joe/history.json", "/joe/joe.css"):
        source = f"{origin}{path}"
        status, headers = request_without_redirects(opener, source)
        require(
            status in AUTH_FAILURE_STATUSES,
            f"anonymous {path} was not OAuth-gated (HTTP {status})",
        )
        if status in {302, 303, 307}:
            location = headers.get("Location")
            require(location is not None, f"OAuth redirect for {path} omitted Location")
            target = urllib.parse.urlsplit(urllib.parse.urljoin(source, location))
            require(
                target.path.startswith("/oauth2/") or target.netloc != parsed_base.netloc,
                f"anonymous {path} redirect does not enter OAuth: {location}",
            )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--live",
        action="store_true",
        help="opt in to the no-auth HTTP smoke at https://cs0.barta.cm",
    )
    arguments = parser.parse_args()

    verify_rendered_contract(load_joe_labels())
    if arguments.live:
        verify_live()
    print(
        "joe_slash_routing=ok "
        f"rendered_config=ok live={'ok' if arguments.live else 'skipped'}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ContractError, OSError, ValueError, json.JSONDecodeError) as error:
        print(f"T76: {error}", file=sys.stderr)
        raise SystemExit(1)
