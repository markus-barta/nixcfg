#!/usr/bin/env python3
"""Verify retained engine pins and Janus retirement without starting containers.

Exit 0: correct; 1: drift or failed verification; 2: unavailable evidence/tooling.
The staged pin is also Pharos's production renderer/retirement engine. It need
not equal transactiond's separately admitted pin or the newest upstream release.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import HTTPRedirectHandler, Request, build_opener


ROOT = Path(__file__).resolve().parent.parent
IMAGE = "ghcr.io/inspr-at/janus/janus-engine"
REPOSITORY = "inspr-at/janus"
ISSUER = "https://token.actions.githubusercontent.com"
ACCEPT_MANIFEST = ", ".join(
    (
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    )
)

# Evaluate only value-free metadata. Do not evaluate a NixOS configuration,
# resolve env files, read ciphertext, or require a flake/private input fetch.
STATE_EXPR = r'''
let
  s = (import (builtins.toPath (builtins.getEnv "JANUS_PIN_COMPOSE"))).services;
  flow = import (builtins.toPath (builtins.getEnv "JANUS_PIN_FLOW"));
in {
  janus = { profiles = s.janus.profiles or []; restart = s.janus.restart or null; };
  staged = {
    inherit (s.janus-engine-staged) image;
    profiles = s.janus-engine-staged.profiles or [];
    network_mode = s.janus-engine-staged.network_mode or null;
    labels = s.janus-engine-staged.labels or [];
  };
  managed = {
    inherit (s.janus-managed-transactiond) image;
    network_mode = s.janus-managed-transactiond.network_mode or null;
    environment = builtins.filter
      (v: builtins.match "JANUS_RELEASE_ARTIFACT_DIGEST=.*" v != null)
      (s.janus-managed-transactiond.environment or []);
  };
  placeholder = {
    inherit (s.janus-placeholder) image command volumes;
    profiles = s.janus-placeholder.profiles or [];
    restart = s.janus-placeholder.restart or null;
  };
  routing = {
    inherit (flow) active;
    upstream = flow.routingEdgeActivation.upstreams.janus.url;
    expected = "http://${s.janus-placeholder.networks.${flow.network.composeKey}.ipv4_address}:${toString flow.ports.janus}";
  };
}
'''


class CheckError(Exception):
    def __init__(self, message, status=1):
        super().__init__(message)
        self.status = status


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Release and registry URLs are exact authorities. In particular, never
        # forward the private GitHub read token to a redirected host.
        raise CheckError("unexpected redirect reading release/registry evidence", 2)


urlopen = build_opener(NoRedirects()).open


def require(condition, message):
    if not condition:
        raise CheckError(message)


def load_state(compose_file, flow_file):
    result = subprocess.run(
        ["nix", "eval", "--offline", "--impure", "--json", "--expr", STATE_EXPR],
        env={
            **os.environ,
            "JANUS_PIN_COMPOSE": str(compose_file.resolve()),
            "JANUS_PIN_FLOW": str(flow_file.resolve()),
        },
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    if result.returncode:
        raise CheckError("could not evaluate the local Janus pin/retirement metadata", 2)
    return json.loads(result.stdout)


def parse_pin(image, image_repo):
    match = re.fullmatch(
        re.escape(image_repo) + r":(rust-engine-v[0-9]+\.[0-9]+\.[0-9]+)@(sha256:[0-9a-f]{64})",
        image,
    )
    require(match is not None, "engine image must be an immutable rust-engine release in the expected repository")
    return {"image": image_repo, "tag": match[1], "digest": match[2]}


def check_local(state, receipt, policy, image_repo=IMAGE, release_repo=REPOSITORY):
    require(state["janus"] == {"profiles": ["janus-retired"], "restart": "no"},
            "Janus app must remain profile-gated as retired with restart disabled")
    staged = state["staged"]
    require(staged["profiles"] == ["janus-engine-staged"]
            and staged["network_mode"] == "none"
            and "traefik.enable=false" in staged["labels"]
            and "traefik.enable=true" not in staged["labels"],
            "staged engine must remain profile-gated, networkless and outside Traefik")
    placeholder = state["placeholder"]
    require(not placeholder["profiles"] and placeholder["restart"] == "unless-stopped",
            "Janus placeholder must remain active in the normal Compose stack")
    require(re.fullmatch(r"caddy:[^@\s]+@sha256:[0-9a-f]{64}", placeholder["image"]) is not None,
            "Janus placeholder must retain a digest-pinned Caddy image")
    require(placeholder["command"] == ["caddy", "run", "--config", "/srv/janus-placeholder/Caddyfile", "--adapter", "caddyfile"]
            and any(isinstance(v, dict) and v.get("type") == "bind"
                    and v.get("source") == "./janus-placeholder"
                    and v.get("target") == "/srv/janus-placeholder"
                    and v.get("read_only") is True
                    and v.get("bind", {}).get("create_host_path") is False
                    for v in placeholder["volumes"]),
            "Janus placeholder must serve the retained repository files read-only")
    require(state["routing"]["active"] is True
            and state["routing"]["upstream"] == state["routing"]["expected"],
            "retired Janus routing must point to the placeholder")

    pins = [parse_pin(state[name]["image"], image_repo) for name in ("staged", "managed")]
    managed = pins[1]
    require(state["managed"]["network_mode"] == "none",
            "managed transaction engine must remain networkless")
    require(state["managed"]["environment"] == ["JANUS_RELEASE_ARTIFACT_DIGEST=" + managed["digest"]],
            "managed engine environment digest differs from its image pin")
    require(receipt.get("artifact") == {**managed, "development": False},
            "managed engine pin differs from its reviewed release admission receipt")
    require(receipt.get("schema_version") == 1
            and policy.get("schema_version") == 1
            and receipt.get("policy_id") == policy.get("policy_id") == "janus-engine-release-v1"
            and receipt.get("policy_version") == policy.get("policy_version")
            and receipt.get("mode") == receipt.get("previous_mode") == "production"
            and receipt.get("channel") == "stable",
            "managed engine admission policy/channel/mode drift")
    channels = [channel for channel in policy.get("channels", []) if channel.get("name") == "stable"]
    require(len(channels) == 1
            and channels[0].get("image") == image_repo
            and channels[0].get("repository") == release_repo
            and channels[0].get("signer_workflow") == release_repo + "/.github/workflows/rust.yml"
            and channels[0].get("certificate_identity_prefix") == f"https://github.com/{release_repo}/.github/workflows/rust.yml@refs/tags/"
            and channels[0].get("oidc_issuer") == ISSUER
            and policy.get("deny_mode_downgrade") is True
            and "production" in policy.get("required_modes", []),
            "managed engine stable-channel verification policy drift")
    require(all(pin["digest"] not in policy["revoked_digests"] for pin in pins),
            "retained engine digest has been revoked")
    identity = f"https://github.com/{release_repo}/.github/workflows/rust.yml@refs/tags/{managed['tag']}"
    require(receipt.get("signature") == {"verified": True, "identity": identity, "oidc_issuer": ISSUER},
            "managed engine signature admission drift")
    require(receipt.get("provenance") == {
        "verified": True, "repository": release_repo,
        "signer_workflow": release_repo + "/.github/workflows/rust.yml",
        "source_ref": "refs/tags/" + managed["tag"],
        "predicate_type": "https://slsa.dev/provenance/v1",
    } and receipt.get("sbom") == {"verified": True, "predicate_type": "https://spdx.dev/Document/v2.3"},
        "managed engine provenance/SBOM admission drift")
    source = receipt.get("source", {})
    scanner = receipt.get("scanner", {})
    require(source.get("verified") is True
            and re.fullmatch(r"[0-9a-f]{40}", source.get("commit", "")) is not None
            and all(re.fullmatch(r"sha256:[0-9a-f]{64}", source.get(key, "")) is not None
                    for key in ("manifest_sha256", "bundle_sha256"))
            and scanner.get("verified") is True
            and scanner.get("name") == "trivy"
            and scanner.get("policy") == "candidate_container_critical_high"
            and scanner.get("subject") == image_repo + "@" + managed["digest"]
            and scanner.get("critical") == scanner.get("high") == 0
            and re.fullmatch(r"sha256:[0-9a-f]{64}", scanner.get("summary_sha256", "")) is not None,
            "managed engine source/scanner admission drift")
    return pins


def request(url, headers):
    try:
        with urlopen(Request(url, headers=headers), timeout=30) as response:
            return response.read(), response.headers
    except HTTPError as error:
        error.close()
        raise CheckError(f"could not read published release/registry evidence (HTTP {error.code})", 2) from None
    except (URLError, TimeoutError):
        # Do not dump headers, response bodies, tokens, or subprocess environments.
        raise CheckError("could not read published release/registry evidence (network error)", 2) from None


def verify_signature(pin, release_repo):
    identity = f"https://github.com/{release_repo}/.github/workflows/rust.yml@refs/tags/{pin['tag']}"
    result = subprocess.run(
        ["cosign", "verify", "--certificate-identity", identity,
         "--certificate-oidc-issuer", ISSUER, pin["image"] + "@" + pin["digest"]],
        capture_output=True, text=True, timeout=120, check=False,
    )
    require(result.returncode == 0, "engine image signature verification failed for " + pin["tag"])
    verified = json.loads(result.stdout)
    require(isinstance(verified, list) and any(
        item.get("critical", {}).get("image", {}).get("docker-manifest-digest") == pin["digest"]
        for item in verified
    ), "engine signature output did not bind the pinned digest")


def check_published(pin, release_repo, token):
    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
    if token:
        headers["Authorization"] = "Bearer " + token
    body, _ = request(f"https://api.github.com/repos/{release_repo}/releases/tags/{quote(pin['tag'], safe='')}", headers)
    release = json.loads(body)
    require(release.get("tag_name") == pin["tag"]
            and release.get("draft") is False and release.get("prerelease") is False
            and bool(release.get("published_at")),
            "pinned engine tag is not a published stable release")
    # Both retained release workflows upload this fixed filename. A digest in
    # an arbitrary asset's name is not release verification (OPS-452).
    require(any(asset.get("name") == "rust-engine-sbom.spdx.json" for asset in release.get("assets", [])),
            "pinned engine release has no published SPDX SBOM asset")
    image_path = pin["image"].removeprefix("ghcr.io/")
    body, _ = request("https://ghcr.io/token?service=ghcr.io&scope=repository:" + image_path + ":pull", {})
    pull_token = json.loads(body)["token"]
    require(isinstance(pull_token, str) and bool(pull_token), "registry pull token unavailable")
    body, headers = request(f"https://ghcr.io/v2/{image_path}/manifests/{pin['tag']}",
                            {"Authorization": "Bearer " + pull_token, "Accept": ACCEPT_MANIFEST})
    require(headers.get("Docker-Content-Digest") == pin["digest"],
            "published engine tag digest differs from its retained pin: " + pin["tag"])
    require("sha256:" + hashlib.sha256(body).hexdigest() == pin["digest"],
            "registry manifest bytes differ from their declared digest")
    verify_signature(pin, release_repo)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quiet", action="store_true", help="print only on drift or verification errors")
    args = parser.parse_args(argv)
    compose = Path(os.environ.get("JANUS_ENGINE_STAGED_COMPOSE_FILE", ROOT / "hosts/csb1/docker/compose-spec.nix"))
    flow = ROOT / "hosts/csb1/shared-flow.nix"
    contract = ROOT / "hosts/csb1/docker/janus/managed-service-production"
    image_repo = os.environ.get("JANUS_ENGINE_IMAGE_REPO", IMAGE)
    release_repo = os.environ.get("JANUS_ENGINE_RELEASE_REPO", REPOSITORY)
    try:
        require(re.fullmatch(r"ghcr\.io/[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+", image_repo) is not None,
                "only ghcr.io image repositories are supported")
        require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", release_repo) is not None,
                "invalid release repository")
        pins = check_local(load_state(compose, flow),
                           json.loads((contract / "release-admission.json").read_text()),
                           json.loads((contract / "release-channels-v1.json").read_text()),
                           image_repo, release_repo)
        seen = set()
        for pin in pins:
            key = (pin["tag"], pin["digest"])
            if key not in seen:
                check_published(pin, release_repo, os.environ.get("JANUS_ENGINE_GITHUB_TOKEN", ""))
                seen.add(key)
        if not args.quiet:
            print("ok: Janus app declared retired; placeholder routing retained")
            for name, pin in zip(("Pharos/staged", "managed transactiond"), pins):
                print(f"ok: {name} published pin, manifest, signature and SBOM presence verified: {pin['image']}:{pin['tag']}@{pin['digest']}")
        return 0
    except CheckError as error:
        print("error: " + str(error), file=sys.stderr)
        return error.status
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.TimeoutExpired):
        print("error: required tooling or valid pin/retirement/release evidence unavailable", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
