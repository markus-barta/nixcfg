#!/usr/bin/env python3
"""INSPR-572/576: evaluate media, admin uploads and ingress offline, without builds."""

from copy import deepcopy
import json
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
ADMIN_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJn7weE26GvDJ5RmNV2WgWpmNddlvQrywDxurwialSdU vid-admin-upload"
RRSYNC = "/nix/store/fixture-rrsync/bin/rrsync"
ADMIN_COMMAND = f'command="{RRSYNC} -no-del /home/mba/docker/inspr-at/admin",restrict '
ADMIN_MOUNT = "/home/mba/docker/inspr-at/admin:/srv/admin:ro"
ADMIN_RULE = "d /home/mba/docker/inspr-at/admin 0755 mba users -"


def evaluate(expression):
    result = subprocess.run(
        ["nix-instantiate", "--eval", "--strict", "--json", "--expr", expression],
        cwd=ROOT, capture_output=True, text=True, timeout=30, check=False,
    )
    assert result.returncode == 0, "offline Nix evaluation failed"
    return json.loads(result.stdout)


def check_paimos(services):
    parsed = {}
    for name, service in services.items():
        parsed[name] = dict(label.split("=", 1) for label in service["labels"])
        if name in ("inspr-www", "paimos-www"):
            assert len(parsed[name]) == len(service["labels"]), "duplicate labels"

    labels = parsed["inspr-www"]
    assert labels["traefik.enable"] == "true"
    prefix = "traefik.http.routers.paimos."
    assert labels[prefix + "rule"] == "Host(`paimos.com`) || Host(`www.paimos.com`)"
    assert labels[prefix + "tls"] == "true"
    assert labels[prefix + "tls.certresolver"] == "default"
    assert labels[prefix + "service"] == "inspr-sites"
    assert labels[prefix + "middlewares"] == "paimos-www-redirect@docker,cloudflarewarp@file"
    middleware = "traefik.http.middlewares.paimos-www-redirect."
    assert labels[middleware + "redirectregex.regex"] == r"^https?://www\.paimos\.com/(.*)"
    assert labels[middleware + "redirectregex.replacement"] == "https://paimos.com/$${1}"
    assert labels[middleware + "redirectregex.permanent"] == "true"

    for host in ("paimos.com", "www.paimos.com"):
        owners = {
            (name, key)
            for name, service_labels in parsed.items()
            for key, value in service_labels.items()
            if key.startswith("traefik.http.routers.") and key.endswith(".rule")
            and f"`{host}`" in value
        }
        assert owners == {
            ("inspr-www", prefix + "rule"),
            ("inspr-www", "traefik.http.routers.inspr-sites-http.rule"),
        }, f"unexpected routing ownership for {host}"

    for name, service_labels in parsed.items():
        if name != "inspr-www":
            assert not any(key.startswith((prefix, middleware)) for key in service_labels)
        assert "traefik.http.services.paimos.loadbalancer.server.port" not in service_labels
    idle = parsed["paimos-www"]
    assert idle["traefik.enable"] == "false"
    assert not any(key.startswith("traefik.http.") for key in idle)


def self_check_paimos(services):
    # Every mutation must be rejected: prove these checks catch routing regressions.
    mutations = [
        ("paimos-www", "traefik.enable", "true"),
        ("paimos-www", "traefik.http.services.stray.loadbalancer.server.port", "80"),
        ("paimos-www", "traefik.http.routers.stray.rule", "Host(`paimos.com`)"),
        ("paimos-www", "traefik.http.routers.stray.rule", "Host(`www.paimos.com`)"),
        ("inspr-www", "traefik.http.routers.paimos.service", "paimos"),
        ("inspr-www", "traefik.http.routers.paimos.middlewares", "cloudflarewarp@file"),
        ("inspr-www", "traefik.http.routers.paimos.middlewares", "paimos-www-redirect@docker"),
        ("inspr-www", "traefik.http.middlewares.paimos-www-redirect.redirectregex.permanent", "false"),
        ("inspr-www", "traefik.http.routers.inspr-sites-http.rule", "Host(`media.inspr.at`)"),
    ]
    for name, key, value in mutations:
        broken = deepcopy(services)
        broken[name]["labels"] = [
            label for label in broken[name]["labels"] if not label.startswith(key + "=")
        ] + [key + "=" + value]
        try:
            check_paimos(broken)
        except AssertionError:
            continue
        raise AssertionError(f"self-check accepted broken label: {key}")


