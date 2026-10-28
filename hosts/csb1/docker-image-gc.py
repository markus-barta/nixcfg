"""Docker image and build-cache GC for csb1 (OPS-327), ported from agm1's AGM-48.

`docker image prune --all` and `docker system prune -a` are off limits here: they
drop images that rollbacks and the Janus engine pipeline depend on, and the
latter also takes the unmounted Janus volumes (csb1 never-prune rule). So an
image goes only when it is none of:
  - used by any container, running or stopped
  - referenced by the Nix-declared compose spec (csb1 and Janus-managed stack;
    a declared service may have no container yet, e.g. janus-engine-staged)
  - tagged *:rollback
  - in a protected repository (Janus engine / envelope: Pharos beacon tokens)
  - among the newest KEEP_NEWEST images of any repository it is tagged or
    pulled by digest in (previous pins stay for a rollback)
  - younger than KEEP_DAYS (a deploy in flight: pulled, not started yet)
Build cache older than KEEP_DAYS goes. Volumes are never touched.

Everything comes from the Engine API list endpoints over the docker socket
(no inspect). Images are untagged without force, so Docker itself refuses one
a container started using after the scan; that case is skipped, not failed.

DOCKER_IMAGE_GC_DRY_RUN=1 lists what would go and changes nothing.
"""

from __future__ import annotations

import http.client
import json
import os
import socket
import sys
import time
import urllib.parse

SOCKET_PATH = "/var/run/docker.sock"
DECLARED_REFS: list[str] = json.loads(r"""@DECLARED_REFS@""")
PROTECTED_REPOS = frozenset(
    {
        "ghcr.io/inspr-at/janus/janus-engine",
        "ghcr.io/inspr-at/janus/janus-envelope",
    }
)


class Fatal(Exception):
    """The run cannot judge safely; nothing more is removed."""


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path: str, timeout: float) -> None:
        super().__init__("localhost", timeout=timeout)
        self.unix_path = path

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self.unix_path)
        self.sock = sock


def docker_api(method: str, path: str) -> tuple[int, bytes]:
    conn = UnixHTTPConnection(SOCKET_PATH, timeout=300)
    try:
        conn.request(method, path)
        res = conn.getresponse()
        return res.status, res.read()
    finally:
        conn.close()


def get_json(api, path: str):
    status, body = api("GET", path)
    if status != 200:
        raise Fatal(f"GET {path} -> {status}: {body[:200]!r}")
    return json.loads(body)


def env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, str(default))
    if not raw.isdigit() or int(raw) < 1:
        raise Fatal(f"{name}={raw!r} is not a positive integer")
    return int(raw)


def tags_of(image: dict) -> list[str]:
    return [t for t in image.get("RepoTags") or [] if t and not t.startswith("<none>")]


def digests_of(image: dict) -> list[str]:
    return [d for d in image.get("RepoDigests") or [] if d and not d.startswith("<none>")]


def repo_of_tag(tag: str) -> str:
    name, sep, last = tag.rpartition(":")
    # "registry:5000/app" has no tag: the colon belongs to the host part.
    return name if sep and "/" not in last else tag


def repositories(image: dict) -> set[str]:
    return {repo_of_tag(t) for t in tags_of(image)} | {
        d.split("@", 1)[0] for d in digests_of(image)
    }


def declared_ids(images: list[dict], refs: list[str]) -> set[str]:
    """Image IDs a declared reference (name[:tag][@digest] or sha256:id) can name."""
    ids = set()
    for ref in refs:
        name, _, digest = ref.partition("@")
        if not digest and name.startswith("sha256:"):
            ids.update(i["Id"] for i in images if i["Id"] == name)
            continue
        if not digest and repo_of_tag(name) == name:
            name += ":latest"
        for image in images:
            if digest:
                if any(d.endswith("@" + digest) for d in digests_of(image)):
                    ids.add(image["Id"])
            elif name in tags_of(image):
                ids.add(image["Id"])
    return ids


def validate(containers, images) -> None:
    if not isinstance(containers, list) or not isinstance(images, list):
        raise Fatal("container or image listing is not a list")
    if not containers:
        raise Fatal("the daemon lists no containers at all; refusing to judge")
    for c in containers:
        if not isinstance(c, dict) or not str(c.get("ImageID", "")).startswith("sha256:"):
            raise Fatal(f"container without a usable ImageID: {str(c)[:120]}")
    for i in images:
        if (
            not isinstance(i, dict)
            or not str(i.get("Id", "")).startswith("sha256:")
            or not isinstance(i.get("Created"), int)
        ):
            raise Fatal(f"image without a usable Id/Created: {str(i)[:120]}")


