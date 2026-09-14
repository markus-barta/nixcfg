#!/usr/bin/env python3
"""NIX-501: exercise legacy Flow behavior from the rendered Traefik rules."""

from __future__ import annotations

import ipaddress
import json
import pathlib
import re
import subprocess
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlsplit


REPO = pathlib.Path(__file__).resolve().parents[1]
EVAL = REPO / "tests/legacy-flow-routing-eval.nix"
HELPER = REPO / "hosts/csb1/legacy-flow-routing.nix"


class ContractError(AssertionError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def evaluate() -> dict[str, Any]:
    result = subprocess.run(
        ["nix-instantiate", "--eval", "--strict", "--json", str(EVAL)],
        text=True,
        capture_output=True,
        check=False,
    )
    require(result.returncode == 0, f"legacy routing evaluation failed: {result.stderr}")
    value = json.loads(result.stdout)
    require(isinstance(value, dict), "legacy routing evaluation must return an object")
    return value


def require_evaluation_failure(expression: str, context: str) -> None:
    result = subprocess.run(
        ["nix-instantiate", "--eval", "--strict", "--expr", expression],
        text=True,
        capture_output=True,
        check=False,
    )
    require(result.returncode != 0, f"{context}: unsafe input evaluated successfully")


@dataclass(frozen=True)
class Request:
    method: str
    host: str
    target: str
    accept: str = "application/json"
    client_ip: str = "198.51.100.10"
    origin: str | None = None
    authorization: str | None = None
    cookie: str | None = None
    body: str | None = None

    @property
    def url(self) -> str:
        return f"https://{self.host}{self.target}"

    @property
    def path(self) -> str:
        return urlsplit(self.url).path

    @property
    def query(self) -> str:
        return urlsplit(self.url).query


@dataclass(frozen=True)
class Outcome:
    action: str
    router: str | None
    target: str | None = None
    location: str | None = None
    service: str | None = None


def values(rule: str, matcher: str) -> list[str]:
    return re.findall(rf"{matcher}\(`([^`]*)`\)", rule)


def router_matches(router: dict[str, Any], request: Request) -> bool:
    rule = router["rule"]
    hosts = values(rule, "Host")
    if hosts and request.host not in hosts:
        return False

    methods = values(rule, "Method")
    if methods and request.method not in methods:
        return False

    header_patterns = re.findall(r"HeaderRegexp\(`Accept`, `([^`]*)`\)", rule)
    if header_patterns and not any(re.search(pattern, request.accept) for pattern in header_patterns):
        return False

    client_ranges = values(rule, "ClientIP")
    if client_ranges and not any(
        ipaddress.ip_address(request.client_ip) in ipaddress.ip_network(network)
        for network in client_ranges
    ):
        return False

    exact_paths = values(rule, "Path")
    path_prefixes = values(rule, "PathPrefix")
    path_regexps = values(rule, "PathRegexp")
    if exact_paths or path_prefixes or path_regexps:
        return (
            request.path in exact_paths
            or any(request.path.startswith(prefix) for prefix in path_prefixes)
            or any(re.search(pattern, request.path) for pattern in path_regexps)
        )
    return True


def expand_redirect(middleware: dict[str, Any], source: str) -> str:
    redirect = middleware.get("redirectRegex")
    require(isinstance(redirect, dict), "redirect middleware is not redirectRegex")
    require(redirect.get("permanent") is False, "legacy redirect must remain temporary")
    match = re.fullmatch(redirect["regex"], source)
    require(match is not None, f"redirect regex did not match {source}")
    return re.sub(
        r"\$\{([0-9]+)\}",
        lambda capture: match.group(int(capture.group(1))) or "",
        redirect["replacement"],
    )


def route(
    routers: dict[str, Any], middlewares: dict[str, Any], request: Request
) -> Outcome:
    matches = [
        (name, router)
        for name, router in routers.items()
        if router_matches(router, request)
    ]
    if not matches:
        return Outcome("no-route", None)
    name, router = max(matches, key=lambda item: item[1]["priority"])
    configured = router.get("middlewares", [])
    if "inspr-legacy-flow-deny" in configured:
        return Outcome("deny", name)

    redirects = [
        middlewares[middleware]
        for middleware in configured
        if middleware in middlewares and "redirectRegex" in middlewares[middleware]
    ]
    if redirects:
        require(len(redirects) == 1, f"{name}: more than one redirect middleware")
        return Outcome(
            "redirect",
            name,
            location=expand_redirect(redirects[0], request.url),
            service=router["service"],
        )

    prefixes = [
        middlewares[middleware]["addPrefix"]["prefix"]
        for middleware in configured
        if middleware in middlewares and "addPrefix" in middlewares[middleware]
    ]
    require(len(prefixes) <= 1, f"{name}: request receives more than one prefix")
    upstream_path = f"{prefixes[0]}{request.path}" if prefixes else request.path
    upstream_target = upstream_path + (f"?{request.query}" if request.query else "")
    return Outcome("proxy", name, target=upstream_target, service=router["service"])


def expect(
    case_id: str,
    routers: dict[str, Any],
    middlewares: dict[str, Any],
    request: Request,
    action: str,
    expected: str | None = None,
) -> Outcome:
    outcome = route(routers, middlewares, request)
    require(outcome.action == action, f"{case_id}: expected {action}, got {outcome}")
    if action == "proxy" and expected is not None:
        require(outcome.target == expected, f"{case_id}: expected upstream {expected}, got {outcome.target}")
    if action == "redirect" and expected is not None:
        require(outcome.location == expected, f"{case_id}: expected Location {expected}, got {outcome.location}")
    return outcome


def main() -> int:
    dynamic = evaluate()
    http = dynamic.get("http")
    require(isinstance(http, dict), "fragment has no http object")
    routers = http.get("routers")
    middlewares = http.get("middlewares")
    services = http.get("services")
    require(isinstance(routers, dict), "fragment has no routers")
    require(isinstance(middlewares, dict), "fragment has no middlewares")
    require(isinstance(services, dict), "fragment has no services")

    # The original 25 audited examples remain regressions. Two prior restrictive
    # assumptions are corrected: /api is a family, and an already-prefixed path
    # passes exactly once instead of entering a host-wide deny/redirect.
    audit_cases = [
        ("PAIMOS-LEGACY-HEALTH", Request("GET", "pm.barta.cm", "/api/health"), "proxy", "/paimos/api/health"),
        ("PAIMOS-LEGACY-HANDOFF-READ", Request("GET", "pm.barta.cm", "/api/external-stage/handoffs/h-1"), "proxy", "/paimos/api/external-stage/handoffs/h-1"),
        ("PAIMOS-LEGACY-HANDOFF-ACCEPT", Request("POST", "pm.barta.cm", "/api/external-stage/handoffs/h-1/accept", body="{}"), "proxy", "/paimos/api/external-stage/handoffs/h-1/accept"),
        ("PAIMOS-LEGACY-HANDOFF-REPORT", Request("POST", "pm.barta.cm", "/api/external-stage/handoffs/h-1/reports", body="{}"), "proxy", "/paimos/api/external-stage/handoffs/h-1/reports"),
        ("PAIMOS-LEGACY-LOGOUT", Request("POST", "pm.barta.cm", "/api/auth/logout", origin="https://pm.barta.cm", cookie="session=opaque"), "proxy", "/paimos/api/auth/logout"),
        ("PAIMOS-LEGACY-PASSWORD-RESET", Request("GET", "pm.barta.cm", "/reset/token-1?next=%2Fsettings", accept="text/html"), "redirect", "https://flow.inspr.at/paimos/reset/token-1?next=%2Fsettings"),
        ("PAIMOS-LEGACY-OIDC-LOGIN-START", Request("GET", "pm.barta.cm", "/api/auth/oidc/login?return=%2Fprojects", accept="text/html"), "redirect", "https://flow.inspr.at/paimos/api/auth/oidc/login?return=%2Fprojects"),
        ("PAIMOS-LEGACY-OIDC-STALE-CALLBACK", Request("GET", "pm.barta.cm", "/api/auth/oidc/callback?code=discard&state=discard", accept="text/html"), "redirect", "https://flow.inspr.at/paimos/api/auth/oidc/login"),
        ("PHAROS-LEGACY-REPORT", Request("POST", "pharos.barta.cm", "/report", body="payload"), "proxy", "/pharos/report"),
        ("PHAROS-LEGACY-AGENT-FAMILY", Request("POST", "pharos.barta.cm", "/agent/actions/claim", authorization="Bearer opaque"), "proxy", "/pharos/agent/actions/claim"),
        ("PHAROS-PRIVATE-MANAGED-INTENT-FETCH", Request("GET", "pharos.barta.cm", "/internal/managed-service-setup-intents/i-1", client_ip="10.0.0.10"), "proxy", "/pharos/internal/managed-service-setup-intents/i-1"),
        ("PHAROS-LEGACY-MAP", Request("GET", "pharos.barta.cm", "/map?scope=all", accept="text/html"), "redirect", "https://flow.inspr.at/pharos/map?scope=all"),
        ("PHAROS-LEGACY-AUTH-LOGIN", Request("GET", "pharos.barta.cm", "/auth/login?return=%2Fmap", accept="text/html"), "redirect", "https://flow.inspr.at/pharos/auth/login?return=%2Fmap"),
        ("PHAROS-LEGACY-LOGOUT-POST", Request("POST", "pharos.barta.cm", "/auth/logout", accept="text/html", origin="https://pharos.barta.cm", cookie="session=opaque", body="csrf=opaque"), "proxy", "/pharos/auth/logout"),
        ("PHAROS-LEGACY-LOGGED-OUT-FOLLOWUP", Request("GET", "pharos.barta.cm", "/pharos/auth/logged-out?reason=user", accept="text/html"), "redirect", "https://flow.inspr.at/pharos/auth/logged-out?reason=user"),
        ("JANUS-PRIVATE-INTERNAL-FAMILY", Request("POST", "vault.barta.cm", "/internal/managed-service-operations/o-1/reconcile", client_ip="10.0.0.20", body="{}"), "proxy", "/janus/internal/managed-service-operations/o-1/reconcile"),
        ("JANUS-LEGACY-MANAGED-SETUP", Request("GET", "vault.barta.cm", "/managed-service/setup?intent=i-1", accept="text/html"), "redirect", "https://flow.inspr.at/janus/managed-service/setup?intent=i-1"),
        ("JANUS-LEGACY-VAULT-NEW", Request("GET", "vault.barta.cm", "/vault/new?provider=one", accept="text/html"), "redirect", "https://flow.inspr.at/janus/vault/new?provider=one"),
        ("JANUS-LEGACY-STALE-LOGOUT", Request("POST", "vault.barta.cm", "/logout", accept="text/html", origin="https://vault.barta.cm", cookie="session=opaque"), "proxy", "/janus/logout"),
        ("PHAROS-LEGACY-MANAGED-RETURN", Request("GET", "pharos.barta.cm", "/managed-service/operations?operation=one", accept="text/html"), "redirect", "https://flow.inspr.at/pharos/managed-service/operations?operation=one"),
        ("SHARED-PAIMOS-OIDC-CALLBACK", Request("GET", "flow.inspr.at", "/paimos/api/auth/oidc/callback?code=c&state=s", accept="text/html"), "no-route", None),
        ("SHARED-PHAROS-AUTH-CALLBACK", Request("GET", "flow.inspr.at", "/pharos/auth/callback?code=c&state=s", accept="text/html"), "no-route", None),
        ("SHARED-JANUS-AUTH-CALLBACK", Request("GET", "flow.inspr.at", "/janus/oidc/callback?code=c&state=s", accept="text/html"), "no-route", None),
        ("SHARED-PUBLIC-INTERNAL-DENIAL", Request("GET", "flow.inspr.at", "/pharos/internal/managed-service-operations"), "no-route", None),
        ("LEGACY-UNLISTED-API-NO-CATCHALL", Request("GET", "pm.barta.cm", "/api/issues?state=open"), "proxy", "/paimos/api/issues?state=open"),
    ]
    require(len(audit_cases) == 25, "the 25 audited regression identifiers changed")
    for case in audit_cases:
        expect(case[0], routers, middlewares, *case[1:])

    behavior_cases = [
        ("CLI-GET", Request("GET", "pm.barta.cm", "/api/projects"), "proxy", "/paimos/api/projects"),
        ("CLI-POST", Request("POST", "pm.barta.cm", "/api/issues", body='{"title":"opaque"}'), "proxy", "/paimos/api/issues"),
        ("CLI-PATCH", Request("PATCH", "pm.barta.cm", "/api/issues/PAI-1", body='{"state":"done"}'), "proxy", "/paimos/api/issues/PAI-1"),
        ("CLI-DELETE", Request("DELETE", "pm.barta.cm", "/api/knowledge/k-1"), "proxy", "/paimos/api/knowledge/k-1"),
        ("API-ACCEPT-HTML", Request("GET", "pm.barta.cm", "/api/schema?format=openapi", accept="text/html"), "proxy", "/paimos/api/schema?format=openapi"),
        ("API-SSE", Request("GET", "pm.barta.cm", "/api/runs/r-1/events", accept="text/event-stream"), "proxy", "/paimos/api/runs/r-1/events"),
        ("PHAROS-JSON", Request("GET", "pharos.barta.cm", "/map/data.json?scope=all", accept="application/json"), "proxy", "/pharos/map/data.json?scope=all"),
        ("PHAROS-ASSET", Request("GET", "pharos.barta.cm", "/assets/vendor/flow-shell/app.js", accept="text/html"), "proxy", "/pharos/assets/vendor/flow-shell/app.js"),
        ("PHAROS-HEALTH-ACCEPT-HTML", Request("GET", "pharos.barta.cm", "/healthz", accept="text/html"), "proxy", "/pharos/healthz"),
        ("JANUS-STATIC", Request("GET", "vault.barta.cm", "/static/app.css", accept="text/css,*/*"), "proxy", "/janus/static/app.css"),
        ("JANUS-BUILD-ACCEPT-HTML", Request("GET", "vault.barta.cm", "/buildz", accept="text/html"), "proxy", "/janus/buildz"),
        ("PAIMOS-ROOT", Request("GET", "pm.barta.cm", "/", accept="text/html,application/xhtml+xml"), "redirect", "https://flow.inspr.at/paimos/"),
        ("PHAROS-DEEP-LINK", Request("HEAD", "pharos.barta.cm", "/services/csb1/traefik?tab=health", accept="text/html"), "redirect", "https://flow.inspr.at/pharos/services/csb1/traefik?tab=health"),
        ("JANUS-DEEP-LINK", Request("GET", "vault.barta.cm", "/knowledge/flows/onboarding", accept="text/html"), "redirect", "https://flow.inspr.at/janus/knowledge/flows/onboarding"),
        ("NONBROWSER-CATCHALL", Request("GET", "pharos.barta.cm", "/unknown-machine-family", accept="application/octet-stream"), "proxy", "/pharos/unknown-machine-family"),
        ("MUTATION-CATCHALL", Request("PUT", "vault.barta.cm", "/ui/custom", accept="text/html", origin="https://vault.barta.cm", body="opaque"), "proxy", "/janus/ui/custom"),
        ("PREFIX-ONCE-PAIMOS", Request("GET", "pm.barta.cm", "/paimos/api/issues"), "proxy", "/paimos/api/issues"),
        ("PREFIX-ONCE-PHAROS", Request("GET", "pharos.barta.cm", "/pharos/report"), "proxy", "/pharos/report"),
        ("PREFIX-ONCE-JANUS", Request("GET", "vault.barta.cm", "/janus/api/posture"), "proxy", "/janus/api/posture"),
        ("PAIMOS-CALLBACK-PREFIXED", Request("GET", "pm.barta.cm", "/paimos/api/auth/oidc/callback?code=c&state=s", accept="text/html"), "redirect", "https://flow.inspr.at/paimos/api/auth/oidc/login"),
        ("PHAROS-CALLBACK-ROOT", Request("GET", "pharos.barta.cm", "/auth/callback?code=c&state=s", accept="text/html"), "redirect", "https://flow.inspr.at/pharos/auth/login"),
        ("PHAROS-CALLBACK-PREFIXED", Request("GET", "pharos.barta.cm", "/pharos/auth/callback?code=c&state=s", accept="text/html"), "redirect", "https://flow.inspr.at/pharos/auth/login"),
        ("JANUS-CALLBACK-ROOT", Request("GET", "vault.barta.cm", "/oidc/callback?code=c&state=s", accept="text/html"), "redirect", "https://flow.inspr.at/janus/login"),
        ("JANUS-CALLBACK-PREFIXED", Request("GET", "vault.barta.cm", "/janus/oidc/callback?code=c&state=s", accept="text/html"), "redirect", "https://flow.inspr.at/janus/login"),
        ("PAIMOS-PUBLIC-INTERNAL-ROOT", Request("GET", "pm.barta.cm", "/internal/control"), "deny", None),
        ("PAIMOS-PUBLIC-INTERNAL-PREFIXED", Request("GET", "pm.barta.cm", "/paimos/internal/control"), "deny", None),
        ("PHAROS-PUBLIC-INTERNAL-ROOT", Request("GET", "pharos.barta.cm", "/internal/managed-service-operations"), "deny", None),
        ("PHAROS-PUBLIC-INTERNAL-PREFIXED", Request("GET", "pharos.barta.cm", "/pharos/internal/managed-service-operations"), "deny", None),
        ("JANUS-PUBLIC-INTERNAL-ROOT", Request("POST", "vault.barta.cm", "/internal/managed-service-operations/o-1/reconcile"), "deny", None),
        ("JANUS-PUBLIC-INTERNAL-PREFIXED", Request("POST", "vault.barta.cm", "/janus/internal/managed-service-operations/o-1/reconcile"), "deny", None),
        ("PHAROS-PRIVATE-INTERNAL-PREFIXED", Request("POST", "pharos.barta.cm", "/pharos/internal/managed-service-operations", client_ip="10.0.0.10"), "proxy", "/pharos/internal/managed-service-operations"),
        ("JANUS-PRIVATE-INTERNAL-PREFIXED", Request("GET", "vault.barta.cm", "/janus/internal/managed-service-host-envelopes/h/o", client_ip="10.0.0.20"), "proxy", "/janus/internal/managed-service-host-envelopes/h/o"),
        ("UNAPPROVED-PRIVATE-CALLER-DENIED", Request("GET", "pharos.barta.cm", "/internal/managed-service-setup-intents/i-1", client_ip="10.0.0.11"), "deny", None),
        ("INTERNAL-BOUNDARY", Request("GET", "pharos.barta.cm", "/internal-other"), "proxy", "/pharos/internal-other"),
        ("PREFIXED-INTERNAL-BOUNDARY", Request("GET", "vault.barta.cm", "/janus/internal-other"), "proxy", "/janus/internal-other"),
        ("ENCODED-INTERNAL-DENIED", Request("GET", "pharos.barta.cm", "/internal%2Fmanaged-service-operations"), "deny", None),
        ("ENCODED-PREFIXED-INTERNAL-DENIED", Request("GET", "vault.barta.cm", "/janus%2Finternal%2Fmanaged-service-operations"), "deny", None),
        ("ENCODED-API-PROXY", Request("GET", "pm.barta.cm", "/api%2Fissues?state=open", accept="text/html"), "proxy", "/paimos/api%2Fissues?state=open"),
        ("ENCODED-CALLBACK-RESTART", Request("GET", "pharos.barta.cm", "/pharos%2Fauth%2Fcallback?code=c&state=s", accept="text/html"), "redirect", "https://flow.inspr.at/pharos/auth/login"),
    ]
    for case in behavior_cases:
        expect(case[0], routers, middlewares, *case[1:])

    # Proxy routes may select only admission and AddPrefix middleware. Thus
    # Host, Origin, body, cookies, Authorization, query, and response semantics
    # remain application-owned. The reused upstream's passHostHeader setting is
    # intentionally outside this fragment and must be checked on integration.
    for name, router in routers.items():
        configured = router.get("middlewares", [])
        if router["service"] == "inspr-legacy-flow-deny":
            continue
        for middleware in configured:
            require(
                middleware == "cloudflarewarp@file"
                or middleware.endswith("-prefix"),
                f"{name}: proxy gained a request/response rewriting middleware",
            )
        require(
            router["service"].startswith("inspr-routing-edge-upstream-")
            and router["service"].endswith("@file"),
            f"{name}: does not reuse the published routing-edge upstream",
        )

    encoded = json.dumps(dynamic, sort_keys=True)
    for forbidden in (
        "stripPrefix",
        "replacePath",
        "replacePathRegex",
        "customRequestHeaders",
        "customResponseHeaders",
        "accessControlAllowOriginList",
        "forwardAuth",
    ):
        require(forbidden not in encoded, f"forbidden routing behavior present: {forbidden}")
    require(
        all("Host(`flow.inspr.at`)" not in router["rule"] for router in routers.values()),
        "legacy fragment must not duplicate shared-origin routing",
    )
    require(
        set(services) == {"inspr-legacy-flow-deny"},
        "legacy fragment must reuse shared upstreams and own only its deny sink",
    )

    helper = json.dumps(str(HELPER))
    require_evaluation_failure(
        f"import {helper} {{ privateSourceRanges = {{ "
        'pharos = [ "203.0.113.1/32" ]; janus = [ "10.0.0.2/32" ]; }; }',
        "public private-caller CIDR",
    )
    require_evaluation_failure(
        f"import {helper} {{ privateSourceRanges = {{ "
        'pharos = [ "10.0.0.1/32" ]; janus = [ ]; }; }',
        "empty private-caller range",
    )

    for app, host, login in (
        ("paimos", "pm.barta.cm", "/api/auth/oidc/login"),
        ("pharos", "pharos.barta.cm", "/auth/login"),
        ("janus", "vault.barta.cm", "/login"),
    ):
        for prefix in ("", "/" + app):
            expect(f"LOGIN-ORIGIN-{app}-{prefix}", routers, middlewares,
                   Request("GET", host, prefix + login + "?return=%2Fprojects"),
                   "redirect", "https://flow.inspr.at/" + app + login + "?return=%2Fprojects")
        expect(f"PREFIXED-BROWSER-{app}", routers, middlewares,
               Request("GET", host, "/" + app + "/settings?tab=one", accept="text/html"),
               "redirect", "https://flow.inspr.at/" + app + "/settings?tab=one")

    for cidr in ("10.0.0.1/0", "10.0.0.1/7", "172.16.0.1/8", "172.31.0.1/11", "192.168.0.1/8", "192.168.0.1/15"):
        require_evaluation_failure(
            f'import {helper} {{ privateSourceRanges = {{ '
            f'pharos = [ "{cidr}" ]; janus = [ "10.0.0.2/32" ]; }}; }}',
            f"CIDR extends outside private address space: {cidr}",
        )

    print(
        f"legacy_flow_routing_audit_cases={len(audit_cases)} "
        f"behavior_cases={len(behavior_cases)} passed"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
