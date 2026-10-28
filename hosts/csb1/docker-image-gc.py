"""Docker image and build-cache GC for csb1 (OPS-327), ported from agm1's AGM-48.

`docker image prune --all` and `docker system prune -a` are off limits here: they
drop images that rollbacks and the Janus engine pipeline depend on, and the
latter also takes the unmounted Janus volumes (csb1 never-prune rule). So an
image goes only when it is none of:
  - used by any container, running or stopped
  - referenced by the running compose spec (csb1 and Janus-managed stack;
    a declared service may have no container yet, e.g. janus-engine-staged)
  - referenced by the compose spec of any NixOS system generation still on
    disk (every generation stays a working `nixos-rebuild --rollback` target)
  - the current or previous image of a compose service by pin history (the
    AEON release rollback path), even after the generations that declared it
    are gone: the history is kept in HISTORY_PATH and takes in each numbered
    generation once, in order (the booted and running systems are protected, but
    they are no release chronology)
  - listed in KEEP_DIR/*.refs (release kits write the image they prestage there
    before pulling it, and drop the file one release later); re-read before
    every batch and every delete
  - tagged *:rollback, or the newest image of its repository with a prev-* tag
    (HausV's own rollback target; HausV's stack is not Nix-declared)
  - in a protected repository (Janus engine / envelope: Pharos beacon tokens)
  - among the newest KEEP_NEWEST images of any repository it is tagged or
    pulled by digest in
  - younger than KEEP_DAYS (by build time)
Build cache older than KEEP_DAYS goes. Volumes are never touched.

Removal holds the compose deploy locks (reconcile, weekly update, HausV and
preview deploys) in batches of at most BATCH_S: every Engine call in a batch
gets the remaining budget as its timeout and none starts without enough budget
left. Every batch re-plans from fresh listings, generations, history and keep.d
taken under the lock, and every delete re-reads the generations and keep.d, so
neither a deploy nor a `nixos-rebuild boot` changes what is declared under it.
An unreadable generation, history or keep.d stops the run. Images are
deleted by ID without force (a name could have moved to another image); only an
image named in several repositories is untagged by name, each name re-checked
against a fresh listing first. noprune=1: untagged parents are left alone.

Everything comes from the Engine API list endpoints over the docker socket
(no inspect). DOCKER_IMAGE_GC_DRY_RUN=1 lists what would go and changes nothing.
"""

from __future__ import annotations

import errno
import fcntl
import http.client
import json
import os
import re
import socket
import sys
import time
import urllib.parse
from contextlib import contextmanager

SOCKET_PATH = "/var/run/docker.sock"
DECLARED_REFS: list[str] = json.loads(r"""@DECLARED_REFS@""")
PROTECTED_REPOS = frozenset(
    {
        "ghcr.io/inspr-at/janus/janus-engine",
        "ghcr.io/inspr-at/janus/janus-envelope",
    }
)
KEEP_DIR = "/var/lib/docker-image-gc/keep.d"
KEEP_LINE = re.compile(r"^[^\s@]+@sha256:[0-9a-f]{64}$")
# NixOS system generations (system-<n>-link, oldest first), then the booted and the running system.
PROFILES_DIR = "/nix/var/nix/profiles"
GENERATION = re.compile(r"^system-(\d+)-link$")
SYSTEM_LINKS = ("/run/booted-system", "/run/current-system")
COMPOSE_DIR = "etc/compose"
HISTORY_PATH = "/var/lib/docker-image-gc/history.json"
KEEP_RELEASES = 2
# Every compose deploy path on csb1 serializes on one of these (flock -w).
# Not the Janus Pharos lock: its scripts take it with flock -n and would fail.
LOCK_PATHS = (
    "/run/lock/compose-csb1.lock",
    "/run/lock/compose-hausv.lock",
    "/run/lock/compose-hausv-next.lock",
)
LOCK_WAIT_S = 300
BATCH_S = 60
# Budget a call needs at least before it starts; a call that then runs out of budget stops the run.
DELETE_NEED_S = 20
GET_NEED_S = 5


class Fatal(Exception):
    """The run cannot judge safely; nothing more is removed."""


class Busy(Exception):
    """A deploy holds a compose lock; this run stops without removing more."""