def plan(containers, images, refs, now: float, keep_days: int, keep_newest: int):
    """Return ({image id: first protecting reason}, [images to remove, newest first])."""
    validate(containers, images)
    reasons: dict[str, str] = {}

    def protect(image_id: str, why: str) -> None:
        reasons.setdefault(image_id, why)

    for c in containers:
        protect(c["ImageID"], "used by a container")
    for image_id in declared_ids(images, refs):
        protect(image_id, "declared in the compose spec")

    newest_first = sorted(images, key=lambda i: (i["Created"], i["Id"]), reverse=True)
    per_repo: dict[str, int] = {}
    cutoff = now - keep_days * 86400
    for image in newest_first:
        image_id = image["Id"]
        if any(t.endswith(":rollback") for t in tags_of(image)):
            protect(image_id, "tagged :rollback")
        repos = repositories(image)
        if repos & PROTECTED_REPOS:
            protect(image_id, "protected repository")
        for repo in sorted(repos):
            per_repo[repo] = per_repo.get(repo, 0) + 1
            if per_repo[repo] <= keep_newest:
                protect(image_id, f"newest {keep_newest} of its repository")
        if image["Created"] >= cutoff:
            protect(image_id, f"younger than {keep_days} days")
    remove = [i for i in newest_first if i["Id"] not in reasons]
    return reasons, remove


def describe(image: dict) -> str:
    refs = tags_of(image) or digests_of(image) or ["<untagged>"]
    created = time.strftime("%Y-%m-%d", time.gmtime(image["Created"]))
    return f"{image['Id'][7:19]} {' '.join(refs)} created {created} {image.get('Size', 0) / 1e9:.2f} GB"


def remove_image(api, image: dict) -> str:
    """Untag one reference at a time, then the ID. Returns removed / skipped / kept / failed."""
    refs = tags_of(image) + digests_of(image) + [image["Id"]]
    for ref in refs:
        status, body = api("DELETE", "/images/" + urllib.parse.quote(ref, safe="/:@") + "?noprune=0")
        if status in (200, 404):
            continue
        text = body.decode("utf-8", "replace")
        # Untagging says "container X is using its referenced image"; deleting
        # by ID says "image is being used by ... container".
        if status == 409 and ("being used" in text or "is using" in text):
            return "skipped"
        if status == 409 and "dependent child" in text:
            return "kept"
        print(f"docker-image-gc: DELETE {ref} -> {status}: {text[:200]}", file=sys.stderr)
        return "failed"
    return "removed"


def main(api=docker_api, now: float | None = None) -> int:
    dry_run = os.environ.get("DOCKER_IMAGE_GC_DRY_RUN", "0") == "1"
    try:
        keep_days = env_int("DOCKER_IMAGE_GC_KEEP_DAYS", 2)
        keep_newest = env_int("DOCKER_IMAGE_GC_KEEP_NEWEST", 3)
        containers = get_json(api, "/containers/json?all=1")
        images = get_json(api, "/images/json")
        reasons, remove = plan(
            containers, images, DECLARED_REFS, time.time() if now is None else now, keep_days, keep_newest
        )
    except (Fatal, OSError, ValueError) as exc:
        print(f"docker-image-gc: {exc}; nothing removed", file=sys.stderr)
        return 2

    by_reason: dict[str, int] = {}
    for why in reasons.values():
        by_reason[why] = by_reason.get(why, 0) + 1
    summary = ", ".join(f"{n} {why}" for why, n in sorted(by_reason.items()))
    total = sum(i.get("Size", 0) for i in remove) / 1e9
    print(f"docker-image-gc: {len(images)} images; protected {len(reasons)} ({summary})")

    if dry_run:
        for image in remove:
            print(f"would remove {describe(image)}")
        cache = get_json(api, "/system/df?type=build-cache").get("BuildCache") or []
        old = [c for c in cache if not c.get("InUse") and c.get("LastUsedAt")]
        print(
            f"docker-image-gc (dry run): {len(remove)} images would go (~{total:.1f} GB, shared layers "
            f"counted per image); {len(cache)} build-cache entries, {len(old)} not in use"
        )
        return 0

    counts = {"removed": 0, "skipped": 0, "kept": 0, "failed": 0}
    for image in remove:
        result = remove_image(api, image)
        counts[result] += 1
        print(f"{result} {describe(image)}")
    filters = urllib.parse.quote(json.dumps({"until": [f"{keep_days * 24}h"]}))
    status, body = api("POST", f"/build/prune?all=1&filters={filters}")
    if status != 200:
        print(f"docker-image-gc: build cache prune -> {status}: {body[:200]!r}", file=sys.stderr)
        counts["failed"] += 1
    else:
        freed = json.loads(body).get("SpaceReclaimed") or 0
        print(f"docker-image-gc: build cache older than {keep_days} days pruned ({freed / 1e9:.2f} GB)")
    print("docker-image-gc: " + ", ".join(f"{n} {k}" for k, n in counts.items()))
    return 1 if counts["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
