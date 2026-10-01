#!/usr/bin/env python3
"""OPS-246: reject accidental public ports in the csb0/csb1 Compose specs.

This checks declarations, not live listeners or host-network services. Accept
single-port short/long syntax; reject ranges and ambiguous input for review.
Only the services' ports are evaluated: no env_file or secret is read.
"""

import argparse
import copy
import ipaddress
import json
from pathlib import Path
import re
import subprocess
import sys
import unittest


PUBLIC_PORTS = {
    "csb0": {(80, 80, "tcp"), (443, 443, "tcp"), (443, 443, "udp"), (8883, 8883, "tcp")},
    "csb1": {(80, 80, "tcp"), (443, 443, "tcp"), (443, 443, "udp")},
}
TAILNET_BINDS = ipaddress.ip_network("100.64.0.0/24")


def port_number(value):
    if type(value) is int:
        number = value
    elif isinstance(value, str) and re.fullmatch(r"[0-9]+", value):
        number = int(value)
    else:
        raise ValueError("expected a single numeric port; ranges are not approved")
    if not 1 <= number <= 65535:
        raise ValueError("port must be between 1 and 65535")
    return number


def parse_port(entry):
    """Return host IP, published port, target port, and protocol."""
    if isinstance(entry, str):
        value, separator, protocol = entry.partition("/")
        protocol = protocol if separator else "tcp"
        if value.startswith("["):
            match = re.fullmatch(r"\[([^\]]+)\]:([^:]+):([^:]+)", value)
            if not match:
                raise ValueError("invalid bracketed host port mapping")
            host_ip, published, target = match.groups()
        else:
            parts = value.split(":")
            if len(parts) == 2:
                host_ip = None
                published, target = parts
            elif len(parts) == 3:
                host_ip, published, target = parts
            else:
                raise ValueError("mapping needs an explicit published and target port")
    elif isinstance(entry, dict):
        if "published" not in entry or "target" not in entry:
            raise ValueError("mapping needs an explicit published and target port")
        host_ip = entry.get("host_ip")
        published, target = entry["published"], entry["target"]
        protocol = entry.get("protocol", "tcp")
        if "host_ip" in entry and host_ip is None:
            raise ValueError("host_ip must be an IP address when present")
    else:
        raise ValueError("port entry must be short-syntax text or a long-syntax object")

    if protocol not in ("tcp", "udp"):
        raise ValueError("unsupported port protocol")
    if host_ip is not None:
        if not isinstance(host_ip, str):
            raise ValueError("host_ip must be an IP address")
        try:
            host_ip = ipaddress.ip_address(host_ip)
        except ValueError as exc:
            raise ValueError("host_ip must be a valid literal IP address") from exc
    return host_ip, port_number(published), port_number(target), protocol


def violations(host, services):
    if host not in PUBLIC_PORTS:
        return ["host has no approved public-port policy"]
    if not isinstance(services, dict) or not services:
        return [f"{host}: expected a nonempty service-to-ports object"]
    failures = []
    for service, ports in services.items():
        if not isinstance(service, str) or not isinstance(ports, list):
            failures.append(f"{host}/{service!r}: ports must be a list")
            continue
        for index, entry in enumerate(ports):
            try:
                host_ip, published, target, protocol = parse_port(entry)
                private_bind = host_ip == ipaddress.ip_address("127.0.0.1") or (
                    isinstance(host_ip, ipaddress.IPv4Address) and host_ip in TAILNET_BINDS
                )
                approved_public = service == "traefik" and (
                    published, target, protocol
                ) in PUBLIC_PORTS[host]
                if not private_bind and not approved_public:
                    raise ValueError("public bind requires an exact Traefik allow-list entry")
            except ValueError as exc:
                failures.append(f"{host}/{service!r} ports[{index}]: {exc}")
    return failures


def evaluate_ports(repo_root, host):
    spec = repo_root / "hosts" / host / "docker" / "compose-spec.nix"
    result = subprocess.run(
        [
            "nix", "eval", "--offline", "--extra-experimental-features", "nix-command",
            "--json", "--file", str(spec), "--apply",
            "s: builtins.mapAttrs (_: service: service.ports or []) s.services",
        ],
        check=True, text=True, stdout=subprocess.PIPE,
    )
    return json.loads(result.stdout)


