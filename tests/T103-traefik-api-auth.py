#!/usr/bin/env python3
"""OPS-365: Traefik API is not served on public entrypoints.

Offline evaluation and synthetic renderer fixtures; no NixOS builds or secrets.
Live probes are opt-in and report request identities and status codes only.
Requires Nix, Ruby/Psych, yq and the pinned public doctrine Git objects.
"""

from __future__ import annotations

import argparse
import contextlib
import copy
import http.client
import io
import json
import os
import pathlib
import re
import shlex
import subprocess
import sys
import tempfile
from typing import Any, Callable
from unittest import mock

REPO = pathlib.Path(__file__).resolve().parents[1]
ROUTER = "traefik.http.routers."
MIDDLEWARE = "traefik.http.middlewares."
HOSTS = {"csb0": "cs0.barta.cm", "csb1": "cs1.barta.cm"}
LIVE_PATHS = ("/api/rawdata", "/api/version", "/api/http/routers", "/dashboard/")
SYNTHETIC_COOKIE = "_oauth2_proxy=ops365-synthetic-invalid-session"
LOCAL_ENTRYPOINT = "traefik-api"
LOCAL_ROUTER = "traefik-api-local"


class ContractError(AssertionError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def run(argv: list[str], data: str | None = None, **kwargs: Any) -> str:
    result = subprocess.run(argv, input=data, capture_output=True, text=True,
                            check=False, **kwargs)
    # Never echo evaluated configuration or subprocess output on failure.
    require(result.returncode == 0, f"{pathlib.Path(argv[0]).name}: offline command failed")
    return result.stdout


def evaluate(path: pathlib.Path, projection: str) -> dict[str, Any]:
    value = json.loads(run(["nix", "eval", "--offline", "--json", "--file", str(path),
                            "--apply", projection]))
    require(isinstance(value, dict), f"{path.name}: expected an object")
    return value


def compose(path: pathlib.Path) -> dict[str, Any]:
    # Avoid realizing interpolated store paths in unrelated volumes.
    return evaluate(path, """spec: { services = builtins.mapAttrs (_: service: {
      labels = service.labels or []; image = service.image or "";
      command = service.command or []; ports = service.ports or [];
      environment = service.environment or {}; networks = service.networks or [];
      network_mode = service.network_mode or "";
    }) spec.services; }""")


def yaml_document(source: str) -> dict[str, Any]:
    value = json.loads(run(["ruby", "-rjson", "-rpsych", "-e",
                           "puts JSON.generate(Psych.safe_load(STDIN.read, aliases: false))"],
                          source))
    require(isinstance(value, dict), "expected a YAML object")
    return value


def label_map(service: dict[str, Any]) -> dict[str, str]:
    raw = service.get("labels", [])
    if isinstance(raw, dict):
        entries = list(raw.items())
    else:
        require(isinstance(raw, list), "labels must be a list or map")
        entries = []
        for label in raw:
            require(isinstance(label, str), "label must be a string")
            key, separator, value = label.partition("=")
            require(bool(separator), "label is missing '='")
            entries.append((key, value))
    result: dict[str, str] = {}
    for key, value in entries:
        require(isinstance(key, str) and isinstance(value, str), "invalid label")
        key = key.lower()
        if key.startswith((ROUTER, MIDDLEWARE)):
            require(key not in result, "duplicate routing label key")
        result[key] = value
    return result


def routing_labels(spec: dict[str, Any]) -> dict[str, str]:
    labels: dict[str, str] = {}
    for service in spec["services"].values():
        for key, value in label_map(service).items():
            if key.startswith((ROUTER, MIDDLEWARE)):
                require(key not in labels or labels[key] == value,
                        "conflicting routing label")
                labels[key] = value
    return labels


def docker_routers(spec: dict[str, Any]) -> dict[str, Any]:
    routers: dict[str, Any] = {}
    for key, value in routing_labels(spec).items():
        if key.startswith(ROUTER):
            name, separator, field = key[len(ROUTER):].partition(".")
            require(bool(separator), "invalid router label")
            routers.setdefault(name, {})[field] = value
    for router in routers.values():
        router["entryPoints"] = [entry.strip() for entry in
                                 router.get("entrypoints", "").split(",") if entry.strip()]
    return routers


def loopback_port(static: dict[str, Any], name: str) -> int:
    address = static.get("entryPoints", {}).get(name, {}).get("address", "")
    match = re.fullmatch(r"127\.0\.0\.1:([0-9]{1,5})(?:/tcp)?", address)
    require(match is not None and 0 < int(match[1]) <= 65535,
            "API entrypoint must bind to 127.0.0.1")
    return int(match[1])


def port_contains(value: Any, target: int) -> bool:
    if value is None:
        return False
    first, _, last = str(value).partition("-")
    return int(first) <= target <= int(last or first)


def api_values(value: Any) -> int:
    if isinstance(value, dict):
        return sum(api_values(item) for item in value.values())
    if isinstance(value, list):
        return sum(api_values(item) for item in value)
    return int(value == "api@internal")


def verify_boundary(spec: dict[str, Any], static: dict[str, Any],
                    fragments: dict[str, Any]) -> int:
    api = static.get("api", {})
    require(isinstance(api, dict) and api.get("insecure", False) is False,
            "api.insecure must be absent or false")
    if static or "traefik" in spec["services"]:
        require(api.get("dashboard") is False, "api.dashboard must remain false")
    routers = {"docker": docker_routers(spec)}
    for source, fragment in fragments.items():
        routers[source] = fragment.get("http", {}).get("routers", {})
        require(api_values(fragment) == sum(router.get("service") == "api@internal"
                                           for router in routers[source].values()),
                "api@internal must be a direct HTTP router service")
    require(api_values([label_map(service) for service in spec["services"].values()])
            == sum(router.get("service") == "api@internal"
                   for router in routers["docker"].values()),
            "api@internal must be a direct Docker router service")
    ports = {8080}
    count = 0
    for provider in routers.values():
        for router in provider.values():
            if router.get("service") != "api@internal":
                continue
            count += 1
            entries = router.get("entryPoints", [])
            require(isinstance(entries, list) and bool(entries),
                    "API router must name explicit entrypoints")
            for entry in entries:
                ports.add(loopback_port(static, entry))
    # Also guard the reserved operator listener when no router references it.
    if LOCAL_ENTRYPOINT in static.get("entryPoints", {}):
        ports.add(loopback_port(static, LOCAL_ENTRYPOINT))
    for name, service in spec["services"].items():
        if name != "traefik" and not re.search(r"(^|/)traefik(?:[:@]|$)",
                                               service.get("image", "")):
            continue
        require(service.get("network_mode", "") in ("", "bridge"),
                "Traefik must retain its container network namespace")
        command = service.get("command", [])
        args = shlex.split(command) if isinstance(command, str) else command
        for index, arg in enumerate(args):
            option = arg.lower().split("=", 1)[0]
            if option == "--api.insecure":
                value = arg.partition("=")[2] if "=" in arg else (
                    args[index + 1] if index + 1 < len(args) else "true")
                require(value.lower() == "false", "insecure API CLI flag")
            require(not option.startswith("--entrypoints."),
                    "entrypoint CLI overrides bypass the static contract")
        environment = service.get("environment", {})
        if isinstance(environment, list):
            environment = dict(entry.split("=", 1) if "=" in entry else (entry, "")
                               for entry in environment)
        require(str(environment.get("TRAEFIK_API_INSECURE", "false")).lower() == "false",
                "insecure API environment override")
        require(not any(key.startswith("TRAEFIK_ENTRYPOINTS_") for key in environment),
                "entrypoint environment overrides bypass the static contract")
        for port in service.get("ports", []):
            if isinstance(port, dict):
                candidates = (port.get("published"), port.get("target"))
            else:
                candidates = str(port).split("/")[0].split(":")[-2:]
            require(not any(port_contains(value, target) for value in candidates
                            for target in ports), "API port is published")
    return count


def hostdash_rule(host: str) -> str:
    return (f"Host(`{HOSTS[host]}`) && "
            "!(PathPrefix(`/api`) || PathPrefix(`/dashboard`))")


def verify_hostdash(host: str, spec: dict[str, Any]) -> None:
    labels = routing_labels(spec)
    router = f"hostdash-{host}"
    auth = f"hostdash-auth-{host}"
    require(labels.get(f"{ROUTER}{router}.rule") == hostdash_rule(host),
            "HostDash must exclude API/dashboard paths")
    require(labels.get(f"{ROUTER}{router}.middlewares") == auth + "@docker",
            "HostDash exact middleware chain changed")
    require(labels.get(f"{MIDDLEWARE}{auth}.forwardauth.address")
            == "http://hostdash-auth:4180/", "HostDash forwardAuth backend changed")
    # Check both the middleware's defining service and its actual HTTP backend.
    participants = [spec["services"]["traefik"], spec["services"]["hostdash-auth"]]
    participants += [service for service in spec["services"].values()
                     if f"{MIDDLEWARE}{auth}.forwardauth.address" in label_map(service)]
    networks = [set(service.get("networks", [])) for service in participants]
    require(bool(set.intersection(*networks)), "forwardAuth must share a Traefik network")


def pinned_compiler(root: pathlib.Path, cached_source: pathlib.Path | None) -> pathlib.Path:
    """Read exact public source from Git, including uninitialized worktrees."""
    locked = json.loads((REPO / "flake.lock").read_text())["nodes"]["inspr-modules"]["locked"]
    pin = locked["rev"]
    if cached_source is not None:
        require(run(["nix", "hash", "path", str(cached_source)]).strip() == locked["narHash"],
                "cached routing source differs from flake.lock")
        return cached_source / "packages" / "routing-edge"
    common = pathlib.Path(run(["git", "-C", str(REPO), "rev-parse", "--git-common-dir"]).strip())
    if not common.is_absolute():
        common = (REPO / common).resolve()
    repository = common / "modules" / "doctrine"
    git = ["git", "--git-dir", str(repository)]
    paths = run(git + ["ls-tree", "-r", "--name-only", pin, "--",
                       "packages/routing-edge/routing_edge", "contracts/routing"]).splitlines()
    paths = [path for path in paths if path.endswith(".py") and "/fixtures/" not in path]
    require(bool(paths), "pinned routing compiler Git objects unavailable; initialize doctrine")
    for path in paths:
        destination = root / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(run(git + ["show", f"{pin}:{path}"]))
    return root / "packages" / "routing-edge"


def rendered_fragments(cached_source: pathlib.Path | None) -> dict[str, Any]:
    """Render output shapes offline with a synthetic token and pinned compiler."""
    host = REPO / "hosts/csb1"
    flow = evaluate(host / "shared-flow.nix", "s: { inherit (s) contract; routingEdgeActivation.upstreams = s.routingEdgeActivation.upstreams; }")
    activation = flow["routingEdgeActivation"]
    configuration = (host / "configuration.nix").read_text()
    for setting in ('entrypoint.name = "web-secure";',
                    'certificateResolver = "public-http";',
                    'resourceNamespace = "inspr-routing-edge";'):
        require(setting in configuration, "shared Flow compiler selector changed")
    legacy = evaluate(host / "legacy-flow-routing.nix", """f: f {
      privateSourceRanges = (import ./hosts/csb1/shared-flow.nix).privateSourceRanges;
    }""")
    redirect = evaluate(host / "ppm-aeon-redirect-routing.nix", "f: f {}")
    # Same recursive update as configuration.nix, over these disjoint resources.
    for section, resources in redirect["http"].items():
        legacy.setdefault("http", {}).setdefault(section, {}).update(resources)
    with tempfile.TemporaryDirectory(prefix="ops365-render-") as directory:
        work = pathlib.Path(directory)
        compiler = pinned_compiler(work / "source", cached_source)
        deployment = {"mode": "external-file-provider", "entrypoint": {"name": "web-secure"},
                      "certificate_resolver": "public-http", "resource_namespace": "inspr-routing-edge",
                      "upstreams": activation["upstreams"]}
        compiled = json.loads(run([sys.executable, "-B", "-c", """
import json, sys
sys.path.insert(0, sys.argv[1])
from routing_edge.compile import compile_edge
contract, deployment = json.load(sys.stdin)
result = compile_edge(contract, deployment)
assert result.ok
print(json.dumps(result.dynamic))
""", str(compiler)], json.dumps([flow["contract"], deployment])))
        environment = {"PATH": os.environ.get("PATH", os.defpath), "ENTER_EDGE_TOKEN": "0" * 64}
        edge = work / "edge.yml"
        run(["bash", str(host / "scripts/render-inspr-edge-config.sh"), str(edge)], env=environment)
        compiled_path, legacy_path, merged_path = [work / name for name in
                                                  ("compiled.json", "legacy.json", "merged.yml")]
        compiled_path.write_text(json.dumps(compiled))
        legacy_path.write_text(json.dumps(legacy))
        run(["bash", str(host / "scripts/render-shared-flow-config.sh"), str(merged_path),
             str(compiled_path), str(legacy_path), "inspr-routing-edge"])
        return {"edge-renderer": yaml_document(edge.read_text()),
                "shared-flow-compiler": compiled, "shared-flow-legacy": legacy,
                "shared-flow-renderer": yaml_document(merged_path.read_text())}


def expect_rejected(check: Callable[[], Any], message: str) -> None:
    try:
        check()
    except ContractError as error:
        require(message in str(error), "mutation failed for an unrelated reason")
        return
    raise ContractError("mutation escaped the gate: " + message)


def verify_mutations(host: str, spec: dict[str, Any], static: dict[str, Any],
                     fragments: dict[str, Any]) -> int:
    count = 0

    def reject(change: Callable[..., None], message: str) -> None:
        nonlocal count
        mutated_spec, mutated_static, mutated_fragments = copy.deepcopy((spec, static, fragments))
        change(mutated_spec, mutated_static, mutated_fragments)
        expect_rejected(lambda: verify_boundary(mutated_spec, mutated_static, mutated_fragments), message)
        count += 1

    def add_label_router(s: Any, t: Any, f: Any, entries: str | None) -> None:
        labels = label_map(s["services"]["traefik"])
        labels[ROUTER + "mutation.service"] = "api@internal"
        if entries is not None:
            labels[ROUTER + "mutation.entrypoints"] = entries
        s["services"]["traefik"]["labels"] = labels

    for entry in ("web", "web-secure", "unknown", "traefik-api,web-secure", None):
        reject(lambda s, t, f: add_label_router(s, t, f, entry),
               "explicit entrypoints" if entry is None else "bind to 127.0.0.1")
    for source in fragments:
        for entries in (["web"], ["web-secure"], ["unknown"], [LOCAL_ENTRYPOINT, "web"], []):
            def add_file_router(s: Any, t: Any, f: Any) -> None:
                f[source].setdefault("http", {}).setdefault("routers", {})["mutation"] = {
                    "service": "api@internal", "entryPoints": entries}
            reject(add_file_router, "explicit entrypoints" if not entries else "bind to 127.0.0.1")
    for address in (":8099", "0.0.0.0:8099", "[::]:8099", "localhost:8099", "127.0.0.2:8099"):
        reject(lambda s, t, f: t["entryPoints"][LOCAL_ENTRYPOINT].update(address=address),
               "bind to 127.0.0.1")
    for publication in ("8099:8099", "127.0.0.1:9000:8099", "[::1]:8090-8100:8090-8100",
                        {"published": 9000, "target": 8099}, "8080:8080"):
        reject(lambda s, t, f: s["services"]["traefik"]["ports"].append(publication),
               "API port is published")
    reject(lambda s, t, f: t["api"].update(insecure=True), "api.insecure")
    reject(lambda s, t, f: t["api"].update(dashboard=True), "api.dashboard")
    for command in ("--api.insecure", ["--api.insecure=true"], ["--api.insecure", "true"]):
        reject(lambda s, t, f: s["services"]["traefik"].update(command=command), "insecure API CLI")
    reject(lambda s, t, f: s["services"]["traefik"].update(environment={"TRAEFIK_API_INSECURE": "true"}),
           "insecure API environment")
    reject(lambda s, t, f: s["services"]["traefik"].update(network_mode="host"), "container network namespace")
    reject(lambda s, t, f: s["services"]["traefik"].update(command="--entrypoints.traefik-api.address=:8099"),
           "entrypoint CLI overrides")
    reject(lambda s, t, f: s["services"]["traefik"].update(environment={"TRAEFIK_ENTRYPOINTS_TRAEFIK_API_ADDRESS": ":8099"}),
           "entrypoint environment overrides")
    reject(lambda s, t, f: f["dynamic"].setdefault("http", {}).setdefault("services", {}).update(
        alias={"weighted": {"services": [{"name": "api@internal"}]}}), "direct HTTP router")
    labels = routing_labels(spec)
    for key, value, message in (
        (ROUTER + f"hostdash-{host}.rule", f"Host(`{HOSTS[host]}`)", "exclude API/dashboard"),
        (ROUTER + f"hostdash-{host}.middlewares", "", "exact middleware chain"),
        (ROUTER + f"hostdash-{host}.middlewares", f"hostdash-auth-{host}@docker,extra@docker", "exact middleware chain"),
        (MIDDLEWARE + f"hostdash-auth-{host}.forwardauth.address", "http://other:4180/", "forwardAuth backend"),
    ):
        require(key in labels, "HostDash mutation label missing")
        mutant = copy.deepcopy(spec)
        for service in mutant["services"].values():
            current = label_map(service)
            if key in current:
                current[key] = value
                service["labels"] = current
        expect_rejected(lambda: verify_hostdash(host, mutant), message)
        count += 1
    for name in ("hostdash", "hostdash-auth"):
        mutant = copy.deepcopy(spec)
        mutant["services"][name]["networks"] = ["disconnected-fixture"]
        expect_rejected(lambda: verify_hostdash(host, mutant), "share a Traefik network")
        count += 1
    return count


def verify_equivalence(path: pathlib.Path, current: dict[str, Any], revision: str,
                       static: dict[str, Any], dynamic: dict[str, Any]) -> None:
    relative = path.relative_to(REPO).as_posix()
    previous_source = run(["git", "-C", str(REPO), "show", f"{revision}:{relative}"])
    with tempfile.NamedTemporaryFile(mode="w", suffix=".nix", prefix=".ops365-",
                                     dir=path.parent) as baseline:
        baseline.write(previous_source)
        baseline.flush()
        previous = compose(pathlib.Path(baseline.name))
    host = path.parents[1].name
    expected = copy.deepcopy(previous)
    labels = label_map(expected["services"]["traefik"])
    removed = [key for key in labels if key.startswith(ROUTER + "traefik.")]
    require(len(removed) == 6, "unexpected baseline API router labels")
    expected["services"]["traefik"]["labels"] = {key: value for key, value in labels.items() if key not in removed}
    labels = label_map(expected["services"]["hostdash"])
    require(labels[ROUTER + f"hostdash-{host}.rule"] == f"Host(`{HOSTS[host]}`)",
            "unexpected baseline HostDash rule")
    labels[ROUTER + f"hostdash-{host}.rule"] = hostdash_rule(host)
    expected["services"]["hostdash"]["labels"] = labels
    normalized = copy.deepcopy(current)
    for name in ("traefik", "hostdash"):
        normalized["services"][name]["labels"] = label_map(normalized["services"][name])
    require(normalized == expected, "Compose differs beyond API removal and HostDash path exclusions")
    for filename, value in (("static.yml", static), ("dynamic.yml", dynamic)):
        baseline_document = yaml_document(run(["git", "-C", str(REPO), "show",
            f"{revision}:hosts/{host}/docker/traefik/{filename}"]))
        normalized_document = copy.deepcopy(value)
        if filename == "static.yml":
            require(normalized_document["entryPoints"].pop(LOCAL_ENTRYPOINT)
                    == {"address": "127.0.0.1:8099"}, "operator listener changed")
        else:
            require(normalized_document["http"]["routers"].pop(LOCAL_ROUTER) == {
                "rule": "PathPrefix(`/api`)", "entryPoints": [LOCAL_ENTRYPOINT],
                "service": "api@internal"}, "operator router changed")
        require(normalized_document == baseline_document, "unrelated static/dynamic configuration changed")
    print(f"{host}: evaluated equivalence=ok (API labels removed, HostDash paths excluded, loopback route added)")


def verify_live() -> bool:
    passed = True
    for host in HOSTS.values():
        for path in LIVE_PATHS:
            for method in ("GET", "HEAD"):
                for audience in ("anonymous", "synthetic-cookie"):
                    connection = None
                    status = 0
                    try:
                        connection = http.client.HTTPSConnection(host, timeout=10)
                        headers = {"User-Agent": "nixcfg-OPS-365", "Connection": "close"}
                        if audience == "synthetic-cookie":
                            headers["Cookie"] = SYNTHETIC_COOKIE
                        connection.request(method, path, headers=headers)
                        status = connection.getresponse().status
                        # No body/header reads, redirects or real cookies.
                    except (OSError, http.client.HTTPException):
                        pass
                    finally:
                        if connection is not None:
                            connection.close()
                    print(f"{host} {audience} {method} {path} {status:03d}")
                    passed = status in (404, 401, 403) and passed
    return passed


def verify_live_fixtures() -> None:
    requests: list[tuple[str, str, str, str]] = []

    class Connection:
        def __init__(self, host: str, timeout: int) -> None:
            self.host = host

        def request(self, method: str, path: str, headers: dict[str, str]) -> None:
            audience = "synthetic-cookie" if "Cookie" in headers else "anonymous"
            require(headers.get("Cookie", SYNTHETIC_COOKIE) == SYNTHETIC_COOKIE,
                    "live probe used a real cookie")
            require(set(headers) <= {"User-Agent", "Connection", "Cookie"}, "unexpected live headers")
            requests.append((self.host, audience, method, path))

        def getresponse(self) -> Any:
            return self

        def getheader(self, *args: Any) -> None:
            raise ContractError("live probe read a response header")

        def read(self, *args: Any) -> None:
            raise ContractError("live probe read a response body")

        def close(self) -> None:
            pass

    expected = {(host, audience, method, path) for host in HOSTS.values()
                for audience in ("anonymous", "synthetic-cookie") for method in ("GET", "HEAD")
                for path in LIVE_PATHS}
    for status in (404, 401, 403, 200, 204, 302, 301, 500):
        Connection.status = status
        requests.clear()
        output = io.StringIO()
        with mock.patch.object(http.client, "HTTPSConnection", Connection):
            with contextlib.redirect_stdout(output):
                result = verify_live()
        require(result is (status in (404, 401, 403)), f"live fixture failed for HTTP {status}")
        require(set(requests) == expected and len(requests) == 32, "live request coverage changed")
        require(output.getvalue().splitlines() == [f"{' '.join(request)} {status:03d}" for request in requests],
                "live output must contain only request identities and statuses")
    with mock.patch.object(http.client, "HTTPSConnection", side_effect=OSError):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            require(verify_live() is False, "connection failure passed")
        require(len(output.getvalue().splitlines()) == 32
                and all(line.endswith(" 000") for line in output.getvalue().splitlines()),
                "connection failure output changed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="also probe public hosts; statuses only")
    parser.add_argument("--compare-ref", metavar="REV", help="compare permitted Compose/static/dynamic changes")
    parser.add_argument("--routing-source", type=pathlib.Path,
                        help="offline cached public source, verified against flake.lock narHash")
    args = parser.parse_args()
    rendered = rendered_fragments(args.routing_source)
    specs = sorted(REPO.glob("**/compose-spec.nix"))
    require(bool(specs), "no Compose specs discovered")
    static_paths = sorted(REPO.glob("**/traefik/static.y*ml"))
    require(bool(static_paths), "no static configurations discovered")
    statics = {path.parents[2].name: yaml_document(path.read_text()) for path in static_paths}
    files: dict[str, dict[str, Any]] = {}
    for path in sorted(REPO.glob("**/traefik/dynamic.y*ml")):
        files.setdefault(path.parents[2].name, {})["dynamic"] = yaml_document(path.read_text())
    require(set(statics) == set(files), "static/file-provider inventory mismatch")
    files["csb1"].update(rendered)
    seen: set[str] = set()
    mutations = api_routers = 0
    for path in specs:
        host = path.parents[1].name
        spec = compose(path)
        api_routers += verify_boundary(spec, statics.get(host, {}), files.get(host, {}))
        if host in HOSTS:
            seen.add(host)
            verify_hostdash(host, spec)
            require(not any(key.startswith(ROUTER + "traefik.") for key in routing_labels(spec)),
                    "public traefik router labels remain")
            require(files[host]["dynamic"]["http"]["routers"].get(LOCAL_ROUTER) == {
                "rule": "PathPrefix(`/api`)", "entryPoints": [LOCAL_ENTRYPOINT],
                "service": "api@internal"}, "loopback operator router missing or changed")
            mutations += verify_mutations(host, spec, statics[host], files[host])
            if args.compare_ref:
                verify_equivalence(path, spec, args.compare_ref, statics[host], files[host]["dynamic"])
    require(seen == set(HOSTS), "expected host specs missing")
    require(set(statics) <= {path.parents[1].name for path in specs}, "unscanned static configuration")
    verify_live_fixtures()
    print(f"T103: static=ok specs={len(specs)} loopback_api_routers={api_routers} "
          f"static_files={len(statics)} rendered_fragments={len(rendered)} "
          f"mutations={mutations} live_fixture=ok")
    return (0 if verify_live() else 1) if args.live else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ContractError, OSError, ValueError, KeyError) as error:
        print(f"T103: {error}", file=sys.stderr)
        raise SystemExit(1)
