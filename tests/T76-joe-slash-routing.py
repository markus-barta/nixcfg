#!/usr/bin/env python3
"""NIX-463: JoeDesk canonical-slash and anonymous-auth routing smoke."""

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
FLAKE_LOCK = REPO / "flake.lock"
REDIRECT_STATUSES = {301}
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


def run_nix_json(arguments: list[str], context: str) -> Any:
    result = subprocess.run(
        ["nix", "eval", "--json", *arguments],
        text=True,
        capture_output=True,
        check=False,
    )
    require(result.returncode == 0, f"{context} evaluation failed: {result.stderr}")
    return json.loads(result.stdout)


def load_joe_labels() -> dict[str, str]:
    labels = run_nix_json(
        [
            "--file",
            str(COMPOSE_SPEC),
            "--apply",
            'spec: spec.services."joe-board".labels',
        ],
        "compose labels",
    )
    require(isinstance(labels, list), "joe-board labels must evaluate to a list")
    mapped: dict[str, str] = {}
    for label in labels:
        require(isinstance(label, str), "every joe-board label must be a string")
        key, separator, value = label.partition("=")
        require(separator == "=", f"label has no value: {key}")
        require(key not in mapped, f"duplicate joe-board label: {key}")
        mapped[key] = value
    return mapped


def load_rendered_joe_contract() -> dict[str, Any]:
    attribute = f"{REPO}#nixosConfigurations.csb0.config"
    projection = (
        'config: { service = config.nixcfg.composeStack.renderedSpec.services."joe-board"; '
        "excludeFromPull = config.nixcfg.composeStack.autoUpdate.excludeFromPull; }"
    )
    contract = run_nix_json(
        ["--no-update-lock-file", attribute, "--apply", projection],
        "committed flake",
    )
    require(isinstance(contract, dict), "rendered JoeDesk contract must be an object")
    return contract


def compose_unescape(value: str) -> str:
    """Model Compose's documented $$ -> $ interpolation escape."""
    return value.replace("$$", "$")


def expand_redirect(replacement: str, match: re.Match[str]) -> str:
    return re.sub(
        r"\$\{([0-9]+)\}",
        lambda capture: match.group(int(capture.group(1))) or "",
        replacement,
    )


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
    require(
        labels.get(bare + "middlewares") == "joe-csb0-slash@docker",
        "bare path must use only the canonical redirect middleware",
    )
    require(
        labels.get(bare + "service") == labels.get(main + "service") == "joe-board-csb0",
        "both routes must retain the same JoeDesk service association",
    )
    for router in (bare, main):
        require(labels.get(router + "entrypoints") == "web-secure", "HTTPS required")
        require(labels.get(router + "tls") == "true", "TLS required")
    require(
        not any("replacepathregex" in key for key in labels),
        "an internal Joe path rewrite is still present",
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

    middleware = "traefik.http.middlewares.joe-csb0-slash.redirectregex."
    require(labels.get(middleware + "permanent") == "true", "redirect must be permanent")
    rendered_regex = labels.get(middleware + "regex")
    rendered_replacement = labels.get(middleware + "replacement")
    require(rendered_regex is not None, "redirect regex is missing")
    require(rendered_replacement is not None, "redirect replacement is missing")
    traefik_regex = re.compile(compose_unescape(rendered_regex))
    traefik_replacement = compose_unescape(rendered_replacement)
    examples = {
        "https://cs0.barta.cm/joe": "https://cs0.barta.cm/joe/",
        "https://cs0.barta.cm/joe?desk=j&view=wide": (
            "https://cs0.barta.cm/joe/?desk=j&view=wide"
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
        "https://cs0.barta.cm/joe/",
        "https://cs0.barta.cm/joe/data.json",
        "https://cs0.barta.cm/joe/inbox",
    ):
        require(
            traefik_regex.fullmatch(canonical) is None,
            f"canonical route would redirect: {canonical}",
        )


def verify_pinned_build(contract: dict[str, Any]) -> None:
    service = contract.get("service")
    require(isinstance(service, dict), "rendered joe-board service must be an object")
    lock = json.loads(FLAKE_LOCK.read_text())
    revision = lock["nodes"]["joedesk"]["locked"]["rev"]
    require(
        service.get("image") == f"csb0-joe-board:source-{revision}",
        "rendered image name must contain the full locked JoeDesk revision",
    )
    require(
        service.get("pull_policy") == "build",
        "JoeDesk must build its pinned context without registry fallback",
    )
    build = service.get("build")
    require(
        isinstance(build, str) and build.startswith("/nix/store/"),
        "JoeDesk build context must render as an immutable Nix store path",
    )
    require(
        (pathlib.Path(build) / "Dockerfile").is_file(),
        "rendered JoeDesk build context has no Dockerfile",
    )
    require(
        contract.get("excludeFromPull") == ["joe-board"],
        "weekly registry pulls must exclude the host-built JoeDesk image",
    )


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
    verify_pinned_build(load_rendered_joe_contract())
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