class PortPolicyTests(unittest.TestCase):
    def test_private_bindings(self):
        for entry in [
            "127.0.0.1:5432:5432", "100.64.0.4:8088:8080",
            "100.64.0.8:1883:1883/tcp", "127.0.0.1:5353:53/udp",
            {"host_ip": "127.0.0.1", "published": "5432", "target": 5432},
            {"host_ip": "100.64.0.4", "published": 8088, "target": 8080},
        ]:
            with self.subTest(entry=entry):
                self.assertEqual(violations("csb1", {"database": [entry]}), [])

    def test_public_exceptions(self):
        for host, entries in {
            "csb0": ["80:80", "443:443/tcp", "443:443/udp", "8883:8883"],
            "csb1": ["80:80", "443:443/tcp", "443:443/udp", "[::]:443:443/udp",
                     {"host_ip": "0.0.0.0", "published": 80, "target": 80}],
        }.items():
            for entry in entries:
                with self.subTest(host=host, entry=entry):
                    self.assertEqual(violations(host, {"traefik": [entry]}), [])

    def test_unapproved_bindings(self):
        for entry in [
            "5432:5432", "0.0.0.0:5432:5432", "[::]:5432:5432", "[::1]:5432:5432",
            "80:80", "127.0.0.2:5432:5432", "192.168.1.2:5432:5432",
            "100.64.1.4:5432:5432", "100.64.0.4.evil:5432:5432",
            "100.64.0.999:5432:5432", "100.64.0.04:5432:5432",
            {"published": "5432", "target": 5432},
            {"host_ip": "::", "published": 5432, "target": 5432},
        ]:
            with self.subTest(entry=entry):
                self.assertTrue(violations("csb1", {"database": [entry]}))

    def test_exception_boundaries(self):
        for entry in [
            "8883:8883", "80:80/udp", "443:443/sctp", "80:5432", "5432:80",
            "443", {"target": 443}, {"published": 443},
        ]:
            with self.subTest(entry=entry):
                self.assertTrue(violations("csb1", {"traefik": [entry]}))

    def test_malformed_input(self):
        for entry in [
            "127.0.0.1:0:5432", "127.0.0.1:65536:5432", "127.0.0.1:5432:-1",
            "127.0.0.1:5000-5002:5000-5002", "127.0.0.1:5432:5432/unknown",
            "127.0.0.1:5432:5432/sctp",
            "127.0.0.1:5432:5432/tcp/udp", "[::1:5432:5432", 5432, True, None,
            {"host_ip": "127.0.0.1", "published": True, "target": 5432},
            {"host_ip": 2130706433, "published": 5432, "target": 5432},
            {"host_ip": None, "published": 443, "target": 443},
            {"host_ip": "127.0.0.1", "published": "5432-5433", "target": 5432},
        ]:
            with self.subTest(entry=entry):
                self.assertTrue(violations("csb1", {"traefik": [entry]}))
        for services in [None, [], {}, {"db": None}, {"db": "5432:5432"}]:
            with self.subTest(services=services):
                self.assertTrue(violations("csb1", services))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--self-test", action="store_true", help="run parser/policy tests without Nix")
    args = parser.parse_args()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PortPolicyTests)
    if not unittest.TextTestRunner(verbosity=1).run(suite).wasSuccessful():
        return 1
    if args.self_test:
        return 0
    try:
        for host in PUBLIC_PORTS:
            services = evaluate_ports(args.repo_root, host)
            errors = violations(host, services)
            if errors:
                print("\n".join(errors), file=sys.stderr)
                return 1
            seeded = copy.deepcopy(services)
            seeded["ops246_exposed_database"] = ["5432:5432"]
            if not violations(host, seeded):
                print(f"{host}: FAIL: seeded public database mapping passed", file=sys.stderr)
                return 1
            count = sum(len(ports) for ports in services.values())
            print(f"{host}: {count} declared ports approved; seeded 5432:5432 rejected")
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"T92 failed: {exc}", file=sys.stderr)
        return 1
    print("T92 ok: csb0/csb1 published-port policy and negative controls")
    return 0


if __name__ == "__main__":
    sys.exit(main())