class BatchOver(Exception):
    """The batch budget is spent: give the locks back before the next call."""


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path: str, timeout: float) -> None:
        super().__init__("localhost", timeout=timeout)
        self.unix_path = path

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self.unix_path)
        self.sock = sock


def docker_api(method: str, path: str, timeout: float = 300) -> tuple[int, bytes]:
    conn = UnixHTTPConnection(SOCKET_PATH, timeout=timeout)
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


def compose_services(system: str) -> dict[str, str]:
    """{stack/service: image} from one NixOS system's etc/compose/<stack>/docker-compose.yml.

    A system without etc/compose (or whose link vanished, so it is no rollback target any more)
    declares nothing; any other read error, including a permission error, raises.
    """
    compose = os.path.join(system, COMPOSE_DIR)
    try:
        stacks = sorted(os.listdir(compose))
    except FileNotFoundError:
        return {}
    services: dict[str, str] = {}
    for stack in stacks:
        path = os.path.join(compose, stack, "docker-compose.yml")
        with open(path, encoding="utf-8") as fh:
            spec = json.load(fh)  # rendered by builtins.toJSON
        if not isinstance(spec, dict) or not isinstance(spec.get("services"), dict):
            raise Fatal(f"{path}: no services map")
        for name, service in spec["services"].items():
            if isinstance(service, dict) and isinstance(service.get("image"), str):
                services[f"{stack}/{name}"] = service["image"]
    return services


def generation_specs():
    """([(generation, services)] oldest first, [(booted/running system, services)]).

    The profiles directory is listed with scandir, which raises instead of hiding an
    unreadable directory the way glob does.
    """
    with os.scandir(PROFILES_DIR) as entries:
        found = [(int(m.group(1)), e.path) for e in entries if (m := GENERATION.match(e.name))]
    numbered = [(path, compose_services(path)) for _, path in sorted(found)]
    running = [(path, compose_services(path)) for path in SYSTEM_LINKS if os.path.lexists(path)]
    if not any(services for _, services in numbered + running):
        raise Fatal("no compose spec found in any NixOS system generation; refusing to judge")
    return numbered, running


