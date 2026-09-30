#!/usr/bin/env python3
"""NIX-591: classify exact Aeon pin replacements and verify release metadata.

Only the canonical csb1 Aeon image line may use the Pharos fast lane. Read git
metadata before content, so unrelated files (including secrets) are never read.
Registry credentials stay in memory; neither HTTP bodies nor errors are logged.
"""

import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request


PIN_PATH = "hosts/csb1/docker/compose-spec.nix"
PIN_LINE = re.compile(
    rb'      image = "ghcr\.io/inspr-at/aeon:'
    rb'(?P<version>[0-9]{12}\.0\.0)@(?P<digest>sha256:[0-9a-f]{64})";'
    rb'(?: #[^\r\n]*)?\n'
)
SHA = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})")
REPO = "repos/inspr-at/paimos"
ACCEPT = ", ".join(
    (
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    )
)


class GateError(Exception):
    """A safe, value-free failure suitable for CI logs."""


def command(args, cwd=None):
    try:
        result = subprocess.run(args, cwd=cwd, capture_output=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        raise GateError("git or GitHub request could not complete") from None
    if result.returncode:
        raise GateError("git or GitHub request failed")
    return result.stdout


def classify(repo, base, head):
    # Manual dispatch and an initial push have no usable base: full suite.
    if not base or base == "0" * 40:
        return None
    if not SHA.fullmatch(base) or not SHA.fullmatch(head):
        raise GateError("base and head must be full commit SHAs")
    git = ["git", "--no-replace-objects", "-C", str(repo)]
    ancestor = command(git + ["merge-base", base, head]).decode().strip()
    raw = command(
        git + [
            "diff", "--raw", "--no-ext-diff", "--no-textconv", "--no-abbrev",
            "--no-renames", "-z", ancestor, head, "--",
        ]
    ).split(b"\0")
    if len(raw) != 3 or raw[1] != PIN_PATH.encode() or raw[2]:
        return None
    metadata = raw[0].split()
    if len(metadata) != 5 or metadata[:2] != [b":100644", b"100644"] or metadata[4] != b"M":
        return None
    old = command(git + ["show", f"{ancestor}:{PIN_PATH}"]).splitlines(keepends=True)
    new = command(git + ["show", f"{head}:{PIN_PATH}"]).splitlines(keepends=True)
    if len(old) != len(new):
        return None
    changed = [index for index, (left, right) in enumerate(zip(old, new)) if left != right]
    if len(changed) != 1:
        return None
    index = changed[0]
    # Anchor the image to the Aeon service, even if another service uses Aeon.
    if index == 0 or old[index - 1] != b"    aeon = {\n":
        return None
    before, after = PIN_LINE.fullmatch(old[index]), PIN_LINE.fullmatch(new[index])
    if not before or not after or before.groups() == after.groups():
        return None
    return {key: value.decode("ascii") for key, value in after.groupdict().items()}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        # Never forward the registry bearer credential to another endpoint.
        raise GateError("registry redirects are not accepted")


def registry_get(url, headers=None):
    try:
        request = urllib.request.Request(url, headers=headers or {})
        opener = urllib.request.build_opener(NoRedirect)
        with opener.open(request, timeout=15) as response:
            if response.status != 200:
                raise GateError("registry request did not succeed")
            payload = response.read(4 * 1024 * 1024 + 1)
            if len(payload) > 4 * 1024 * 1024:
                raise GateError("registry response exceeds the size limit")
            return payload, response.headers
    except (OSError, urllib.error.URLError, http.client.HTTPException, ValueError):
        raise GateError("registry request failed") from None


def json_object(payload):
    try:
        value = json.loads(payload)
    except (ValueError, UnicodeError):
        raise GateError("invalid registry or GitHub response") from None
    if not isinstance(value, dict):
        raise GateError("expected a registry or GitHub object")
    return value


def verify_registry(pin):
    query = urllib.parse.urlencode(
        {"service": "ghcr.io", "scope": "repository:inspr-at/aeon:pull"}
    )
    payload, _ = registry_get(f"https://ghcr.io/token?{query}")
    token = json_object(payload).get("token")
    if (
        not isinstance(token, str) or not token
        or any(ord(char) < 33 or ord(char) > 126 for char in token)
    ):
        raise GateError("registry did not provide a usable pull credential")
    headers = {"Accept": ACCEPT, "Authorization": f"Bearer {token}"}
    # Check the tagged manifest AND the immutable digest reference. Hash the
    # actual bytes as well as checking the registry's declared digest.
    for reference in (pin["version"], pin["digest"]):
        payload, response_headers = registry_get(
            f"https://ghcr.io/v2/inspr-at/aeon/manifests/{reference}", headers
        )
        actual = "sha256:" + hashlib.sha256(payload).hexdigest()
        if (
            actual != pin["digest"]
            or response_headers.get("Docker-Content-Digest") != pin["digest"]
        ):
            raise GateError("registry manifest does not equal the pinned digest")
        if json_object(payload).get("schemaVersion") != 2:
            raise GateError("registry response is not a v2 image manifest")


def github_get(endpoint):
    return json_object(command(["gh", "api", "--method", "GET", endpoint]))


def commit_object(value):
    if not isinstance(value, dict) or not SHA.fullmatch(str(value.get("sha", ""))):
        raise GateError("GitHub returned an invalid git object")
    return value


def verify_tag(pin):
    tag = f"v{pin['version']}"
    value = commit_object(github_get(f"{REPO}/git/ref/tags/{tag}").get("object"))
    # Current releases also use lightweight tags; accept either representation.
    for _ in range(5):
        if value.get("type") != "tag":
            break
        value = commit_object(github_get(f"{REPO}/git/tags/{value['sha']}").get("object"))
    if value.get("type") != "commit":
        raise GateError("release tag does not resolve to a commit")
    tagged_sha = value["sha"]
    main = commit_object(github_get(f"{REPO}/git/ref/heads/main").get("object"))
    if main.get("type") != "commit":
        raise GateError("main does not resolve to a commit")
    comparison = github_get(f"{REPO}/compare/{tagged_sha}...{main['sha']}")
    if (
        comparison.get("status") not in ("ahead", "identical")
        or commit_object(comparison.get("merge_base_commit"))["sha"] != tagged_sha
        or commit_object(comparison.get("base_commit"))["sha"] != tagged_sha
    ):
        raise GateError("release tag commit is not on paimos main")
    return tagged_sha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("classify", "verify"))
    parser.add_argument("--base", default=os.environ.get("BASE_SHA", ""))
    parser.add_argument("--head", default=os.environ.get("HEAD_SHA", ""))
    parser.add_argument("--repo", default=".")
    args = parser.parse_args()
    pin = classify(args.repo, args.base, args.head)
    if args.mode == "classify":
        output = os.environ.get("GITHUB_OUTPUT")
        if output:
            with Path(output).open("a") as stream:
                stream.write(f"pin_only={'true' if pin else 'false'}\n")
        if pin:
            print("pharos_fast_lane=pin_only tests_ran=0")
        else:
            print("pharos_fast_lane=full_suite")
        return
    if not pin:
        print("aeon_pin_gate=not_applicable reason=not_an_exact_pin_replacement")
        return
    verify_registry(pin)
    tagged_sha = verify_tag(pin)
    # TODO(AEON-407): require gh attestation verify for the pinned digest with
    # inspr-at/paimos/.github/workflows/release.yml@refs/tags/v<version> identity.
    # Phase 0 explicitly defers this until the producer publishes attestations.
    print(f"aeon_pin_gate=verified digest={pin['digest']} tag_commit={tagged_sha}")
    print("attestation_verification=deferred dependency=AEON-407")


if __name__ == "__main__":
    try:
        main()
    except GateError as error:
        print(f"::error::{error}", file=sys.stderr)
        sys.exit(1)