def check_admin(volumes, rules, keys):
    # Exact options preserve the forced command, directory boundary and restrict.
    matching = [key for key in keys if ADMIN_KEY.split()[1] in key.split()]
    assert matching == [ADMIN_COMMAND + ADMIN_KEY], "unsafe or duplicate VID key"
    mounts = [volume for volume in volumes if volume.split(":")[1] == "/srv/admin"]
    assert mounts == [ADMIN_MOUNT], "admin must have exactly one read-only mount"
    assert rules.count(ADMIN_RULE) == 1, "admin tmpfiles ownership/mode missing"


def self_check_admin(volumes, rules, keys):
    upload = ADMIN_COMMAND + ADMIN_KEY
    mutations = [
        (volumes, rules, [key for key in keys if key != upload]),
        (volumes, rules, keys + [upload]),
        (volumes, rules, keys + [ADMIN_KEY]),
        ([volume for volume in volumes if volume != ADMIN_MOUNT], rules, keys),
        (volumes + [ADMIN_MOUNT.replace(":ro", ":rw")], rules, keys),
        (volumes, [rule for rule in rules if rule != ADMIN_RULE], keys),
    ]
    for replacement in (
        ADMIN_KEY,
        upload.replace(" -no-del", ""),
        upload.replace(",restrict", ""),
        upload.replace(",restrict", ",restrict,port-forwarding"),
        upload.replace("/inspr-at/admin", "/inspr-at"),
    ):
        mutations.append((volumes, rules, [
            replacement if key == upload else key for key in keys
        ]))
    for broken in mutations:
        try:
            check_admin(*broken)
        except AssertionError:
            continue
        raise AssertionError("self-check accepted unsafe admin upload configuration")


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
    # Deliberately match the sibling inspr-* routers: no explicit entrypoints.
    assert prefix + "entrypoints" not in labels
    assert labels[prefix + "middlewares"] == "inspr-media-inflight@docker"
    inflight = "traefik.http.middlewares.inspr-media-inflight.inflightreq."
    assert labels[inflight + "amount"] == "16"
    assert labels[inflight + "sourcecriterion.ipstrategy.depth"] == "0"
    assert inflight + "sourcecriterion.requesthost" not in labels
    assert inflight + "sourcecriterion.requestheadername" not in labels
    for key, value in labels.items():
        if key.endswith(".middlewares") and key != prefix + "middlewares":
            assert "inspr-media-inflight@docker" not in value, (
                "the media in-flight limit must not affect sibling routers"
            )
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

    # Select labels only across the stack; never resolve runtime environment values.
    services = evaluate('''builtins.mapAttrs (name: service: {
      labels = service.labels or [];
    }) (import ./hosts/csb1/docker/compose-spec.nix).services''')
    check_paimos(services)
    self_check_paimos(services)

    # Lazily select tmpfiles only: inert dependencies avoid derivations and secrets.
    rules = evaluate('''(import ./hosts/csb1/configuration.nix {
      pkgs = {}; lib = {}; inputs = {}; config = {};
    }).systemd.tmpfiles.rules''')
    assert rules.count("d /home/mba/docker/inspr-at/media 0755 mba users -") == 1
    # Select extraKeys lazily, with only rrsync substituted; no credentials needed.
    keys = evaluate('''(import ./hosts/csb1/configuration.nix {
      pkgs.rrsync = "/nix/store/fixture-rrsync";
      lib = {}; inputs = {}; config = {};
    }).inspr.ssh.authorized.users.mba.extraKeys''')
    assert len(keys) == 3, "update the csb1 extraKeys inventory when changing keys"
    check_admin(service["volumes"], rules, keys)
    self_check_admin(service["volumes"], rules, keys)
    workflow = (ROOT / ".github/workflows/check.yml").read_text()
    assert workflow.count("run: python3 tests/T111-inspr-media.py") == 1, (
        "CI wiring missing or duplicated"
    )
    print("T111: media ingress, admin rrsync restrictions/read-only mount/tmpfiles, paimos.com routing ownership, redirects, idle legacy container, mutation self-checks and CI wiring OK")


if __name__ == "__main__":
    main()
