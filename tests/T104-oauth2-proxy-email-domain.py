#!/usr/bin/env python3
"""OPS-366: restrict SSO to the operator domain; offline by default."""

from __future__ import annotations

import argparse
import copy
from contextlib import redirect_stdout
import http.client
import io
import json
from pathlib import Path
import shlex
import subprocess
import sys
from unittest.mock import Mock, patch
from urllib.parse import urlsplit


REPO = Path(__file__).resolve().parents[1]
LIVE_URLS = (
    "https://cs0.barta.cm/",
    "https://cs0.barta.cm/joe/",
    "https://cs1.barta.cm/",
)
REQUIRED = {
    "hosts/csb0/docker/compose-spec.nix:hostdash-auth",
    "hosts/csb1/docker/compose-spec.nix:hostdash-auth",
}
UNVERIFIED = "--insecure-oidc-allow-unverified-email"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def load_services() -> tuple[dict, int]:
    # Evaluate plain compose data only: no flake inputs, derivations, builds,
    # runtime env_files or decrypted secrets. Inspect every discovered spec,
    # including future hosts, rather than hardcoding the two current proxies.
    specs = sorted(REPO.rglob("compose-spec.nix"))
    require(bool(specs), "no compose specs discovered")
    services = {}
    for spec in specs:
        relative = spec.relative_to(REPO).as_posix()
        expression = """
          let spec = import (builtins.toPath %s); in
          builtins.mapAttrs (_: service: {
            image = service.image or "";
            command = service.command or [];
            entrypoint = service.entrypoint or [];
          }) spec.services
        """ % json.dumps(str(spec))
        result = subprocess.run(
            ["nix-instantiate", "--eval", "--strict", "--json", "--expr", expression],
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
        require(result.returncode == 0, f"compose evaluation failed: {relative}")
        for name, service in json.loads(result.stdout).items():
            services[f"{relative}:{name}"] = service
    return services, len(specs)


def arguments(value: object) -> list[str]:
    if isinstance(value, str):
        return shlex.split(value)
    require(isinstance(value, list), "command/entrypoint must be a string or list")
    require(all(isinstance(arg, str) for arg in value), "non-string argument")
    return value


def check_services(services: dict) -> int:
    proxies = 0
    seen = set()
    for name, service in services.items():
        if "oauth2-proxy" not in service["image"]:
            continue
        proxies += 1
        seen.add(name)
        args = arguments(service["entrypoint"]) + arguments(service["command"])
        require(
            not any(arg.split("=", 1)[0] == UNVERIFIED for arg in args),
            f"{name}: unverified-email flag is forbidden",
        )
        domains = []
        for index, arg in enumerate(args):
            if arg == "--email-domain":
                value = args[index + 1] if index + 1 < len(args) else ""
            elif arg.startswith("--email-domain="):
                value = arg.split("=", 1)[1]
            else:
                continue
            domains.extend(value.split(","))
        require(bool(domains), f"{name}: missing email-domain")
        require(
            all(
                domain.strip() and "*" not in domain and not domain.startswith("--")
                for domain in domains
            ),
            f"{name}: empty or wildcard email-domain",
        )
        if name in REQUIRED:
            require(domains == ["barta.com"], f"{name}: operator domain must be barta.com")
    require(REQUIRED <= seen, "required HostDash oauth2-proxy service missing")
    return proxies


def denied_or_idp(status: int, location: str) -> bool:
    if status in (401, 403):
        return True
    if status != 302:
        return False
    try:
        target = urlsplit(location)
        return (
            target.scheme == "https"
            and target.hostname == "auth.inspr.at"
            and target.port in (None, 443)
            and target.username is None
            and target.password is None
        )
    except ValueError:
        return False


def anonymous_get(url: str) -> tuple[int, bool]:
    target = urlsplit(url)
    connection = http.client.HTTPSConnection(target.hostname, timeout=10)
    try:
        # A fresh client per request: no cookies, authorization, proxy settings,
        # redirects, body reads, or header/body output. TLS verification stays on.
        connection.request("GET", target.path or "/")
        response = connection.getresponse()
        status = response.status
        allowed = denied_or_idp(status, response.getheader("Location", ""))
        response.close()
        return status, allowed
    except (OSError, http.client.HTTPException, ValueError):
        return 0, False
    finally:
        connection.close()


def mutations(services: dict) -> int:
    count = 0
    for name in sorted(REQUIRED):
        baseline = services[name]["command"]
        require("--email-domain=barta.com" in baseline, "missing mutation anchor")
        for replacement in (
            [],
            ["--email-domain=*"],
            ["--email-domain="],
            ["--email-domain=barta.com,*"],
            ["--email-domain", "*"],
            ["--email-domain=*.barta.com"],
            ["--email-domain=other.invalid"],
            ["--email-domain=barta.com", UNVERIFIED],
            ["--email-domain=barta.com", UNVERIFIED + "=true"],
            ["--email-domain=barta.com", UNVERIFIED + "=false"],
            ["--email-domain=barta.com", "--email-domain=*"],
        ):
            candidate = copy.deepcopy(services)
            args = candidate[name]["command"]
            index = args.index("--email-domain=barta.com")
            args[index : index + 1] = replacement
            try:
                check_services(candidate)
            except AssertionError:
                count += 1
            else:
                raise AssertionError(f"{name}: unsafe mutation accepted")
    # A proxy on a newly discovered host must also satisfy the generic rule.
    for args in ([], ["--email-domain=*"], ["--email-domain=barta.com", UNVERIFIED]):
        candidate = copy.deepcopy(services)
        candidate["future:auth"] = {
            "image": "quay.io/oauth2-proxy/oauth2-proxy:v7.15.3",
            "command": args,
            "entrypoint": [],
        }
        try:
            check_services(candidate)
        except AssertionError:
            count += 1
        else:
            raise AssertionError("future proxy mutation accepted")
    return count


def check_live_contract() -> int:
    cases = (
        (302, "https://auth.inspr.at/oauth/v2/authorize?state=fixture", True),
        (401, "", True),
        (403, "", True),
        (200, "", False),
        (202, "", False),
        (301, "https://auth.inspr.at/", False),
        (302, "", False),
        (302, "/oauth2/start", False),
        (302, "https://auth.inspr.at.other.invalid/", False),
        (302, "http://auth.inspr.at/", False),
        (302, "https://auth.inspr.at:444/", False),
        (302, "https://user@auth.inspr.at/", False),
        (302, "https://[invalid/", False),
        (500, "", False),
        (0, "", False),
    )
    for status, location, expected in cases:
        response = Mock(status=status)
        response.getheader.return_value = location
        with patch.object(http.client, "HTTPSConnection") as factory:
            connection = factory.return_value
            connection.getresponse.return_value = response
            require(
                anonymous_get(LIVE_URLS[1]) == (status, expected), "live verdict drift"
            )
            factory.assert_called_once_with("cs0.barta.cm", timeout=10)
            connection.request.assert_called_once_with("GET", "/joe/")
            response.read.assert_not_called()
            response.close.assert_called_once()
            connection.close.assert_called_once()
    with patch.object(http.client, "HTTPSConnection") as factory:
        factory.return_value.request.side_effect = OSError("offline fixture")
        require(anonymous_get(LIVE_URLS[0]) == (0, False), "network failure accepted")
        factory.return_value.close.assert_called_once()
    # Exercise the actual --live entry point offline, including failure exit
    # status and continued probing after failure. Its stdout stays codes only.
    for results, expected_exit, expected_output in (
        ([(302, True), (401, True), (403, True)], 0, "302\n401\n403\n"),
        ([(200, False), (0, False), (403, True)], 1, "200\n000\n403\n"),
    ):
        output = io.StringIO()
        with (
            patch.object(sys, "argv", ["T104", "--live"]),
            patch(__name__ + ".anonymous_get", side_effect=results) as probe,
            redirect_stdout(output),
        ):
            require(main() == expected_exit, "live mode exit status drift")
        require(output.getvalue() == expected_output, "live mode output is not codes only")
        require(
            [call.args[0] for call in probe.call_args_list] == list(LIVE_URLS),
            "live mode did not probe all three URLs in order",
        )
    return len(cases) + 3


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--live",
        action="store_true",
        help="OPS only, after the switch; print status codes only",
    )
    args = parser.parse_args()
    if args.live:
        passed = True
        for url in LIVE_URLS:
            status, allowed = anonymous_get(url)
            print(f"{status:03d}")
            passed = passed and allowed
        return 0 if passed else 1

    services, specs = load_services()
    proxies = check_services(services)
    rejected = mutations(services)
    live_cases = check_live_contract()
    workflow = (REPO / ".github/workflows/check.yml").read_text()
    require(
        workflow.count("run: python3 tests/T104-oauth2-proxy-email-domain.py") == 1,
        "CI wiring missing or duplicated",
    )
    print(
        f"T104: PASS specs={specs} proxies={proxies} "
        f"mutations={rejected} live_fixtures={live_cases}"
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (AssertionError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"T104: FAIL {error}", file=sys.stderr)
        sys.exit(1)
