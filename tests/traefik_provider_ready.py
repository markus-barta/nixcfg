"""Readiness of the isolated T75 providers, before its one-shot HTTP assertions."""

import json
import sys


def providers_ready(routers):
    if not isinstance(routers, list) or not all(isinstance(router, dict) for router in routers):
        return False
    by_name = {router.get("name"): router for router in routers if isinstance(router.get("name"), str)}
    backend = by_name.get("nix448backend@docker", {})
    redirect = by_name.get("https-redirect@file", {})
    return (
        backend.get("status") == "enabled"
        and backend.get("rule") == "Host(`backend.example.test`)"
        and backend.get("entryPoints") == ["web"]
        and backend.get("middlewares") == ["cloudflarewarp@file"]
        and backend.get("service") in ("nix448backend", "nix448backend@docker")
        and redirect.get("status") == "enabled"
        and redirect.get("entryPoints") == ["web"]
        and redirect.get("middlewares") == ["https-redirect@file"]
    )


if __name__ == "__main__":
    try:
        ready = providers_ready(json.load(sys.stdin))
    except (ValueError, TypeError):
        ready = False
    raise SystemExit(0 if ready else 1)