def load_history(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            history = json.load(fh)
    except FileNotFoundError:
        return {"version": 2, "last_generation": 0, "services": {}}
    services = history.get("services") if isinstance(history, dict) else None
    last = history.get("last_generation", 0) if isinstance(history, dict) else None
    if (
        not isinstance(services, dict)
        or not all(isinstance(refs, list) and all(isinstance(r, str) for r in refs) for refs in services.values())
        or not isinstance(last, int)
    ):
        raise Fatal(f"{path} is not a pin history; refusing to judge")
    return {"version": 2, "last_generation": last, "services": services}


def update_history(history: dict, generations: list[tuple[int, dict[str, str]]]) -> dict:
    """Take in the numbered generations newer than the last one taken in, oldest first; keep the last
    KEEP_RELEASES distinct pins per service.

    Each generation counts once, when it is new: replaying older generations still on disk would
    rewind the history (v1 replayed after v3 pushes out v2). The booted and running systems are not
    generations here: appending an old booted pin would make it the "current" one.
    """
    services = {name: list(refs) for name, refs in history["services"].items()}
    last = history["last_generation"]
    if generations and max(n for n, _ in generations) < last:
        # The newest generations were deleted, or the profile was recreated and numbers started
        # over: take the newest on disk as the mark and replay nothing (that would rewind).
        last = max(n for n, _ in generations)
    for number, spec in sorted(generations, key=lambda g: g[0]):
        if number <= last:
            continue
        for name, ref in sorted(spec.items()):
            refs = services.setdefault(name, [])
            if refs and refs[-1] == ref:
                continue
            if ref in refs:
                refs.remove(ref)
            refs.append(ref)
            del refs[:-KEEP_RELEASES]
        last = number
    return {"version": 2, "last_generation": last, "services": services}


def save_history(path: str, history: dict) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(history, fh, indent=1, sort_keys=True)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def read_keep(path: str) -> list[str]:
    """Every ref in path/*.refs: one name[:tag]@sha256:<digest> per line, # comments and blanks allowed."""
    if not os.path.isdir(path):
        raise Fatal(f"{path} is missing; refusing to judge")
    refs = []
    for name in sorted(os.listdir(path)):
        if not name.endswith(".refs"):
            continue
        with open(os.path.join(path, name), encoding="utf-8") as fh:
            for n, raw in enumerate(fh, start=1):
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                if not KEEP_LINE.match(line):
                    raise Fatal(f"{name}:{n}: not a name[:tag]@sha256:<digest> ref: {line[:120]!r}")
                refs.append(line)
    return refs


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
        # Protection reads the names: a listing without them must not read as "untagged".
        for key in ("RepoTags", "RepoDigests"):
            names = i.get(key)
            usable = names is None or (isinstance(names, list) and all(isinstance(n, str) for n in names))
            if key not in i or not usable:
                raise Fatal(f"image {i['Id'][:19]} without a usable {key}: {str(i)[:120]}")


def plan(containers, images, refsets: dict[str, list[str]], now: float, keep_days: int, keep_newest: int):
    """Return ({image id: first protecting reason}, [images to remove, newest first])."""
    validate(containers, images)
    reasons: dict[str, str] = {}

    def protect(image_id: str, why: str) -> None:
        reasons.setdefault(image_id, why)

    for c in containers:
        protect(c["ImageID"], "used by a container")
    for why, refs in refsets.items():
        for image_id in declared_ids(images, refs):
            protect(image_id, why)

    newest_first = sorted(images, key=lambda i: (i["Created"], i["Id"]), reverse=True)
    per_repo: dict[str, int] = {}
    prev_seen: set[str] = set()
    cutoff = now - keep_days * 86400
    for image in newest_first:
        image_id = image["Id"]
        if any(t.endswith(":rollback") for t in tags_of(image)):
            protect(image_id, "tagged :rollback")
        for tag in tags_of(image):
            repo, _, name = tag.rpartition(":")
            if name.startswith("prev-") and "/" not in name and repo not in prev_seen:
                prev_seen.add(repo)
                protect(image_id, "newest prev-* of its repository")
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


def delete(api, ref: str) -> tuple[int, str]:
    status, body = api("DELETE", "/images/" + urllib.parse.quote(ref, safe="/:@") + "?noprune=1")
    return status, body.decode("utf-8", "replace")


def classify(status: int, text: str, ref: str) -> str:
    # Untagging says "container X is using its referenced image"; deleting
    # by ID says "image is being used by ... container".
    if status == 409 and ("being used" in text or "is using" in text):
        return "skipped"
    if status == 409 and "dependent child" in text:
        return "kept"
    print(f"docker-image-gc: DELETE {ref} -> {status}: {text[:200]}", file=sys.stderr)
    return "failed"


def remove_image(api, image: dict) -> str:
    """Delete one planned image. Returns removed / skipped / kept / failed."""
    image_id = image["Id"]
    status, text = delete(api, image_id)
    if status in (200, 404):
        return "removed"
    if status == 409 and "referenced in" in text:
        # Named in more than one repository: untag by name, but only names that
        # a fresh listing still shows on this image.
        for ref in tags_of(image) + digests_of(image):
            owners = [i["Id"] for i in get_json(api, "/images/json") if ref in tags_of(i) + digests_of(i)]
            if not owners:
                continue
            if owners != [image_id]:
                print(f"docker-image-gc: {ref} now names another image; keeping {image_id[7:19]}")
                return "kept"
            status, text = delete(api, ref)
            if status not in (200, 404):
                return classify(status, text, ref)
        status, text = delete(api, image_id)
        if status in (200, 404):
            return "removed"
    return classify(status, text, image_id)


@contextmanager
def deploy_locks(paths, wait_s: float, sleep=time.sleep):
    """Hold every compose deploy lock, or raise Busy after wait_s. Never holds one while waiting for another."""
    deadline = time.monotonic() + wait_s
    while True:
        fds, busy = [], None
        try:
            for path in paths:
                # Like flock(1): open read-only, create if missing.
                fd = os.open(path, os.O_RDONLY | os.O_CREAT | os.O_CLOEXEC, 0o666)
                fds.append(fd)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except OSError as exc:
                    if exc.errno not in (errno.EWOULDBLOCK, errno.EAGAIN):
                        raise
                    busy = path
                    break
            if busy is None:
                yield
                return
        finally:
            for fd in fds:
                os.close(fd)
        if time.monotonic() >= deadline:
            raise Busy(busy)
        sleep(5)


def listings(api):
    return get_json(api, "/containers/json?all=1"), get_json(api, "/images/json")


def protection(save: bool):
    """(number of NixOS systems, {reason: refs}) from the generations, the pin history and keep.d, read now.

    save writes the replayed history (never in a dry run).
    """
    numbered, running = generation_specs()
    history = update_history(
        load_history(HISTORY_PATH),
        [(int(GENERATION.match(os.path.basename(path)).group(1)), spec) for path, spec in numbered],
    )
    if save:
        save_history(HISTORY_PATH, history)
    refsets = {
        "declared in the running compose spec": DECLARED_REFS,
        "declared in a NixOS generation": [ref for _, spec in numbered + running for ref in spec.values()],
        "current/previous pin of its service": [ref for refs in history["services"].values() for ref in refs],
        "listed in keep.d": read_keep(KEEP_DIR),
    }
    return len(numbered) + len(running), refsets


def budgeted(api, deadline: float):
    """api for one batch: a call starts only with enough budget left and gets the rest as its timeout."""

    def call(method: str, path: str) -> tuple[int, bytes]:
        left = deadline - time.monotonic()
        if left < (DELETE_NEED_S if method == "DELETE" else GET_NEED_S):
            raise BatchOver()
        return api(method, path, timeout=left)

    return call


def main(api=docker_api, now: float | None = None, sleep=time.sleep) -> int:
    dry_run = os.environ.get("DOCKER_IMAGE_GC_DRY_RUN", "0") == "1"
    try:
        keep_days = env_int("DOCKER_IMAGE_GC_KEEP_DAYS", 2)
        keep_newest = env_int("DOCKER_IMAGE_GC_KEEP_NEWEST", 3)
        systems, refsets = protection(save=not dry_run)
        containers, images = listings(api)
        now = time.time() if now is None else now
        reasons, remove = plan(containers, images, refsets, now, keep_days, keep_newest)
    except (Fatal, OSError, ValueError) as exc:
        print(f"docker-image-gc: {exc}; nothing removed", file=sys.stderr)
        return 2

    by_reason: dict[str, int] = {}
    for why in reasons.values():
        by_reason[why] = by_reason.get(why, 0) + 1
    summary = ", ".join(f"{n} {why}" for why, n in sorted(by_reason.items()))
    total = sum(i.get("Size", 0) for i in remove) / 1e9
    print(f"docker-image-gc: {len(images)} images, {systems} NixOS systems; protected {len(reasons)} ({summary})")

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
    attempted: set[str] = set()
    try:
        while True:
            with deploy_locks(LOCK_PATHS, LOCK_WAIT_S, sleep):
                batch = budgeted(api, time.monotonic() + BATCH_S)
                done = 0
                try:
                    # Re-plan under the lock: a deploy or a new generation since the last batch may use or name an image now.
                    _, refsets = protection(save=True)
                    containers, images = listings(batch)
                    _, remove = plan(containers, images, refsets, now, keep_days, keep_newest)
                    todo = [i for i in remove if i["Id"] not in attempted]
                    if not todo:
                        break
                    for image in todo:
                        # A kit may list an image it prestages (outside the compose lock), and
                        # `nixos-rebuild boot` may declare one, at any time: re-read both first.
                        _, fresh = protection(save=False)
                        if declared_ids([image], [ref for refs in fresh.values() for ref in refs]):
                            attempted.add(image["Id"])
                            result = "kept"
                        else:
                            result = remove_image(batch, image)
                            attempted.add(image["Id"])
                        counts[result] += 1
                        done += 1
                        print(f"{result} {describe(image)}")
                except BatchOver:
                    if not done:
                        raise Fatal(f"not one image fit into a {BATCH_S} s batch") from None
            # Let a deploy that waits on a lock (flock -w) in before the next batch.
            sleep(2)
    except Busy as busy:
        print(f"docker-image-gc: {busy} held by a deploy for {LOCK_WAIT_S} s; stopping this run")
    except (Fatal, OSError, ValueError) as exc:
        print(f"docker-image-gc: {exc}; nothing more removed", file=sys.stderr)
        print("docker-image-gc: " + ", ".join(f"{n} {k}" for k, n in counts.items()))
        return 2

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
