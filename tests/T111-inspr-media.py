#!/usr/bin/env python3
"""INSPR-572: evaluate media ingress and its host directory offline, without builds."""

import json
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def evaluate(expression):
    result = subprocess.run(
        ["nix-instantiate", "--eval", "--strict", "--json", "--expr", expression],
        cwd=ROOT, capture_output=True, text=True, timeout=30, check=False,
    )
    assert result.returncode == 0, "offline Nix evaluation failed"
    return json.loads(result.stdout)


def main():
    service = evaluate('(import ./hosts/csb1/docker/compose-spec.nix).services.inspr-www')
    labels = dict(label.split("=", 1) for label in service["labels"])
    assert len(labels) == len(service["labels"]), "duplicate Traefik labels"
    prefix = "traefik.http.routers.inspr-media."
    assert labels[prefix + "rule"] == "Host(`media.inspr.at`)"
    assert labels[prefix + "tls"] == "true"
    assert labels[prefix + "tls.certresolver"] == "default"
    assert labels[prefix + "service"] == "inspr-sites"
    assert "cloudflarewarp" not in labels.get(prefix + "middlewares", ""), (
        "DNS-only media ingress must not trust Cloudflare forwarded headers"
    )
    assert labels.get(prefix + "entrypoints") == labels.get(
        "traefik.http.routers.inspr-www.entrypoints"
    ), "media must follow the existing HTTPS entrypoint policy"
    assert labels["traefik.http.services.inspr-sites.loadbalancer.server.port"] == "80"
    assert service["volumes"].count("/home/mba/docker/inspr-at/media:/srv/media:ro") == 1

    redirect = "traefik.http.routers.inspr-sites-http."
    assert "Host(`media.inspr.at`)" in labels[redirect + "rule"]
    assert labels[redirect + "entrypoints"] == "web"
    assert labels[redirect + "middlewares"] == "inspr-sites-https@docker"
    assert labels[redirect + "service"] == "inspr-sites"
    middleware = "traefik.http.middlewares.inspr-sites-https.redirectscheme."
    assert labels[middleware + "scheme"] == "https"
    assert labels[middleware + "permanent"] == "true"

    # Lazily select tmpfiles only: inert dependencies avoid derivations and secrets.
    rules = evaluate('''(import ./hosts/csb1/configuration.nix {
      pkgs = {}; lib = {}; inputs = {}; config = {};
    }).systemd.tmpfiles.rules''')
    assert rules.count("d /home/mba/docker/inspr-at/media 0755 mba users -") == 1
    print("T111 inspr-media: DNS-only TLS, HTTP redirect, read-only mount and tmpfiles OK")


if __name__ == "__main__":
    main()
