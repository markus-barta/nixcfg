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
import shlex
import subprocess
import sys
import tempfile
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
SSH_REMOTE = "ssh://git@github.com/inspr-at/paimos.git"
PUBLIC_REMOTE = "https://github.com/inspr-at/paimos.git"
GITHUB_HOST_KEY = "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
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


def command(args, cwd=None, env=None, timeout=20):
    try:
        result = subprocess.run(args, cwd=cwd, env=env, capture_output=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        raise GateError("git request could not complete") from None
    if result.returncode:
        raise GateError("git request failed")
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
        raise GateError("invalid registry response") from None
    if not isinstance(value, dict):
        raise GateError("expected a registry object")
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


def advertised_refs(payload, allowed):
    try:
        lines = payload.decode("ascii").splitlines()
    except UnicodeError:
        raise GateError("git returned invalid release refs") from None
    refs = {}
    for line in lines:
        fields = line.split("\t")
        if (
            len(fields) != 2 or not SHA.fullmatch(fields[0])
            or fields[1] not in allowed or fields[1] in refs
        ):
            raise GateError("git returned invalid release refs")
        refs[fields[1]] = fields[0]
    return refs


def verify_tag(pin):
    if not re.fullmatch(r"[0-9]{12}\.0\.0", pin["version"]):
        raise GateError("invalid release tag version")
    tag = f"refs/tags/v{pin['version']}"
    main = "refs/heads/main"
    # Never persist a key beyond this verification or pass its value to Git.
    key = os.environ.pop("PAIMOS_DEPLOY_KEY", "")
    child_env = dict(os.environ)
    for name in (
        "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_REPLACE_REF_BASE", "GIT_NAMESPACE", "GIT_SHALLOW_FILE",
    ):
        child_env.pop(name, None)
    child_env.update(
        GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",
        GIT_CONFIG_COUNT="0", GIT_TERMINAL_PROMPT="0", GIT_ASKPASS="false",
    )
    with tempfile.TemporaryDirectory(
        prefix="aeon-pin-git-", dir=os.environ.get("RUNNER_TEMP")
    ) as scratch:
        root = Path(scratch)
        root.chmod(0o700)
        remote = PUBLIC_REMOTE
        if key:
            key_file = root / "deploy-key"
            key_file.touch(mode=0o600)
            key_file.write_text(key + "\n")
            known_hosts = root / "known_hosts"
            known_hosts.write_text(GITHUB_HOST_KEY + "\n")
            child_env["GIT_SSH_COMMAND"] = shlex.join([
                "ssh", "-F", "/dev/null", "-i", str(key_file),
                "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=15", "-o", "StrictHostKeyChecking=yes",
                "-o", f"UserKnownHostsFile={known_hosts}",
                "-o", "GlobalKnownHostsFile=/dev/null",
            ])
            remote = SSH_REMOTE
        else:
            # Forks/Dependabot may verify public releases without credentials.
            # No credential helper or interactive prompt may supply hidden auth.
            child_env["GIT_SSH_COMMAND"] = "false"
        key = ""
        git = ["git", "--no-replace-objects", "-c", "credential.helper=",
               "-c", "core.askPass="]

        def run(*args, timeout=20):
            return command(git + list(args), cwd=root, env=child_env, timeout=timeout)

        try:
            # Never read the checkout's local Git config: checkout may persist
            # a nixcfg-only HTTP Authorization header there.
            repository = root / "repository"
            run("init", "--bare", "--quiet", str(repository))
            git.extend(["-C", str(repository)])
            tags = advertised_refs(run("ls-remote", "--tags", remote, tag, tag + "^{}"),
                                   {tag, tag + "^{}"})
            heads = advertised_refs(run("ls-remote", "--heads", remote, main), {main})
            if tag not in tags or main not in heads:
                raise GateError("release tag or main is missing")
            # Blob-less, no checkout, no shallow boundary: the complete commit
            # graph is needed to reject off-main tags without false negatives.
            run("fetch", "--quiet", "--filter=blob:none", "--no-tags",
                "--no-write-fetch-head", remote,
                f"+{main}:refs/remotes/release/main", f"+{tag}:{tag}", timeout=120)
            fetched_tag = run("rev-parse", "--verify", tag).decode().strip()
            main_sha = run("rev-parse", "--verify", "refs/remotes/release/main^{commit}").decode().strip()
            tagged_sha = run("rev-parse", "--verify", tag + "^{commit}").decode().strip()
            if (
                fetched_tag != tags[tag] or main_sha != heads[main]
                or not SHA.fullmatch(tagged_sha)
                or tagged_sha != tags.get(tag + "^{}", tags[tag])
            ):
                raise GateError("release refs changed during verification")
            if run("merge-base", tagged_sha, main_sha).decode().strip() != tagged_sha:
                raise GateError("release tag commit is not on paimos main")
            return tagged_sha
        except GateError as error:
            # Keep all diagnostics value-free, including SSH errors.
            access = "check PAIMOS_DEPLOY_KEY read-only access" if remote == SSH_REMOTE else (
                "PAIMOS_DEPLOY_KEY is required if paimos is private; anonymous Git access failed"
            )
            raise GateError(f"{error}; {access}") from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("classify", "verify"))
    parser.add_argument("--base", default=os.environ.get("BASE_SHA", ""))
    parser.add_argument("--head", default=os.environ.get("HEAD_SHA", ""))
    parser.add_argument("--repo", default=".")
    args = parser.parse_args()
    pin = classify(args.repo, args.base, args.head)
    if args.mode == "classify":
        # The workflow copies this exact line into $GITHUB_OUTPUT; the script
        # itself never opens a path taken from the environment.
        print(f"pin_only={'true' if pin else 'false'}")
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
