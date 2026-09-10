#!/usr/bin/env python3
"""NIX-462: JoeDesk canonical-slash and anonymous-auth routing smoke."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


REPO = pathlib.Path(__file__).resolve().parents[1]
COMPOSE_SPEC = REPO / "hosts/csb0/docker/compose-spec.nix"
REDIRECT_STATUSES = {301, 308}
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


def compose_unescape(value: str) -> str:
    """Model Compose's documented $$ -> $ label interpolation escape."""
    return value.replace("$$", "$")


def expand_redirect(replacement: str, match: re.Match[str]) -> str:
    return re.sub(
        r"\$\{([0-9]+)\}",
        lambda capture: match.group(int(capture.group(1))) or "",
        replacement,
    )


def verify_rendered_contract(labels: dict[str, str]) -> None:
    middleware_key = "traefik.http.routers.joe-csb0.middlewares"
    regex_key = "traefik.http.middlewares.joe-csb0-slash.redirectregex.regex"
    replacement_key = (
        "traefik.http.middlewares.joe-csb0-slash.redirectregex.replacement"
    )
    permanent_key = "traefik.http.middlewares.joe-csb0-slash.redirectregex.permanent"

    middleware_chain = labels.get(middleware_key, "").split(",")
    require(
        middleware_chain
        == ["joe-csb0-slash@docker", "hostdash-auth-csb0@docker"],
        "canonical slash redirect must run before OAuth",
    )
    require(labels.get(permanent_key) == "true", "slash redirect must be permanent")
    require(
        not any("joe-csb0-path.replacepathregex" in key for key in labels),
        "internal replacepathregex middleware is still present",
    )

    rendered_regex = labels.get(regex_key)
    rendered_replacement = labels.get(replacement_key)
    require(rendered_regex is not None, "redirect regex label is missing")
    require(rendered_replacement is not None, "redirect replacement label is missing")
    traefik_regex = re.compile(compose_unescape(rendered_regex))
    traefik_replacement = compose_unescape(rendered_replacement)

    examples = {
        "https://edge.example.test/joe": "https://edge.example.test/joe/",
        "https://edge.example.test/joe?desk=j&view=wide": (
            "https://edge.example.test/joe/?desk=j&view=wide"
        ),
    }
    for source, expected in examples.items():
        match = traefik_regex.fullmatch(source)
        require(match is not None, f"redirect regex did not match {source}")
        require(
            expand_redirect(traefik_replacement, match) == expected,
            f"redirect expansion changed for {source}",
        )
    for canonical in (
        "https://edge.example.test/joe/",
        "https://edge.example.test/joe/data.json",
        "https://edge.example.test/joe/assets/app.js",
        "https://edge.example.test/joe/inbox",
    ):
        require(
            traefik_regex.fullmatch(canonical) is None,
            f"canonical route would redirect: {canonical}",
        )

    ui_rule = labels.get("traefik.http.routers.joe-csb0.rule", "")
    require("Path(`/joe`)" in ui_rule, "UI router no longer accepts slashless /joe")
    require(
        "PathPrefix(`/joe/`)" in ui_rule,
        "UI router no longer protects canonical JoeDesk paths",
    )
    inbox_priority = int(labels["traefik.http.routers.joe-inbox-csb0.priority"])
    ui_priority = int(labels["traefik.http.routers.joe-csb0.priority"])
    require(inbox_priority > ui_priority, "inbox router must outrank the UI router")
    require(
        "traefik.http.routers.joe-inbox-csb0.middlewares" not in labels,
        "inbox router unexpectedly gained OAuth middleware",
    )


def request_without_redirects(opener: Any, url: str) -> tuple[int, Any]:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "nixcfg-NIX-462-joe-slash-smoke"},
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
