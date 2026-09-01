#!/usr/bin/env python3
"""Equivalence gate for composeStack migrations — OPS-117.

The safety property the whole of OPS-116 rests on. Without it, converting a
1000-line compose file to Nix is an unreviewable rewrite. With it, each host
migration is a *provable no-op*: the rendered spec must parse to exactly the
same data structure as the YAML it replaced, modulo the DNS keys the module now
supplies on purpose.

It compares parsed data, not text — key order, quoting style and YAML-vs-JSON
scalar spelling are all irrelevant and would only produce noise.

What it asserts, and why each one exists:

  * deep equality of the whole spec, after removing the injected DNS keys.
    Anything else that changed is a conversion bug.
  * the compose PROJECT NAME is unchanged. Named volumes are prefixed with it,
    so getting this wrong silently orphans live data. On hsb0/hsb1/hsb8/hsb9 the
    project is literally "docker" (derived from the directory), not the
    hostname, and hsb1 has docker_opus-stream-app riding on it.
  * the set of service, volume and network names is unchanged — a dropped
    service is the loudest possible failure and must not hide inside a diff.
  * no bridge-network service gained `dns`. Those must keep Docker's embedded
    resolver at 127.0.0.11; overriding it breaks container-name resolution.
  * every host-network service DID gain it, or the migration silently undoes
    the OPS-113 fix.

Usage:
    nix shell nixpkgs#yq-go -c ./tests/compose_stack_gate.py hsb1
    nix shell nixpkgs#yq-go -c ./tests/compose_stack_gate.py --all
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
MODULE_OWNED = ("dns", "dns_search")

# Belt and braces: even a directory name from the repo must look like a host
# before it is interpolated into a Nix attribute path.
HOSTNAME_OK = re.compile(r"^[a-z][a-z0-9-]{1,30}$")

RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
OFF = "\033[0m"


def known_hosts() -> list[str]:
    """Host names discovered from the repo layout — a closed set, not user input.

    Everything that reaches a command line below is taken from THIS list, never
    from argv. A caller's argument is only ever used to filter it. That is what
    keeps an arbitrary string out of `nix eval` and `yq` (CodeQL
    py/command-line-injection), and it also turns a typo into a clear error
    instead of an obscure Nix failure.
    """
    found = sorted(p.parent.parent.name for p in REPO.glob("hosts/*/docker/docker-compose.yml"))
    return [h for h in found if HOSTNAME_OK.match(h)]


def run(cmd: list[str]) -> str:
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd[:3])}… failed:\n{result.stderr.strip()}")
    return result.stdout


def original_spec(host: str) -> dict:
    path = REPO / "hosts" / host / "docker" / "docker-compose.yml"
    if not path.exists():
        raise FileNotFoundError(f"no compose file for {host} at {path}")
    spec = json.loads(run(["yq", "-o=json", ".", str(path)]))
    # The x-host-dns anchors are the interim OPS-113 pinning that composeStack
    # replaces. They are extension fields, invisible to compose itself.
    for key in [k for k in spec if k.startswith("x-host-dns")]:
        del spec[key]
    for service in (spec.get("services") or {}).values():
        if isinstance(service, dict):
            for key in MODULE_OWNED:
                service.pop(key, None)
    return spec


def rendered_spec(host: str) -> dict:
    attr = f".#nixosConfigurations.{host}.config.nixcfg.composeStack.renderedSpec"
    return json.loads(run(["nix", "eval", "--json", attr]))


def diff_paths(expected, actual, path: str = "") -> list[str]:
    """Every leaf where the two differ, as dotted paths. Empty means identical."""
    if type(expected) is not type(actual):
        return [f"{path}: type {type(expected).__name__} -> {type(actual).__name__}"]
    if isinstance(expected, dict):
        out: list[str] = []
        for key in sorted(set(expected) | set(actual)):
            sub = f"{path}.{key}" if path else key
            if key not in expected:
                out.append(f"{sub}: ADDED ({actual[key]!r})")
            elif key not in actual:
                out.append(f"{sub}: REMOVED ({expected[key]!r})")
            else:
                out += diff_paths(expected[key], actual[key], sub)
        return out
    if isinstance(expected, list):
        if len(expected) != len(actual):
            return [f"{path}: list length {len(expected)} -> {len(actual)}"]
        out = []
        for index, (e, a) in enumerate(zip(expected, actual)):
            out += diff_paths(e, a, f"{path}[{index}]")
        return out
    return [] if expected == actual else [f"{path}: {expected!r} -> {actual!r}"]


def check(host: str) -> bool:
    expected = original_spec(host)
    actual_full = rendered_spec(host)
    actual = json.loads(json.dumps(actual_full))  # deep copy

    failures: list[str] = []
    notes: list[str] = []

    services = actual.get("services") or {}
    host_net = [n for n, s in services.items() if (s or {}).get("network_mode") == "host"]
    other = [n for n, s in services.items() if (s or {}).get("network_mode") != "host"]

    # DNS injection: required on host-network, forbidden everywhere else.
    for name in host_net:
        if "dns" not in services[name]:
            failures.append(f"host-network service {name!r} did NOT get dns injected")
    for name in other:
        for key in MODULE_OWNED:
            if key in (services[name] or {}):
                failures.append(
                    f"non-host-network service {name!r} got {key} — this breaks "
                    f"container-name resolution via 127.0.0.11"
                )

    injected = {}
    for name in host_net:
        for key in MODULE_OWNED:
            if key in services[name]:
                injected.setdefault(key, services[name][key])
            services[name].pop(key, None)

    # Project name — the one that orphans live data if wrong.
    exp_name = expected.get("name")
    act_name = actual.get("name")
    if exp_name != act_name:
        failures.append(f"compose `name:` changed: {exp_name!r} -> {act_name!r}")

    for section in ("services", "volumes", "networks"):
        exp_keys = set((expected.get(section) or {}).keys())
        act_keys = set((actual.get(section) or {}).keys())
        if exp_keys != act_keys:
            failures.append(
                f"{section} set changed: missing={sorted(exp_keys - act_keys)} "
                f"extra={sorted(act_keys - exp_keys)}"
            )

    for line in diff_paths(expected, actual):
        failures.append(f"spec differs at {line}")

    if injected:
        notes.append(f"injected into {len(host_net)} host-network service(s): {injected}")

    label = f"{host:6}"
    if failures:
        print(f"{RED}FAIL{OFF} {label} {len(failures)} problem(s)")
        for item in failures[:20]:
            print(f"       {item}")
        if len(failures) > 20:
            print(f"       … and {len(failures) - 20} more")
        return False

    print(f"{GREEN}OK{OFF}   {label} spec is semantically identical")
    for note in notes:
        print(f"       {YELLOW}expected delta{OFF}: {note}")
    return True


def section(text: str, start: str, end: str) -> str:
    """Return one named documentation section, failing closed on drift."""
    if text.count(start) != 1 or text.count(end) != 1:
        raise ValueError(f"expected one {start!r} and one {end!r}")
    if text.index(start) >= text.index(end):
        raise ValueError(f"expected {start!r} before {end!r}")
    return text.split(start, 1)[1].split(end, 1)[0]


def markdown_table_services(path: Path, start: str, end: str) -> list[str]:
    body = section(path.read_text(), start, end)
    return re.findall(r"^\|\s*(?:\*\*)?([a-z0-9][a-z0-9-]*)(?:\*\*)?\s*\|", body, re.M)


def markdown_list_services(path: Path) -> list[str]:
    test = section(
        path.read_text(),
        "### Test 2: All Services Running",
        "### Test 3: Key Services Responding",
    )
    body = section(test, "**Expected Results:**", "**Status:**")
    return re.findall(r"^- ([a-z0-9][a-z0-9-]*)$", body, re.M)


def shell_array_services(path: Path) -> list[str]:
    text = path.read_text()
    match = re.search(r"EXPECTED_SERVICES=\(\n(.*?)\n\)", text, re.S)
    if not match:
        raise ValueError(f"{path}: EXPECTED_SERVICES array not found")
    return re.findall(r'^\s+"([a-z0-9][a-z0-9-]*)"$', match.group(1), re.M)


def check_hsb1_documentation() -> bool:
    """Keep every operator-facing hsb1 service inventory on the rendered spec."""
    expected = set((rendered_spec("hsb1").get("services") or {}).keys())
    host = REPO / "hosts" / "hsb1"
    surfaces = {
        "RUNBOOK container table": markdown_table_services(
            host / "docs" / "RUNBOOK.md", "### Container Overview", "### Key Paths"
        ),
        "SMARTHOME container table": markdown_table_services(
            host / "docs" / "SMARTHOME.md", "## 🐳 Docker Services", "## 📁 File Locations"
        ),
        "README container table": markdown_table_services(
            host / "README.md", "Services use host or bridge networking", "## Native Services"
        ),
        "T04 manual inventory": markdown_list_services(host / "tests" / "T04-docker-services.md"),
        "T04 executable inventory": shell_array_services(host / "tests" / "T04-docker-services.sh"),
    }
    failures: list[str] = []
    for label, actual in surfaces.items():
        actual_set = set(actual)
        duplicates = sorted(name for name in actual_set if actual.count(name) > 1)
        if actual_set != expected or duplicates:
            failures.append(
                f"{label}: missing={sorted(expected - actual_set)} "
                f"extra={sorted(actual_set - expected)} duplicates={duplicates}"
            )

    retired = ("health-pixoo", "watchtower-weekly", "watchtower-pixdcon")
    for path in (
        host / "README.md",
        host / "docs" / "RUNBOOK.md",
        host / "docs" / "SMARTHOME.md",
        host / "tests" / "T04-docker-services.md",
        host / "tests" / "T04-docker-services.sh",
    ):
        text = path.read_text()
        for name in retired:
            if name in text:
                failures.append(f"{path.relative_to(REPO)} still names retired service {name}")

    if failures:
        print(f"{RED}FAIL{OFF} hsb1  documentation inventory drift")
        for item in failures:
            print(f"       {item}")
        return False

    print(f"{GREEN}OK{OFF}   hsb1  five documentation inventories match {len(expected)} services")
    return True


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__, file=sys.stderr)
        return 2

    available = known_hosts()
    if args == ["--all"]:
        hosts = available
    else:
        # Filter the discovered set by the request; never pass argv through.
        requested = set(args)
        hosts = [h for h in available if h in requested]
        unknown = sorted(requested - set(available))
        if unknown:
            print(f"{RED}ERR{OFF}  unknown host(s): {', '.join(unknown)}", file=sys.stderr)
            print(f"      known: {', '.join(available)}", file=sys.stderr)
            return 2

    ok = True
    if args == ["--all"]:
        try:
            ok &= check_hsb1_documentation()
        except Exception as error:  # noqa: BLE001 — malformed docs must fail this gate
            print(f"{RED}ERR{OFF}  hsb1  documentation gate: {error}")
            ok = False
    for host in hosts:
        try:
            ok &= check(host)
        except Exception as error:  # noqa: BLE001 — a host without the module yet is a skip
            message = str(error).splitlines()[0] if str(error) else type(error).__name__
            if "composeStack" in message or "attribute" in message:
                print(f"{YELLOW}SKIP{OFF} {host:6} not migrated yet ({message[:60]})")
            else:
                print(f"{RED}ERR{OFF}  {host:6} {message[:100]}")
                ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
