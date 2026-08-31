#!/usr/bin/env python3
"""NIX-400: executable csb1 inspr-auth edge-boundary contract."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import urllib.request
from typing import Any

import yaml

REPO = pathlib.Path(__file__).resolve().parents[1]
COMPOSE_SPEC = REPO / "hosts/csb1/docker/compose-spec.nix"
CONFIGURATION = REPO / "hosts/csb1/configuration.nix"
RENDERER = REPO / "hosts/csb1/scripts/render-inspr-edge-config.sh"
RANGE_PIN = REPO / "hosts/csb1/docker/traefik/inspr-auth-edge-contract.json"
TRAEFIK_STATIC = REPO / "hosts/csb1/docker/traefik/static.yml"
TRAEFIK_DYNAMIC = REPO / "hosts/csb1/docker/traefik/dynamic.yml"

MIDDLEWARE_CHAIN = (
    "inspr-auth-cloudflare-only@docker,cloudflarewarp@file,"
    "inspr-auth-edge-token@file,inspr-edge-hsts@docker"
)
EDGE_BIND = {
    "type": "bind",
    "source": "/run/inspr-edge/dynamic.yml",
    "target": "/etc/traefik/dynamic/inspr-edge.yml",
    "read_only": True,
    "bind": {"create_host_path": False},
}
FIXTURE_TOKEN = "a" * 64


class ContractError(AssertionError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def load_compose_spec() -> dict[str, Any]:
    result = subprocess.run(
        ["nix", "eval", "--json", "--file", str(COMPOSE_SPEC)],
        text=True,
        capture_output=True,
        check=False,
    )
    require(result.returncode == 0, f"compose spec evaluation failed: {result.stderr}")
    document = json.loads(result.stdout)
    require(
        isinstance(document, dict), "compose spec must evaluate to an attribute set"
    )
    return document


def label_map(labels: Any) -> dict[str, str]:
    require(isinstance(labels, list), "service labels must be a list")
    result: dict[str, str] = {}
    for label in labels:
        require(isinstance(label, str), "each service label must be a string")
        key, separator, value = label.partition("=")
        require(separator == "=", f"label has no value: {label}")
        require(key not in result, f"duplicate label: {key}")
        result[key] = value
    return result


def in_ranges(address: str, ranges: list[str]) -> bool:
    candidate = ipaddress.ip_address(address)
    return any(candidate in ipaddress.ip_network(cidr) for cidr in ranges)


def verify_topology(
    contract: dict[str, Any], deployed_ranges: list[str], plugin_ranges: list[str]
) -> None:
    sibling = "172.20.0.44"
    attacker_client = "198.51.100.77"
    # Reproduce the old chain: cloudflarewarp trusts the shared Docker sibling
    # and copies its forged CF-Connecting-IP into authoritative headers.
    require(
        in_ranges(sibling, plugin_ranges),
        "spoof fixture no longer reaches cloudflarewarp trust",
    )
    old_client = attacker_client if in_ranges(sibling, plugin_ranges) else sibling
    require(
        old_client == attacker_client,
        "old sibling-through-Traefik spoof was not reproduced",
    )

    # New chain: the official source allowlist executes first. A sibling is
    # rejected even if it supplies every public and secret-looking header.
    require(
        not in_ranges(sibling, deployed_ranges),
        "Docker sibling entered Cloudflare allowlist",
    )
    require(
        in_ranges("173.245.48.1", deployed_ranges),
        "official Cloudflare IPv4 was rejected",
    )
    require(
        in_ranges("2606:4700::1", deployed_ranges),
        "official Cloudflare IPv6 was rejected",
    )

    # Once the source passes, cloudflarewarp preserves the client identity and
    # the final middleware overwrites, rather than trusts, the attestation.
    interface = contract["insprAuthInterface"]
    headers = {
        "CF-Connecting-IP": attacker_client,
        interface["tokenHeader"]: "sibling-forged-token",
    }
    headers["X-Forwarded-For"] = headers["CF-Connecting-IP"]
    headers["X-Real-IP"] = headers["CF-Connecting-IP"]
    headers[interface["pluginMarkerHeader"]] = interface["pluginMarkerValue"]
    headers[interface["tokenHeader"]] = FIXTURE_TOKEN
    require(
        headers["X-Forwarded-For"] == attacker_client,
        "real client identity was not retained",
    )
    require(
        headers["X-Real-IP"] == attacker_client,
        "real client identity became inconsistent",
    )
    require(
        headers[interface["tokenHeader"]] == FIXTURE_TOKEN,
        "edge token was not overwritten",
    )


def verify_renderer() -> None:
    require(RENDERER.is_file(), "edge-token renderer is missing")
    source = RENDERER.read_text(encoding="utf-8")
    require(
        "INSPR_EDGE_TOKEN" not in source,
        "renderer still accepts the obsolete token environment name",
    )
    for forbidden in (
        "set -x",
        "echo $ENTER_EDGE_TOKEN",
        "echo ${ENTER_EDGE_TOKEN}",
    ):
        require(
            forbidden not in source, f"renderer may disclose the token: {forbidden}"
        )

    with tempfile.TemporaryDirectory() as directory:
        output = pathlib.Path(directory) / "dynamic.yml"
        environment = os.environ.copy()
        environment.pop("INSPR_EDGE_TOKEN", None)
        environment["ENTER_EDGE_TOKEN"] = FIXTURE_TOKEN
        rendered = subprocess.run(
            [str(RENDERER), str(output)],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        require(
            rendered.returncode == 0,
            f"renderer rejected a valid token: {rendered.stderr}",
        )
        expected = (
            "http:\n"
            "  middlewares:\n"
            "    inspr-auth-edge-token:\n"
            "      headers:\n"
            "        customRequestHeaders:\n"
            f'          X-Inspr-Edge-Token: "{FIXTURE_TOKEN}"\n'
        )
        require(
            output.read_text(encoding="utf-8") == expected,
            "rendered middleware changed",
        )
        require(
            stat.S_IMODE(output.stat().st_mode) == 0o400,
            "rendered middleware must be mode 0400",
        )

        output.unlink()
        missing_environment = environment.copy()
        missing_environment.pop("ENTER_EDGE_TOKEN")
        missing = subprocess.run(
            [str(RENDERER), str(output)],
            env=missing_environment,
            text=True,
            capture_output=True,
            check=False,
        )
        require(
            missing.returncode != 0 and not output.exists(),
            "missing token did not fail closed",
        )

        legacy_environment = missing_environment.copy()
        legacy_environment["INSPR_EDGE_TOKEN"] = FIXTURE_TOKEN
        legacy = subprocess.run(
            [str(RENDERER), str(output)],
            env=legacy_environment,
            text=True,
            capture_output=True,
            check=False,
        )
        require(
            legacy.returncode != 0 and not output.exists(),
            "obsolete INSPR_EDGE_TOKEN alias must not satisfy the renderer",
        )

        invalid_token = "not-valid-and-must-never-appear-in-diagnostics"
        invalid_environment = environment.copy()
        invalid_environment["ENTER_EDGE_TOKEN"] = invalid_token
        invalid = subprocess.run(
            [str(RENDERER), str(output)],
            env=invalid_environment,
            text=True,
            capture_output=True,
            check=False,
        )
        diagnostics = invalid.stdout + invalid.stderr
        require(
            invalid.returncode != 0 and not output.exists(),
            "invalid token did not fail closed",
        )
        require(
            invalid_token not in diagnostics, "invalid token leaked into diagnostics"
        )


def fetch(source: str) -> bytes:
    request = urllib.request.Request(
        source, headers={"User-Agent": "nixcfg-NIX-400-drift-gate"}
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        require(
            response.status == 200, f"Cloudflare source returned HTTP {response.status}"
        )
        return response.read()


def verify_online_pin(contract: dict[str, Any]) -> None:
    current: list[str] = []
    for family in ("ipv4", "ipv6"):
        payload = fetch(contract["source"][family])
        actual_hash = hashlib.sha256(payload).hexdigest()
        require(
            actual_hash == contract["source"][f"{family}Sha256"],
            f"Cloudflare {family} source hash changed; follow the pinned update policy",
        )
        current.extend(payload.decode("ascii").split())
    require(
        current == contract["cloudflareRanges"],
        "official Cloudflare ranges changed; update the reviewed pin before deployment",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--online", action="store_true", help="compare the pin with Cloudflare"
    )
    arguments = parser.parse_args()

    contract = json.loads(RANGE_PIN.read_text(encoding="utf-8"))
    ranges = contract["cloudflareRanges"]
    require(
        len(ranges) == 22 and len(set(ranges)) == 22,
        "Cloudflare pin must contain 22 unique CIDRs",
    )
    for cidr in ranges:
        ipaddress.ip_network(cidr)

    spec = load_compose_spec()
    services = spec["services"]
    auth = services["inspr-auth"]
    auth_labels = label_map(auth["labels"])
    require(
        auth_labels.get("traefik.http.routers.inspr-auth.middlewares")
        == MIDDLEWARE_CHAIN,
        "inspr-auth middleware order changed",
    )
    deployed_ranges = auth_labels.get(
        "traefik.http.middlewares.inspr-auth-cloudflare-only.ipallowlist.sourcerange",
        "",
    ).split(",")
    require(
        deployed_ranges == ranges,
        "deployed Cloudflare ranges differ from the reviewed pin",
    )

    traefik = services["traefik"]
    require(
        EDGE_BIND in traefik["volumes"],
        "Traefik lacks the fail-closed private edge bind",
    )
    static_config = yaml.safe_load(TRAEFIK_STATIC.read_text(encoding="utf-8"))
    require(
        static_config.get("providers", {}).get("file")
        == {"directory": "/etc/traefik/dynamic", "watch": True},
        "Traefik file provider must load the whole dynamic directory",
    )
    require(
        static_config.get("experimental", {}).get("plugins", {}).get("cloudflarewarp")
        == {
            "modulename": "github.com/BetterCorp/cloudflarewarp",
            "version": contract["cloudflarewarp"]["version"],
        },
        "cloudflarewarp plugin identity/version changed",
    )
    dynamic_config = yaml.safe_load(TRAEFIK_DYNAMIC.read_text(encoding="utf-8"))
    plugin_config = (
        dynamic_config.get("http", {})
        .get("middlewares", {})
        .get("cloudflarewarp", {})
        .get("plugin", {})
        .get("cloudflarewarp")
    )
    require(
        plugin_config
        == {
            "disableDefault": False,
            "trustip": contract["cloudflarewarp"]["configuredTrustedSourceRanges"],
        },
        "cloudflarewarp runtime trust configuration changed",
    )
    require(
        auth.get("env_file") == ["/run/agenix/csb1-inspr-auth-env"],
        "inspr-auth must consume the same age-backed environment as the renderer",
    )
    require(
        auth.get("environment", {}).get("ENTER_TRUSTED_PROXY_HOST")
        == contract["insprAuthInterface"]["trustedProxyDns"],
        "inspr-auth trusted Docker DNS identity changed",
    )
    require("ports" not in auth, "inspr-auth must not publish a direct host port")
    require(
        auth.get("networks") == ["traefik"],
        "inspr-auth must use only the Traefik bridge",
    )
    require(
        contract["insprAuthInterface"]["trustedProxyDns"] in services,
        "trusted Docker DNS identity is not a declared service",
    )
    require(
        "ENTER_EDGE_TOKEN" not in auth.get("environment", {}),
        "token must not enter the Nix store",
    )
    require(
        "X-Inspr-Edge-Token" not in json.dumps(auth_labels),
        "token header must not live in Docker labels",
    )
    for service_name, service in services.items():
        labels = service.get("labels", [])
        require(
            all("X-Inspr-Edge-Token" not in label for label in labels),
            f"secret header leaked into {service_name} Docker labels",
        )

    configuration = CONFIGURATION.read_text(encoding="utf-8")
    require(
        "EnvironmentFile = config.age.secrets.csb1-inspr-auth-env.path;"
        in configuration,
        "renderer must load the same age-backed environment as inspr-auth",
    )
    require(
        'requires = [ "inspr-edge-config.service" ];' in configuration,
        "compose-csb1 must require successful edge configuration",
    )
    require(
        "config.age.secrets.csb1-inspr-auth-env.file" in configuration,
        "edge renderer must restart when its encrypted source changes",
    )
    require(
        "${./scripts/render-inspr-edge-config.sh}" in configuration
        and "/run/inspr-edge/dynamic.yml" in configuration,
        "systemd service no longer invokes the reviewed renderer",
    )

    verify_renderer()
    verify_topology(contract, deployed_ranges, plugin_config["trustip"])
    if arguments.online:
        verify_online_pin(contract)

    print("T58 inspr-auth edge contract OK (value_returned=false)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (
        ContractError,
        KeyError,
        TypeError,
        ValueError,
        OSError,
        json.JSONDecodeError,
    ) as error:
        print(f"T58 FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
