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
RELEASE_SET = REPO / "hosts/csb0/joedesk-release.json"
IDENTITY_HEADERS = ("X-Auth-Request-User", "X-Auth-Request-Email", "X-Auth-Request-Preferred-Username",
                    "X-Auth-Request-Groups", "X-Forwarded-User", "X-Forwarded-Email", "X-Forwarded-Preferred-Username")
SPOOF_HEADERS = {variant: "joedesk-smoke-spoof" for name in IDENTITY_HEADERS
                 for variant in (name, name.replace("-", "_"), name.replace("-", "."))}
SPOOF_HEADERS["X-Forwarded_User"] = "joedesk-smoke-spoof"
REDIRECT_STATUSES = {301}
AUTH_FAILURE_STATUSES = {301, 302, 303, 307, 308, 401, 403}


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
    health = "traefik.http.routers.joe-health-csb0."
    results = "traefik.http.routers.joe-results-inbox-csb0."
    strip = "joe-identity-strip-csb0@docker"
    host = "Host(`cs0.barta.cm`)"
    routers = {key.split(".")[3] for key in labels if key.startswith("traefik.http.routers.")}
    require(routers == {"joe-csb0", "joe-csb0-slash", "joe-inbox-csb0", "joe-health-csb0", "joe-results-inbox-csb0"}, "unexpected JoeDesk router/exemption")
    require(labels.get(health + "rule") == host + " && Path(`/joe/healthz`) && (Method(`GET`) || Method(`HEAD`))", "health must use exact Path and single-argument v3 Method matchers")
    require(labels.get(health + "middlewares") == strip, "health must strip identity without SSO")
    require(int(labels[health + "priority"]) > max(int(labels[router + "priority"]) for router in (bare, main, inbox, results)), "health must outrank every Joe router")
    for header in IDENTITY_HEADERS:
        require(labels.get("traefik.http.middlewares.joe-identity-strip-csb0.headers.customrequestheaders." + header) == "", "incoming identity must be removed")
    require(not any("x-joedesk-origin" in (key + value).lower() for key, value in labels.items()), "edge must not manipulate app origin")
    require(
        labels.get(main + "rule") == host + " && PathPrefix(`/joe/`)",
        "canonical UI/data/assets must stay in the protected router",
    )
    require(
        labels.get(main + "middlewares") == strip + ",hostdash-auth-csb0@docker",
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
    for router in (bare, main, inbox, health, results):
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
    require(labels.get(inbox + "middlewares") == strip, "inbox must strip identity without SSO")
    spec = run_nix_json(["--file", str(COMPOSE_SPEC)], "compose spec")
    service = spec["services"]["joe-board"]
    require(not service.get("ports") and service.get("network_mode") != "host", "app must publish no host port or host network")
    all_labels = [label for item in spec["services"].values() for label in item.get("labels", [])]
    require("traefik.http.middlewares.hostdash-auth-csb0.forwardauth.authResponseHeaders=X-Auth-Request-User,X-Auth-Request-Email" in all_labels, "SSO identity replacement must remain enabled")
    require(not any("x-joedesk-origin" in label.lower() for label in all_labels), "edge must preserve app stamp")
    static = (REPO / "hosts/csb0/docker/traefik/static.yml").read_text()
    require(re.search(r'  web-secure:\n(?:(?:    .*|\s*)\n)*?      aliasHeadersStrategy: delete', static) is not None,
            "TLS entrypoint must delete all aliasing headers before routing/auth")

    require(labels.get(results + "rule") == host + " && Path(`/joe/inbox/results`) && Method(`POST`)", "Results ingress must be exact POST")
    require(labels.get(results + "middlewares") == strip, "Results ingress must strip identity without SSO")
    require(labels.get(results + "service") == "joe-board-csb0" and int(labels[results + "priority"]) > int(labels[main + "priority"]), "Results service/priority changed")

    # Evaluate the small, explicitly asserted rule vocabulary against requests.
    # Identity headers never select a router; protected requests enter forwardAuth.
    def selected(path: str, method: str) -> str:
        candidates = []
        for name in routers:
            prefix = "traefik.http.routers." + name + "."
            rule = labels[prefix + "rule"]
            def match(m: re.Match[str]) -> str:
                kind, value = m.groups()
                return str({"Host": value == "cs0.barta.cm", "Path": path == value,
                            "PathPrefix": path.startswith(value), "Method": method == value}[kind])
            expression = re.sub(r"(Host|PathPrefix|Path|Method)\(`([^`]*)`\)", match, rule)
            expression = expression.replace("&&", " and ").replace("||", " or ")
            require(re.fullmatch(r"[TrueFalsandor ()]+", expression) is not None, "unsupported rule grammar")
            if eval(expression, {"__builtins__": {}}, {}):
                candidates.append((int(labels[prefix + "priority"]), name))
        return max(candidates)[1]
    for method in ("GET", "HEAD"):
        require(selected("/joe/healthz", method) == "joe-health-csb0", "exact health routing failed")
    for method in ("POST", "PUT", "DELETE", "OPTIONS"):
        require(selected("/joe/healthz", method) == "joe-csb0", "health write bypasses SSO")
    require(selected("/joe/inbox/results", "POST") == "joe-results-inbox-csb0", "Results exact POST route failed")
    for method in ("GET", "HEAD", "PUT", "DELETE", "OPTIONS", "PATCH"):
        require(selected("/joe/inbox/results", method) == "joe-csb0", "Results non-POST bypasses SSO")
    protected = ["inbox/results/", "inbox/resultsx", "", "app.js", "healthz/", "healthz-extra", "data.json", "history.json",
                 "results.json", "state.json", "fleet-config.json", "fleet-config/actions.json"]
    for path in protected:
        for method in ("GET", "HEAD"):
            require(selected("/joe/" + path, method) == "joe-csb0", "protected surface bypasses SSO")

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


def verify_pinned_build(contract: dict[str, Any], release: dict[str, Any] | None = None,
                        lock_revision: str | None = None) -> None:
    service = contract.get("service")
    require(isinstance(service, dict), "rendered joe-board service must be an object")
    release = release or json.loads(RELEASE_SET.read_text())
    active = release["sets"][release["active"]]
    revision = lock_revision or json.loads(FLAKE_LOCK.read_text())["nodes"]["joedesk"]["locked"]["rev"]
    require(active["board"]["rev"] == revision, "active release must match the locked source")
    require(
        service.get("image") == active["board"]["image"] == f"csb0-joe-board:source-{revision}",
        "rendered image name must contain the full locked JoeDesk revision",
    )
    require(
        service.get("pull_policy") == ("never" if release["active"] == "previous" else "build"),
        "JoeDesk must use the active release's build/retained-image policy",
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


def request_without_redirects(opener: Any, url: str, method: str = "GET", extra_headers: dict[str, str] | None = None) -> tuple[int, Any]:
    request = urllib.request.Request(
        url,
        method=method,
        headers={"User-Agent": "nixcfg-OPS-354-joe-routing-smoke", **(extra_headers or {})},
    )
    try:
        with opener.open(request, timeout=10) as response:
            return response.status, response.headers
    except urllib.error.HTTPError as error:
        return error.code, error.headers


def verify_live(data_schema: str = "v1") -> None:
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

    if data_schema == "v2":
        for method in ("GET", "HEAD"):
            status, headers = request_without_redirects(opener, origin + "/joe/healthz", method, SPOOF_HEADERS)
            require(status not in AUTH_FAILURE_STATUSES, "auth_required")
            require(status == 200 and headers.get("X-JoeDesk-Origin") == "app", "app_origin_not_proven")

    # v1 remains testable before cutover without a v2 source or public health.
    for path in ("/joe/", "/joe/data.json", "/joe/history.json", "/joe/joe.css", "/joe/inbox/results"):
        for identity in ({}, SPOOF_HEADERS):
            for method in ("GET", "HEAD"):
                status, headers = request_without_redirects(opener, origin + path, method, identity)
                require(status in AUTH_FAILURE_STATUSES and headers.get("X-JoeDesk-Origin") is None, "anonymous_or_alias_identity_exposed")
                require(status >= 400 or bool(headers.get("Location")), "sso_not_proven")

    # Separate pending JOED-27 router: trailing/extended paths stay behind SSO.
    for path in ("/joe/inbox/results/", "/joe/inbox/resultsx"):
        for spoof in (False, True):
            identity = SPOOF_HEADERS if spoof else {}
            for method in ("GET", "HEAD", "POST"):
                status, headers = request_without_redirects(opener, origin + path, method, identity)
                require(status in AUTH_FAILURE_STATUSES and headers.get("X-JoeDesk-Origin") is None, "results_near_path_exposed")
                require(status >= 400 or bool(headers.get("Location")), "sso_not_proven")


def verify_release_smoke(source: pathlib.Path) -> None:
    # Delegate the complete allowlist, freshness and anonymous/spoof matrix to
    # JoeDesk itself. A v1 404 or a redirect never counts as v2 success.
    expected_rev = json.loads(FLAKE_LOCK.read_text())["nodes"]["joedesk"]["locked"]["rev"]
    actual_rev = subprocess.run(["git", "-C", str(source), "rev-parse", "HEAD"], capture_output=True, text=True, check=False)
    require(actual_rev.returncode == 0 and actual_rev.stdout.strip() == expected_rev, "live smoke source must match the active locked revision")
    dirty = subprocess.run(["git", "-C", str(source), "status", "--porcelain"], capture_output=True, text=True, check=False)
    require(dirty.returncode == 0 and not dirty.stdout.strip(), "live smoke requires a clean exact source checkout")
    release = json.loads((source / "release.json").read_text())
    result = subprocess.run([
        "node", str(source / "scripts/smoke-release.mjs"),
        "https://cs0.barta.cm/joe/", release["version_scheme"], release["version"],
    ], capture_output=True, text=True, check=False)
    require(result.returncode == 0, "release_smoke_failed (run JoeDesk smoke for its value-free reason)")
    evidence = json.loads(result.stdout)
    require(evidence.get("ok") is True, "release smoke did not pass")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--live",
        action="store_true",
        help="opt in to the no-auth HTTP smoke at https://cs0.barta.cm",
    )
    parser.add_argument("--labels-only", action="store_true", help="static labels without the full flake/daemon evaluation")
    parser.add_argument("--joedesk-source", type=pathlib.Path, help="exact active v2 checkout; required only for v2 live smoke")
    arguments = parser.parse_args()
    active = json.loads(RELEASE_SET.read_text())
    schema = active["sets"][active["active"]]["board"]["data_schema"]
    require(not arguments.live or schema == "v1" or arguments.joedesk_source is not None, "v2 live mode requires --joedesk-source")

    verify_rendered_contract(load_joe_labels())
    if not arguments.labels_only:
        verify_pinned_build(load_rendered_joe_contract())
    if arguments.live:
        if schema == "v2":
            verify_release_smoke(arguments.joedesk_source)
        verify_live(schema)
    print(
        "joe_slash_routing=ok "
        f"rendered_config={'skipped' if arguments.labels_only else 'ok'} live={'ok' if arguments.live else 'skipped'}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ContractError, OSError, ValueError, json.JSONDecodeError) as error:
        print(f"T76: {error}", file=sys.stderr)
        raise SystemExit(1)
