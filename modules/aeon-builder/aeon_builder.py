#!/usr/bin/env python3
"""NIX-600: mbp2606 as a switchable self-hosted runner pool for inspr-at/paimos.

Mode B of the AEON-438 contract (paimos docs/RELEASE.md): there are never idle
registered runners. The controller watches the repository's queued jobs, verifies
each one that asks for the mbp2606 label through the API, and only then clones a
fresh Lima VM from the sealed base, checks that the VM cannot reach the LAN, the
tailnet or the host, and mints a single-job JIT runner inside it. Unverified runs
aimed at mbp2606 are cancelled. The VM is deleted after its one job.

The GitHub App key stays in this user's config and never enters a VM; every API
call uses an installation token cut down to the one permission it needs.
"""

import argparse
import base64
import contextlib
import datetime as dt
import fcntl
import grp
import http.client
import ipaddress
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from collections import deque
from pathlib import Path

API = "https://api.github.com"
VARIABLE = "AEON_MBP2606_AVAILABILITY"
BASE_VM = "aeon-base"
HOME = Path.home()
CONFIG_DIR = HOME / ".config/aeon-builder"
STATE_DIR = HOME / ".local/state/aeon-builder"
DEFAULT_CONFIG = CONFIG_DIR / "config.json"

READ = {"actions": "read", "metadata": "read"}
# Every run status in which a job can still be waiting for a runner.
ACTIVE_STATUSES = ("queued", "in_progress", "waiting", "pending", "requested")
MAX_PAGES = 20
# Leave room before the job-started hook's AEON_CACHE_WAIT=240 self-deny.
ADMISSION_WAIT_SECONDS = 150
ADMISSION_API_UNAVAILABLE_LIMIT = 3
ADMISSION_API_UNAVAILABLE_WINDOW_SECONDS = 30 * 60
CANCEL = {"actions": "write"}
ADMIN_READ = {"administration": "read"}
ADMIN_WRITE = {"administration": "write"}
VARIABLES = {"actions_variables": "write"}


class BuilderError(RuntimeError):
    pass


class TransientGitHubError(BuilderError):
    """A temporary API failure after the request's bounded retry budget."""


# ---------------------------------------------------------------- pure policy


def normalize_workflow_path(path):
    return (path or "").split("@", 1)[0]


def verify_run(run, cfg, sha_on_branch):
    """Mode-B admission for one workflow run. Missing metadata rejects."""
    repo = cfg["repo"]
    if (run.get("repository") or {}).get("full_name") != repo:
        return False, "repository mismatch"
    head = (run.get("head_repository") or {}).get("full_name")
    if head != repo:
        return False, f"head repository {head or 'missing'}"
    event = run.get("event")
    if event not in cfg["events"]:
        return False, f"event {event or 'missing'} not allowed"
    path = normalize_workflow_path(run.get("path"))
    if path not in cfg["workflows"]:
        return False, f"workflow {path or 'missing'} not allowed"
    branch_required = event not in ("pull_request", "merge_group")
    if branch_required and run.get("head_branch") != cfg["branch"]:
        return False, f"branch {run.get('head_branch') or 'missing'}"
    sha = run.get("head_sha") or ""
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        return False, "head sha missing"
    if branch_required and not sha_on_branch(sha):
        return False, "head sha not reachable from branch"
    return True, "ok"


def wants_label(job, label):
    return label.lower() in [str(item).lower() for item in job.get("labels") or []]


def could_take(job, runner_labels):
    """GitHub assigns a queued job to any runner whose labels include ALL of the
    job's runs-on labels (case-insensitive). `runs-on: self-hosted` alone
    therefore fits an mbp2606 runner too, so sweeps match subsets, not the label."""
    wanted = {str(item).lower() for item in job.get("labels") or []}
    if not wanted:
        return True  # missing evidence: fail closed
    return wanted <= {label.lower() for label in runner_labels}


def job_classes(job, cfg):
    """The configured event class labels a job asks for."""
    names = {name.lower() for name in cfg["classLabels"].values()}
    return {str(item).lower() for item in job.get("labels") or []} & names


def expected_class(run, cfg):
    return cfg["classLabels"].get(run.get("event"))


def class_ok(job, run, cfg):
    """AEON-459: a mint candidate carries exactly one class label, the one its
    run's verified event maps to. Anything else is never minted for."""
    expected = expected_class(run, cfg)
    return expected is not None and job_classes(job, cfg) == {expected.lower()}


def mint_labels(cfg, run):
    """Base labels plus exactly one event class (GitHub matches runs-on as a
    subset), so a class-labelled job only fits a runner of the same class."""
    return list(cfg["runnerLabels"]) + [expected_class(run, cfg)]


def pool_labels(cfg):
    """Every label any pool runner can carry: the widest sweep target."""
    return list(cfg["runnerLabels"]) + sorted(set(cfg["classLabels"].values()))


def uses_cache_disk(run, cfg):
    """Trusted caches are writable only by pushes to the branch (AEON-438)."""
    return run.get("event") in cfg["cacheWriteEvents"]


RULESET_KEYS = ("enforcement", "target", "conditions", "bypass_actors", "rules")


def canonical(value):
    """Order-insensitive form: lists of dicts are sorted by their JSON."""
    if isinstance(value, dict):
        return {k: canonical(v) for k, v in sorted(value.items())}
    if isinstance(value, list):
        items = [canonical(v) for v in value]
        return sorted(items, key=lambda v: json.dumps(v, sort_keys=True))
    return value


def ruleset_drift(ruleset, expected, limit=600):
    """Diagnostic only (OPS-329): which rule types and parameters differ, so a
    pause log shows what GitHub returned. Never decides anything."""
    if not ruleset:
        return "ruleset missing"
    out = []
    for key in RULESET_KEYS:
        if key == "rules" or canonical(ruleset.get(key)) == canonical(expected.get(key)):
            continue
        out.append(f"{key}: expected {json.dumps(canonical(expected.get(key)))[:120]} got {json.dumps(canonical(ruleset.get(key)))[:120]}")
    def by_type(rules):
        rules = rules if isinstance(rules, list) else []
        return {str(r.get("type")): r for r in rules if isinstance(r, dict)}
    live, pinned = by_type(ruleset.get("rules")), by_type(expected.get("rules"))
    for kind in sorted(set(pinned) - set(live)):
        out.append(f"rule {kind} missing")
    for kind in sorted(set(live) - set(pinned)):
        out.append(f"rule {kind} added")
    for kind in sorted(set(live) & set(pinned)):
        a, b = canonical(pinned[kind]), canonical(live[kind])
        if a == b:
            continue
        params_a, params_b = a.get("parameters"), b.get("parameters")
        params_a = params_a if isinstance(params_a, dict) else {"(parameters)": params_a}
        params_b = params_b if isinstance(params_b, dict) else {"(parameters)": params_b}
        diffs = [f"{k}: {json.dumps(params_a.get(k))[:60]} -> {json.dumps(params_b.get(k))[:60]}"
                 for k in sorted(set(params_a) | set(params_b)) if params_a.get(k) != params_b.get(k)]
        other = sorted(k for k in set(a) | set(b) if k != "parameters" and a.get(k) != b.get(k))
        out.append(f"rule {kind}: " + "; ".join(diffs + [f"{k} differs" for k in other]))
    return " | ".join(out)[:limit] or "no difference found on this read"


def ruleset_problems(ruleset, expected):
    """The live main ruleset must equal the pinned one exactly (AEON-438):
    enforcement, target, ref conditions, bypass actors, rules and parameters."""
    if not ruleset:
        return ["ruleset missing"]
    problems = [f"{key} changed" for key in RULESET_KEYS
                if canonical(ruleset.get(key)) != canonical(expected.get(key))]
    if ruleset.get("enforcement") != "active":
        problems.insert(0, f"enforcement is {ruleset.get('enforcement')}")
    return problems


def load_gate(gated, load1, high, low):
    """Hysteresis: equal thresholds retain the previous gate state."""
    if load1 > high:
        return True
    if load1 < low:
        return False
    return gated


def memory_gate(gated, free, high, low):
    if free is None or free >= high:
        return False
    if free < low:
        return True
    return gated


def get_memory_free():
    proc = subprocess.run(["/usr/bin/memory_pressure", "-Q"], capture_output=True, text=True,
                          check=True, timeout=5)
    match = re.search(r"System-wide memory free percentage:\s*(\d+(?:\.\d+)?)%", proc.stdout)
    if not match or not 0 <= float(match[1]) <= 100:
        raise ValueError("memory_pressure free percentage missing or invalid")
    return float(match[1])


def availability_record(cfg, free_slots, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    return {
        "schema": 2,
        "repository": cfg["repo"],
        "os": "linux",
        "arch": "arm64",
        "online": True,
        "busy": free_slots <= 0,
        "observed_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "idle_runners": max(free_slots, 0),
        "events": sorted(cfg["events"]),
    }


def clone_expression(cfg, slot, disk, fresh=True):
    """A cloned disk keeps its filesystem (labelled for its source disk), so only
    a fresh disk lets Lima format; otherwise Lima just mounts partition 1."""
    ports = cfg["sshPortBase"] + slot
    fmt = "true" if fresh else "false"
    expr = [
        f".cpus = {int(cfg['slotCpus'])}",
        f'.memory = "{int(cfg["slotMemoryGiB"])}GiB"',
        f".ssh.localPort = {ports}",
        '.additionalDisks = [{"name": "%s", "format": %s, "fsType": "ext4"}]' % (disk, fmt) if disk else ".additionalDisks = []",
    ]
    return " | ".join(expr)


def base_expression(cfg):
    ignore_all = [
        {"guestIP": ip, "guestIPMustBeZero": False, "guestPortRange": [1, 65535], "hostPortRange": [1, 65535], "ignore": True}
        for ip in ("0.0.0.0", "127.0.0.1")
    ]
    expr = [
        ".mounts = []",
        f".portForwards = {json.dumps(ignore_all)}",
        ".containerd.system = false",
        ".containerd.user = false",
        ".ssh.forwardAgent = false",
        f".cpus = {int(cfg['slotCpus'])}",
        f'.memory = "{int(cfg["slotMemoryGiB"])}GiB"',
        f'.disk = "{int(cfg["slotDiskGiB"])}GiB"',
        f".ssh.localPort = {cfg['sshPortBase'] - 1}",
    ]
    return " | ".join(expr)


def pf_rules(cfg, user):
    first = cfg["sshPortBase"] - 1
    last = cfg["sshPortBase"] + cfg["slots"] - 1
    private = ", ".join(cfg["blockedNetworks"])
    return "\n".join([
        "# aeon-builder (NIX-600): Lima usernet egress leaves the Mac as this user.",
        "# Keep it off the LAN, the tailnet and host loopback; the internet stays open.",
        "# No DNS exception: the hostagent resolves through mDNSResponder, not as this user.",
        f"table <aeon_private> const {{ {private} }}",
        "pass in quick proto tcp from any to any port 22 keep state",
        "# Lima's own ssh (limactl <-> hostagent vsock proxy): both directions, stateless,",
        "# because the replies also come from a socket owned by this user.",
        f"pass out quick on lo0 proto tcp from 127.0.0.1 to 127.0.0.1 port {first}:{last} user {user} no state",
        f"pass out quick on lo0 proto tcp from 127.0.0.1 port {first}:{last} to 127.0.0.1 user {user} no state",
        f"block return out quick from any to <aeon_private> user {user}",
        "",
    ])


def allowlist_document(cfg):
    branch_ref = f"refs/heads/{cfg['branch']}"
    return {
        "repo": cfg["repo"],
        "events": cfg["events"],
        "ref": branch_ref,
        "workflowRefs": [f"{cfg['repo']}/{path}@{branch_ref}" for path in cfg["workflows"]],
    }


def parse_hook_log(text):
    allows, denies = [], []
    for line in text.splitlines():
        if line.startswith("aeon-hook allow "):
            fields = dict(item.split("=", 1) for item in line[len("aeon-hook allow "):].split() if "=" in item)
            allows.append(fields)
        elif line.startswith("aeon-hook deny"):
            denies.append(line)
    return allows, denies


# ---------------------------------------------------------------- GitHub


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


class GitHub:
    def __init__(self, cfg, sleep=time.sleep):
        self.cfg = cfg
        self.sleep = sleep
        env = {}
        for line in Path(cfg["appEnv"]).read_text().splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                env[key.strip()] = value.strip()
        self.app_id = env["app_id"]
        self.installation_id = env["installation_id"]
        self.key = cfg["appKey"]
        self.tokens = {}
        self.etags = {}
        self.lock = threading.Lock()

    def _jwt(self):
        now = int(time.time())
        head = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
        body = b64url(json.dumps({"iat": now - 60, "exp": now + 540, "iss": self.app_id}).encode())
        signed = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", self.key],
            input=f"{head}.{body}".encode(), capture_output=True, check=True,
        ).stdout
        return f"{head}.{body}.{b64url(signed)}"

    def token(self, perms):
        key = tuple(sorted(perms.items()))
        with self.lock:
            cached = self.tokens.get(key)
            if cached and cached[1] > time.time():
                return cached[0]
            repo_name = self.cfg["repo"].split("/", 1)[1]
            data = self._raw("POST", f"/app/installations/{self.installation_id}/access_tokens",
                             {"repositories": [repo_name], "permissions": perms}, bearer=self._jwt())
            self.tokens[key] = (data["token"], time.time() + 600)
            return data["token"]

    def _raw(self, method, path, body=None, bearer=None, etag_key=None):
        url = path if path.startswith("http") else API + path
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        req.add_header("User-Agent", "aeon-builder")
        req.add_header("Authorization", f"Bearer {bearer}")
        if etag_key and etag_key in self.etags:
            req.add_header("If-None-Match", self.etags[etag_key][0])
        # Only idempotent reads retry; token minting and all other writes stay
        # single-shot. Keep the same request (including its conditional ETag).
        attempts = 3 if method == "GET" else 1
        for attempt in range(attempts):
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    raw = resp.read()
                    parsed = json.loads(raw) if raw else {}
                    if etag_key and resp.headers.get("ETag"):
                        self.etags[etag_key] = (resp.headers["ETag"], parsed)
                    return parsed
            except urllib.error.HTTPError as err:
                try:
                    if err.code == 304 and etag_key in self.etags:
                        return self.etags[etag_key][1]
                    try:
                        detail = err.read()[:300].decode(errors="replace")
                    except (http.client.HTTPException, OSError):
                        detail = ""
                    transient = 500 <= err.code < 600
                    message = f"{method} {path}: HTTP {err.code} {detail}"
                finally:
                    err.close()
            except (urllib.error.URLError, http.client.HTTPException, TimeoutError, OSError, ValueError) as err:
                reason = err.reason if isinstance(err, urllib.error.URLError) else err
                transient = isinstance(reason, (http.client.HTTPException, OSError))
                message = f"{method} {path}: {type(err).__name__}: {err}"
            if not transient:
                raise BuilderError(message) from None
            if attempt == attempts - 1:
                raise TransientGitHubError(message) from None
            self.sleep(attempt + 1)

    def call(self, method, path, perms, body=None, cache=False):
        return self._raw(method, path, body, bearer=self.token(perms), etag_key=path if cache and method == "GET" else None)

    # repository helpers
    def repo_path(self, suffix):
        return f"/repos/{self.cfg['repo']}{suffix}"

    def paged(self, path, key, perms, cache=False):
        items = []
        sep = "&" if "?" in path else "?"
        for page in range(1, MAX_PAGES + 1):
            batch = self.call("GET", f"{path}{sep}per_page=100&page={page}", perms, cache=cache).get(key, [])
            items.extend(batch)
            if len(batch) < 100:
                return items
        raise BuilderError(f"{path}: more than {MAX_PAGES} pages; refusing to decide on a partial list")

    def runs(self, status):
        return self.paged(self.repo_path(f"/actions/runs?status={status}"), "workflow_runs", READ, cache=True)

    def active_runs(self):
        seen = {}
        for status in ACTIVE_STATUSES:
            for run in self.runs(status):
                seen[run["id"]] = run
        return list(seen.values())

    def jobs(self, run_id):
        return self.paged(self.repo_path(f"/actions/runs/{run_id}/jobs?filter=latest"), "jobs", READ, cache=True)

    def job(self, job_id):
        return self.call("GET", self.repo_path(f"/actions/jobs/{job_id}"), READ)

    def run(self, run_id):
        return self.call("GET", self.repo_path(f"/actions/runs/{run_id}"), READ)

    def all_jobs(self, run_id):
        return self.paged(self.repo_path(f"/actions/runs/{run_id}/jobs?filter=all"), "jobs", READ)

    def recent_runs(self):
        return self.call("GET", self.repo_path("/actions/runs?per_page=30"), READ).get("workflow_runs", [])

    def sha_on_branch(self, sha):
        data = self.call("GET", self.repo_path(f"/compare/{sha}...{self.cfg['branch']}"), READ)
        return data.get("status") in ("ahead", "identical") and data.get("behind_by") == 0

    def cancel(self, run_id):
        self.call("POST", self.repo_path(f"/actions/runs/{run_id}/cancel"), CANCEL, {})

    def ruleset(self):
        # administration:read gets the ruleset without bypass_actors (GitHub hides
        # them), which the exact comparison rightly rejects; write sees them.
        return self.call("GET", self.repo_path(f"/rulesets/{self.cfg['ruleset']['id']}"), ADMIN_WRITE)

    def ruleset_versions(self):
        """Independent, uncached history signal; never infer a version from the
        ruleset content. The history endpoint needs administration:read, already
        granted to this App. Refuse empty, malformed or truncated histories."""
        path = self.repo_path(f"/rulesets/{self.cfg['ruleset']['id']}/history")
        versions = {}
        for page in range(1, MAX_PAGES + 1):
            batch = self.call("GET", f"{path}?per_page=100&page={page}", ADMIN_READ)
            if not isinstance(batch, list):
                raise BuilderError("ruleset history is not a list")
            for item in batch:
                version = item.get("version_id") if isinstance(item, dict) else None
                if type(version) is not int or version < 1:
                    raise BuilderError("ruleset history has an invalid version_id")
                versions[version] = item.get("updated_at")
            if len(batch) < 100:
                if not versions:
                    raise BuilderError("ruleset history is empty")
                return versions
        raise BuilderError("ruleset history exceeds the page limit")

    def jit(self, name, labels):
        body = {"name": name, "runner_group_id": 1, "labels": labels, "work_folder": "_work"}
        return self.call("POST", self.repo_path("/actions/runners/generate-jitconfig"), ADMIN_WRITE, body)

    def runners(self):
        return self.call("GET", self.repo_path("/actions/runners?per_page=100"), ADMIN_READ).get("runners", [])

    def delete_runner(self, runner_id):
        try:
            self.call("DELETE", self.repo_path(f"/actions/runners/{runner_id}"), ADMIN_WRITE)
        except BuilderError as err:
            if "HTTP 404" not in str(err):
                raise

    def publish(self, record):
        value = json.dumps(record, separators=(",", ":"))
        try:
            self.call("PATCH", self.repo_path(f"/actions/variables/{VARIABLE}"), VARIABLES, {"name": VARIABLE, "value": value})
        except BuilderError as err:
            if "HTTP 404" not in str(err):
                raise
            self.call("POST", self.repo_path("/actions/variables"), VARIABLES, {"name": VARIABLE, "value": value})

    def clear(self):
        try:
            self.call("DELETE", self.repo_path(f"/actions/variables/{VARIABLE}"), VARIABLES)
        except BuilderError as err:
            if "HTTP 404" not in str(err):
                raise


# ---------------------------------------------------------------- Lima


class Lima:
    def __init__(self, cfg):
        self.cfg = cfg
        self.bin = cfg["limactl"]

    def run(self, *args, input=None, check=True, timeout=900):
        proc = subprocess.run([self.bin, *args], input=input, capture_output=True, text=True, timeout=timeout)
        if check and proc.returncode:
            raise BuilderError(f"limactl {' '.join(args[:2])}: {proc.stderr.strip()[-400:]}")
        return proc

    def instances(self):
        """Raises when limactl cannot list: an unknown inventory is never 'empty'."""
        proc = self.run("list", "--json", check=False)
        if proc.returncode != 0:
            raise BuilderError(f"limactl list failed: {proc.stderr.strip()[-200:]}")
        try:
            return {item["name"]: item for item in (json.loads(line) for line in proc.stdout.splitlines() if line.strip())}
        except (ValueError, KeyError) as err:
            raise BuilderError(f"limactl list output unreadable: {err}") from None

    def disks(self):
        """Raises when limactl cannot list disks: unknown is never 'none'."""
        proc = self.run("disk", "list", "--json", check=False)
        if proc.returncode != 0:
            raise BuilderError(f"limactl disk list failed: {proc.stderr.strip()[-200:]}")
        try:
            return {item["name"]: item for item in (json.loads(line) for line in proc.stdout.splitlines() if line.strip())}
        except (ValueError, KeyError) as err:
            raise BuilderError(f"limactl disk list output unreadable: {err}") from None

    def delete_disk(self, name):
        """Delete a disk and verify it is gone; raises otherwise."""
        self.run("disk", "delete", "--force", name, check=False)
        if name in self.disks():
            raise BuilderError(f"disk {name} could not be deleted")

    def shell(self, name, command, input=None, check=True, timeout=300):
        return self.run("shell", "--workdir", "/", name, "--", "bash", "-c", command, input=input, check=check, timeout=timeout)

    def delete(self, name):
        """Delete and verify; True when the instance is gone."""
        for _ in range(3):
            self.run("delete", "--force", name, check=False)
            try:
                if name not in self.instances():
                    return True
            except BuilderError as err:
                log(f"cannot verify deletion of {name}: {err}")
            time.sleep(2)
        log(f"limactl could not delete {name}")
        return False


# ---------------------------------------------------------------- state


def now_utc():
    return dt.datetime.now(dt.timezone.utc)


def atomic_write(path, text, mode=0o600, group=None):
    gid = grp.getgrnam(group).gr_gid if group is not None else None
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as handle:
            os.fchmod(fd, mode)
            if gid is not None:
                os.fchown(fd, -1, gid)
            handle.write(text)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


_busy_file_errors = {}


def write_busy_file(cfg, data):
    path = Path(cfg.get("busyFile", "/Users/Shared/ci-pool-busy"))
    last_error = STATE_DIR / "busy-file.lasterror"
    try:
        atomic_write(path, f"{len(data['slots'])}/{cfg['slots']} {int(time.time())}\n",
                     mode=0o640, group=cfg.get("busyFileGroup", "staff"))
    except (OSError, KeyError) as err:
        message = f"busy file write failed: {err}"
        # Failed renames name a fresh random temp file on every attempt.
        error = json.dumps((err.errno, err.strerror or str(err)) if isinstance(err, OSError) else str(err))
        try:
            previous = last_error.read_text()
        except OSError:
            previous = _busy_file_errors.get(path)
        if previous == error:
            return
        _busy_file_errors[path] = error
        try:
            atomic_write(last_error, error)
        except OSError:
            pass  # Keep the in-process fallback when the state directory is unwritable.
        try:
            log(message)
        except OSError:
            print(message, file=sys.stderr)
    else:
        _busy_file_errors.pop(path, None)
        try:
            if last_error.exists():
                atomic_write(last_error, "")
        except OSError:
            pass


class State:
    """state.json shared by the controller's threads and the CLI process. Every
    read-modify-write holds an flock (processes) and an RLock (threads)."""

    _thread_lock = threading.RLock()
    _local = threading.local()

    def __init__(self, root=STATE_DIR):
        self.root = root
        self.file = root / "state.json"
        self.lockfile = root / "state.lock"

    @contextlib.contextmanager
    def locked(self):
        with State._thread_lock:
            depth = getattr(State._local, "depth", 0)
            if depth:
                # A nested read-modify-write would be overwritten by the outer
                # save; refuse instead of losing it.
                raise RuntimeError("nested State lock")
            self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
            with open(self.lockfile, "a") as handle:
                fcntl.flock(handle, fcntl.LOCK_EX)
                State._local.depth = 1
                try:
                    yield
                finally:
                    State._local.depth = 0
                    fcntl.flock(handle, fcntl.LOCK_UN)

    def load(self):
        try:
            data = json.loads(self.file.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            data = {}
        data.setdefault("mode", "off")
        for key, empty in (("slots", {}), ("verifiedRuns", []), ("cancelledRuns", [])):
            data.setdefault(key, empty)
        return data

    def save(self, data):
        atomic_write(self.file, json.dumps(data, indent=2, sort_keys=True))

    def update(self, fn, then=None):
        """Read-modify-write under the lock; `then` runs before the lock is
        released, so ordering with other processes' publishes is kept."""
        with self.locked():
            data = self.load()
            fn(data)
            self.save(data)
            if then:
                then(data)
            return data


def reject_quarantine_window(data):
    """Close an uncertain window on recovery, pause or stop, under State's lock."""
    quarantine = data.pop("rulesetQuarantine", None)
    if quarantine:
        data.setdefault("rulesetRejectedWindows", []).append({
            "since": quarantine["cutoff"], "until": time.time(),
        })


def stop_pool(data, mode="off"):
    reject_quarantine_window(data)
    data.update(mode=mode)


def log(message):
    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    line = f"{now_utc().strftime('%Y-%m-%dT%H:%M:%SZ')} {message}"
    path = STATE_DIR / "controller.log"
    if path.exists() and path.stat().st_size > 5_000_000:
        os.replace(path, STATE_DIR / "controller.log.1")
    with open(path, "a") as handle:
        handle.write(line + "\n")
    print(line, flush=True)


# ---------------------------------------------------------------- controller


def host_probe_targets(cfg):
    targets = list(cfg["probeTargets"])
    out = subprocess.run(["/sbin/ifconfig"], capture_output=True, text=True).stdout
    for addr in re.findall(r"inet (\d+\.\d+\.\d+\.\d+)", out):
        ip = ipaddress.ip_address(addr)
        if not ip.is_loopback and not ip.is_link_local:
            targets.append(f"{addr}:22")
    route = subprocess.run(["/sbin/route", "-n", "get", "default"], capture_output=True, text=True).stdout
    gateway = re.search(r"gateway: (\d+\.\d+\.\d+\.\d+)", route)
    if gateway:
        targets += [f"{gateway.group(1)}:53", f"{gateway.group(1)}:80", f"{gateway.group(1)}:443"]
    return sorted(set(targets))


PROBE = r"""
leaks=""
for t in "$@"; do
  if timeout 3 bash -c "</dev/tcp/${t%:*}/${t#*:}" 2>/dev/null; then leaks="$leaks $t"; fi
done
getent hosts api.github.com >/dev/null || { echo "name resolution broken"; exit 3; }
timeout 5 bash -c '</dev/tcp/api.github.com/443' 2>/dev/null || { echo "internet unreachable"; exit 3; }
if [ -n "$leaks" ]; then echo "reachable:$leaks"; exit 2; fi
echo "blocked"
"""


def prove_network_block(cfg, lima, vm="aeon-probe"):
    """Boot a throwaway clone and require the host, LAN and tailnet to be
    unreachable while the internet works. This proves the pf anchor from the
    outside: an absent or inactive anchor means the pool stays off."""
    lima.delete(vm)
    try:
        lima.run("clone", "--tty=false", BASE_VM, vm, "--set",
                 f".ssh.localPort = {cfg['sshPortBase'] - 1} | .additionalDisks = []")
        lima.run("start", "--tty=false", vm)
        probe = lima.run("shell", "--workdir", "/", vm, "--", "bash", "-c", PROBE, "probe",
                         *host_probe_targets(cfg), check=False)
        return probe.returncode == 0, (probe.stdout.strip() or probe.stderr.strip()[-200:])
    finally:
        lima.delete(vm)


class Controller:
    def __init__(self, cfg, gh=None, lima=None, state=None, getloadavg=os.getloadavg,
                 getmemoryfree=get_memory_free):
        self.cfg = {**cfg, "loadHigh": float(cfg["loadHigh"]), "loadLow": float(cfg["loadLow"]),
                    "memFreeHigh": float(cfg.get("memFreeHigh", 45)), "memFreeLow": float(cfg.get("memFreeLow", 35)),
                    "memHoldSeconds": cfg.get("memHoldSeconds", 600),
                    "claimSpacingSeconds": cfg.get("claimSpacingSeconds", 180),
                    "rulesetQuarantineEnable": cfg.get("rulesetQuarantineEnable", True),
                    "rulesetQuarantineGraceSeconds": cfg.get("rulesetQuarantineGraceSeconds", 600),
                    "rulesetQuarantineCleanReads": max(2, cfg.get("rulesetQuarantineCleanReads", 2)),
                    "rulesetQuarantineMaxPerDay": cfg.get("rulesetQuarantineMaxPerDay", 3)}
        self.gh = gh or GitHub(cfg)
        self.lima = lima or Lima(cfg)
        self.state = state or State()
        self.getloadavg = getloadavg
        self.getmemoryfree = getmemoryfree
        self.load_gated = False
        self.mem_gated = False
        self.host_gated = False
        self.lock = threading.Lock()
        self.ruleset_lock = threading.Lock()
        self.last_ruleset_error_log = None
        self.admission_api_failures = deque()
        self.workers = {}
        self.pending = 0
        self.last_proof = time.time()
        self.proof = None
        self.last_sweep = 0.0
        self.tainted = set()
        self.slot_used_cache = {}
        self.slot_fresh = {}
        self.stop_event = threading.Event()
        self.terminate_requested = False

    # -- slots
    def free_slots(self, data, pending):
        used = len(data["slots"]) + pending
        return self.cfg["slots"] - used

    def mode(self):
        return self.state.load().get("mode")

    def minting_allowed(self, data=None):
        data = self.state.load() if data is None else data
        return data.get("mode") in ("on", "draining") and not data.get("rulesetQuarantine")

    def sample_host(self):
        """Sample outside the state lock; serialize hysteresis and transitions."""
        load1 = self.getloadavg()[0]
        memory_error = None
        try:
            free = self.getmemoryfree()
        except (OSError, subprocess.SubprocessError, ValueError) as err:
            free = None
            memory_error = err

        def sample(data):
            high, low = self.cfg["loadHigh"], self.cfg["loadLow"]
            self.load_gated = load_gate(data.get("loadGated", False), load1, high, low)
            readable = data.get("memSampled", data.get("memFreePercent") is not None)
            since = data.get("memUnreadableSince")
            if free is None:
                first_failure = since is None
                if first_failure:
                    since = time.time()
                if readable and time.time() - since < self.cfg["memHoldSeconds"]:
                    self.mem_gated = data.get("memGated", False)
                    if first_failure:
                        log(f"memory_pressure unreadable ({memory_error}); holding memory gate {'ON' if self.mem_gated else 'OFF'}")
                else:
                    self.mem_gated = False
                    if first_failure or readable:
                        log(f"memory_pressure unreadable; memory gate disabled: {memory_error}")
                    readable = False
            else:
                if since is not None:
                    log("memory_pressure readable again; memory gate re-enabled")
                since = None
                readable = True
                self.mem_gated = memory_gate(data.get("memGated", False), free,
                                             self.cfg["memFreeHigh"], self.cfg["memFreeLow"])
            reason = "+".join(name for name, gated in (("load", self.load_gated), ("memory", self.mem_gated)) if gated)
            previous = data.get("hostGateReason", "load" if data.get("loadGated") else "")
            if reason != previous:
                memory = f"{free}%" if free is not None else "unknown"
                detail = f"1-min load {load1}, memory free {memory}"
                log(f"host gate ON ({reason}): {detail}; not taking new jobs" if reason else f"host gate OFF: {detail}")
            self.host_gated = bool(reason)
            data.update(loadGated=self.load_gated, load1=load1, memGated=self.mem_gated, memFreePercent=free, memSampled=readable,
                        memUnreadableSince=since,
                        hostGated=self.host_gated, hostGateReason=reason)
        return self.state.update(sample)

    def pause(self, reason, *, reject_exact_window=False, history_versions=None):
        """A failed protection check: refuse availability, stop minting and
        cancel queued mbp2606 runs so nothing waits on a pool that is off."""
        log(f"PAUSE: {reason}")

        def clear(data):
            write_busy_file(self.cfg, data)
            try:
                self.gh.clear()
            except BuilderError as err:
                log(f"clear availability failed: {err}")
        def paused(data):
            baseline = data.get("rulesetExact")
            cutoff = baseline["at"] if baseline else None
            if history_versions is not None and baseline:
                cutoff = self.history_window_start(baseline, history_versions)
                quarantine = data.get("rulesetQuarantine")
                if quarantine:
                    quarantine["cutoff"] = min(quarantine["cutoff"], cutoff)
            if (reject_exact_window or history_versions is not None) and baseline and not data.get("rulesetQuarantine"):
                data.setdefault("rulesetRejectedWindows", []).append({
                    "since": cutoff, "until": time.time(),
                })
            reject_quarantine_window(data)
            if data.get("mode") not in ("stopping", "off"):
                data.update(mode="paused", alert=f"{now_utc().isoformat()} {reason}")
        self.state.update(paused, then=clear)
        try:
            cancelled = cancel_label_runs(self.gh, self.cfg, statuses=("queued",))
            if cancelled:
                log(f"cancelled queued mbp2606 run(s): {', '.join(map(str, cancelled))}")
        except BuilderError as err:
            log(f"cancel after pause failed: {err}")

    def expire_quarantine(self):
        quarantine = self.state.load().get("rulesetQuarantine")
        if quarantine and time.time() - quarantine["since"] >= self.cfg["rulesetQuarantineGraceSeconds"]:
            self.pause("main ruleset quarantine grace expired")
            return True
        return False

    def log_ruleset_drift(self, live):
        try:  # a diagnostic must never undo or skip the protection transition
            detail = ruleset_drift(live, self.cfg["ruleset"]["expected"])
            log("ruleset drift detail: " + detail.encode("ascii", "backslashreplace").decode("ascii"))
        except Exception:  # noqa: BLE001
            pass

    def check_ruleset(self, force=True):
        """Fresh reads before mint/publish, without a confirmation sleep. While
        quarantined only one observation per normal publisher cadence counts.
        Ordinary contention waits rather than throwing away a booted worker."""
        if not self.cfg["rulesetQuarantineEnable"]:
            # Main's content-only policy: a read failure skips this operation,
            # while a confirmed mismatch pauses. History is never consulted.
            try:
                live = self.gh.ruleset()
                problems = ruleset_problems(live, self.cfg["ruleset"]["expected"])
            except (BuilderError, ValueError, TypeError, AttributeError) as err:
                log(f"main ruleset unreadable; skipping check: {err}")
                return False
            if problems:
                self.log_ruleset_drift(live)
                self.pause("main ruleset changed: " + "; ".join(problems))
            return not problems
        if self.state.load().get("rulesetQuarantine"):
            # The persisted cadence reservation serializes quarantine reads,
            # including reads made by another controller instance.
            return self._check_ruleset()
        if not self.ruleset_lock.acquire(timeout=35):
            log("main ruleset check timed out waiting for an in-flight check")
            return False
        try:
            return self._check_ruleset()
        finally:
            self.ruleset_lock.release()

    def _check_ruleset(self):
        data = self.state.load()
        quarantine = data.get("rulesetQuarantine")
        if data.get("mode") not in ("on", "draining"):
            return False
        if self.expire_quarantine():
            return False
        started = time.time()
        entering = False
        if quarantine:
            cadence = min(5, self.cfg.get("pollSeconds", 5))
            checked = []

            def claim_observation(current):
                q = current.get("rulesetQuarantine")
                if q and current.get("mode") in ("on", "draining") and started - q["checkedAt"] >= cadence:
                    q["checkedAt"] = started
                    checked.append(q.copy())
            self.state.update(claim_observation)
            if not checked:
                return False
            quarantine = checked[0]

        # History must precede content: a change during the content read must
        # remain visible to the next check, never be absorbed into its baseline.
        history_error = None
        try:
            versions = self.read_ruleset_versions()
        except (BuilderError, ValueError, TypeError, AttributeError) as err:
            history_error = err
        try:
            live = self.gh.ruleset()
            problems = ruleset_problems(live, self.cfg["ruleset"]["expected"])
        except (BuilderError, ValueError, TypeError, AttributeError) as err:
            return self.ruleset_read_failed(err)

        if problems and not quarantine:
            # The shared interlock is saved BEFORE the history request or drift
            # diagnostic. JIT responses re-check this same State lock.
            baseline = data.get("rulesetExact")
            if not baseline:
                self.pause("main ruleset changed: " + "; ".join(problems))
                self.log_ruleset_drift(live)
                return False
            limited = []
            entered = []

            def enter(current):
                if not self.minting_allowed(current):
                    return
                history = [at for at in current.get("rulesetQuarantineEntries", []) if started - at < 86400]
                current["rulesetQuarantineEntries"] = history
                if len(history) >= self.cfg["rulesetQuarantineMaxPerDay"]:
                    limited.append(True)
                    return
                current["rulesetQuarantine"] = {
                    "since": time.time(), "checkedAt": started, "cleanReads": 0,
                    "versions": baseline["versions"], "cutoff": baseline["at"], "confirmed": False,
                }
                entered.append(True)

            def clear(current):
                if current.get("rulesetQuarantine"):
                    try:
                        self.gh.clear()
                    except BuilderError as err:
                        log(f"clear quarantine availability failed (lease expires in 30 s): {err}")
            data = self.state.update(enter, then=clear)
            if limited:
                self.pause("main ruleset quarantine limit reached (24 h)", reject_exact_window=True)
                self.log_ruleset_drift(live)
                return False
            quarantine = data.get("rulesetQuarantine")
            if not quarantine or not entered:
                return False
            entering = True
            # A lagging second history read must never erase a change already
            # observed before the content mismatch closed the interlock.
            if history_error is None and set(versions) - set(quarantine["versions"]):
                self.pause(f"main ruleset history changed: {quarantine['versions']} -> {sorted(versions)}",
                           history_versions=versions)
                self.log_ruleset_drift(live)
                return False
            # The entry decision uses a fresh independent signal AFTER the
            # mismatch has closed the shared interlock, including on read error.
            try:
                versions = self.read_ruleset_versions()
                history_error = None
            except (BuilderError, ValueError, TypeError, AttributeError) as err:
                history_error = err

        if problems:
            self.log_ruleset_drift(live)

        if history_error:
            if quarantine:
                return self.ruleset_read_failed(history_error, entry=entering)
            self.log_ruleset_read_error(f"main ruleset history unreadable on exact read; keeping baseline: {history_error}")
            return self.minting_allowed()

        if quarantine:
            if set(versions) - set(quarantine["versions"]):
                self.pause(f"main ruleset history changed: {quarantine['versions']} -> {sorted(versions)}",
                           history_versions=versions)
                return False
            if self.expire_quarantine():
                return False
            recovered = []

            def observe(current):
                q = current.get("rulesetQuarantine")
                if not q or q["since"] != quarantine["since"] or q["checkedAt"] != started \
                        or current.get("mode") not in ("on", "draining"):
                    return
                if not q["confirmed"]:
                    current.setdefault("rulesetQuarantineEntries", []).append(q["since"])
                    q["confirmed"] = True
                q["cleanReads"] = 0 if problems else q["cleanReads"] + 1
                if q["cleanReads"] >= self.cfg["rulesetQuarantineCleanReads"]:
                    # Keep closed intervals permanently, including across restarts:
                    # delayed/retried jobs from this uncertain window stay denied.
                    reject_quarantine_window(current)
                    baseline = current["rulesetExact"]
                    current["rulesetExact"] = {
                        "versions": sorted(set(q["versions"]) | set(versions)), "at": int(started),
                        "since": baseline.get("since", baseline["at"]),
                    }
                    recovered.append(True)
            self.state.update(observe)
            if recovered:
                log("main ruleset quarantine recovered; rejecting runs from the uncertain window")
                self.cancel_weak_window_runs()
            return bool(recovered)

        # Use the start of this exact read at the API's created_at precision;
        # never subtract an arbitrary safety margin from the observed boundary.
        # An unchanged history may lag, so preserve its creation time separately
        # and widen history-change windows using the new versions' timestamps.
        changed = []

        def exact(current):
            if not self.minting_allowed(current):
                return
            baseline = current.get("rulesetExact")
            if baseline and set(versions) - set(baseline["versions"]):
                changed.append(True)
                return
            current["rulesetExact"] = {
                "versions": sorted(set(baseline["versions"] if baseline else []) | set(versions)),
                "at": int(started),
                "since": baseline.get("since", baseline["at"]) if baseline else int(started),
            }
        self.state.update(exact)
        if changed:
            self.pause("main ruleset history changed between exact reads", history_versions=versions)
            return False
        return self.minting_allowed()

    def read_ruleset_versions(self):
        versions = self.gh.ruleset_versions()
        if not isinstance(versions, dict) or not versions \
                or any(type(version) is not int or version < 1 for version in versions):
            raise BuilderError("ruleset history has no usable version ids")
        return versions

    def history_window_start(self, baseline, versions):
        """Late history can only widen a rejection, never move its start on.
        Any unreadable new timestamp falls back to the baseline's creation."""
        cutoff = baseline["at"]
        for version in set(versions) - set(baseline["versions"]):
            try:
                updated = dt.datetime.fromisoformat(versions[version].replace("Z", "+00:00"))
                if updated.tzinfo is None:
                    raise ValueError("updated_at has no timezone")
                cutoff = min(cutoff, updated.timestamp())
            except (ValueError, TypeError, AttributeError, OverflowError):
                cutoff = min(cutoff, baseline.get("since", baseline["at"]))
        return cutoff

    def log_ruleset_read_error(self, message):
        """Keep persistent read failures visible without logging every poll."""
        now = time.time()
        if self.last_ruleset_error_log is None or now - self.last_ruleset_error_log >= 60:
            self.last_ruleset_error_log = now
            log(message)

    def ruleset_read_failed(self, err, entry=False):
        quarantine = self.state.load().get("rulesetQuarantine")
        if quarantine and entry:
            self.pause(f"main ruleset history unreadable after mismatch: {err}")
        elif quarantine:
            self.state.update(lambda d: d["rulesetQuarantine"].update(cleanReads=0)
                              if d.get("rulesetQuarantine") else None)
            if not self.expire_quarantine():
                self.log_ruleset_read_error(f"main ruleset quarantine read not clean: {err}")
        else:
            self.log_ruleset_read_error(f"main ruleset unreadable; skipping check: {err}")
        return False

    def weak_window_reason(self, run, data=None):
        data = self.state.load() if data is None else data
        windows = data.get("rulesetRejectedWindows", [])
        if not windows:
            return None
        try:
            created = dt.datetime.fromisoformat(run["created_at"].replace("Z", "+00:00"))
            if created.tzinfo is None:
                raise ValueError("created_at has no timezone")
            at = created.timestamp()
        except (KeyError, ValueError, TypeError, AttributeError):
            return "created_at unreadable after ruleset quarantine"
        if any(window["since"] <= at <= window["until"] for window in windows):
            return "created_at falls in a ruleset quarantine window"
        return None

    def cancel_rejected_run(self, run_id, reason):
        """Reserve one attempt under the interlock; never hold it across a POST.
        Failed attempts stay recorded, as on main, rather than retrying per tick."""
        attempted = []

        def reserve(data):
            if not self.minting_allowed(data) or run_id in data["cancelledRuns"]:
                return
            data["cancelledRuns"].append(run_id)
            attempted.append(True)
        self.state.update(reserve)
        if not attempted:
            return
        log(f"reject run {run_id}: {reason}; cancelling")
        try:
            self.gh.cancel(run_id)
        except BuilderError as err:
            log(f"cancel {run_id} failed: {err}")
        with self.state.locked():
            if not self.minting_allowed(self.state.load()):
                log(f"cancel {run_id} was already in flight when the pool stopped minting")

    def cancel_weak_window_runs(self):
        for run in self.gh.active_runs():
            if not self.minting_allowed():
                return
            reason = self.weak_window_reason(run)
            if reason and any(j.get("status") == "queued" and could_take(j, pool_labels(self.cfg))
                              for j in self.gh.jobs(run["id"])):
                self.cancel_rejected_run(run["id"], reason)

    def tick(self):
        self.sample_host()
        self.reap_finished_workers()
        mode = self.mode()
        if mode not in ("on", "draining"):
            return mode
        if self.state.load().get("rulesetQuarantine"):
            candidates = self.queued_pool_jobs() if mode == "draining" else []
            def drained(current):
                if mode == "draining" and current.get("mode") == "draining" and current.get("rulesetQuarantine") \
                        and not candidates and not current["slots"] and not self.workers:
                    stop_pool(current)
            data = self.state.update(drained, then=lambda d: write_busy_file(self.cfg, d))
            if data.get("mode") == "off":
                log("drained during ruleset quarantine; pool is off")
                return "off"
            self.expire_quarantine()
            return self.mode()
        candidates = self.queued_pool_jobs()
        pending = 0
        attempted = False
        for run, job in candidates:
            data = self.state.load()
            if not self.minting_allowed():
                break
            assigned = {s["jobId"] for s in data["slots"].values()}
            if job["id"] in assigned or job["id"] in self.workers:
                continue
            if run["id"] in data["cancelledRuns"]:
                continue
            reason = self.weak_window_reason(run, data)
            if reason:
                self.cancel_rejected_run(run["id"], reason)
                continue
            ok, reason = (True, "ok") if run["id"] in data["verifiedRuns"] else verify_run(run, self.cfg, self.gh.sha_on_branch)
            if not ok:
                self.cancel_rejected_run(run["id"], reason)
                continue
            if run["id"] not in data["verifiedRuns"]:
                self.state.update(lambda d, r=run["id"]: d["verifiedRuns"].append(r))
            if not class_ok(job, run, self.cfg):
                self.cancel_rejected_run(run["id"],
                                         f"job {job['id']} labels {job.get('labels')} lack exact class {expected_class(run, self.cfg)}")
                continue
            if attempted:
                pending += 1
                continue
            attempted = True
            slot = self.claim_slot(job, run)
            if slot is None:
                pending += 1
                continue
            thread = threading.Thread(target=self.serve, args=(slot, run, job), daemon=True)
            self.workers[job["id"]] = thread
            thread.start()
        self.pending = pending
        if not self.host_gated:
            self.maybe_prove()
        if time.time() - self.last_sweep > 60:
            self.last_sweep = time.time()
            self.sweep_stale_runners()
        data = self.state.load()
        if data.get("mode") == "draining" and not data.get("rulesetQuarantine") and not candidates and not data["slots"] and not self.workers:
            self.state.update(lambda d: stop_pool(d) if d.get("mode") == "draining" and not d.get("rulesetQuarantine") else None,
                              then=lambda d: write_busy_file(self.cfg, d))
            log("drained; pool is off")
            return "off"
        for key in ("verifiedRuns", "cancelledRuns"):
            if len(data[key]) > 500:
                self.state.update(lambda d, k=key: d.__setitem__(k, d[k][-300:]))
        return self.mode()

    def queued_pool_jobs(self):
        return [(run, job) for run in self.gh.active_runs() for job in self.gh.jobs(run["id"])
                if job.get("status") == "queued" and wants_label(job, self.cfg["label"])]

    def maybe_prove(self):
        """Re-prove the network block in the background while the pool idles;
        a proof never delays availability renewal."""
        if self.proof and self.proof.is_alive():
            return
        data = self.state.load()
        if data.get("mode") != "on" or data.get("hostGated") or not self.cfg["requireNetworkBlock"] or data["slots"] \
                or time.time() - self.last_proof < self.cfg["proofMinutes"] * 60:
            return
        self.last_proof = time.time()

        def prove():
            ok, detail = prove_network_block(self.cfg, self.lima)
            if ok:
                self.state.update(lambda d: d.update(networkProof=now_utc().isoformat()))
            else:
                self.pause(f"network block proof failed: {detail}")
        self.proof = threading.Thread(target=prove, daemon=True)
        self.proof.start()

    def publisher(self):
        """Refresh AEON_MBP2606_AVAILABILITY every few seconds, independent of
        the tick's API and VM work, each time after a fresh ruleset check."""
        interval = min(5, self.cfg["pollSeconds"])
        while not self.stop_event.wait(interval):
            try:
                self.publish_once()
            except Exception as err:  # noqa: BLE001 - an expired record falls back to hosted
                log(f"publish failed: {err}")

    def publish_once(self):
        """The mode check and the remote write happen under the state lock, the
        same lock pause() and `off` hold while clearing: a publish can never
        land after a clear."""
        self.sample_host()
        data = self.state.load()
        if (data.get("mode") == "on" or (data.get("mode") == "draining" and data.get("rulesetQuarantine"))) and not self.check_ruleset():
            return False
        published = []

        def publish(data):
            write_busy_file(self.cfg, data)
            if data.get("mode") == "on" and self.minting_allowed(data):
                free = 0 if data.get("hostGated") else self.free_slots(data, self.pending)
                self.gh.publish(availability_record(self.cfg, free))
                published.append(True)
        self.state.update(lambda d: None, then=publish)
        return bool(published)

    def sweep_stale_runners(self):
        """Registrations whose VM is gone (e.g. a denied job GitHub still counts
        as running) are deleted once GitHub lets go of them."""
        try:
            for runner in self.gh.runners():
                live = {s.get("runner") for s in self.state.load()["slots"].values()}
                if runner["name"].startswith("mbp2606-") and runner["name"] not in live and runner.get("status") == "offline":
                    try:
                        self.gh.delete_runner(runner["id"])
                        log(f"deleted stale runner registration {runner['name']}")
                    except BuilderError:
                        pass
        except BuilderError as err:
            log(f"runner sweep failed: {err}")

    def retire_slot(self, slot, vm, disk):
        """Release a slot only when its VM is provably gone and its disk is
        settled. Otherwise it stays occupied as `stuck` (the pool pauses): a
        surviving VM must never get its disk restored or its slot reused."""
        if not self.lima.delete(vm):
            self.set_slot(slot, phase="stuck")
            self.pause(f"slot {slot}: {vm} could not be deleted; slot held until an operator cleans it")
            return False
        try:
            self.finish_disk(slot, disk)
        except Exception as err:  # noqa: BLE001
            self.set_slot(slot, phase="stuck")
            self.pause(f"slot {slot}: cache disk could not be settled ({err}); slot held")
            return False
        self.release_slot(slot)
        return True

    def reap_finished_workers(self):
        for job_id, thread in list(self.workers.items()):
            if not thread.is_alive():
                del self.workers[job_id]

    def reconcile(self):
        """A controller that died (SIGKILL, crash, reboot) leaves slots, VMs and
        registrations behind. Clean them before serving: the slot disks count as
        tainted because nobody watched them."""
        data = self.state.load()
        for slot_key, info in list(data["slots"].items()):
            slot = int(slot_key)
            log(f"reconcile: slot {slot} was left {info.get('phase')} (run {info.get('runId')}); cleaning up")
            if (info.get("disk") or "").startswith("aeon-cache-"):
                self.tainted.add(slot)
            if not self.retire_slot(slot, f"aeon-job-{slot}", info.get("disk")):
                continue
            if info.get("runnerId"):
                try:
                    self.gh.delete_runner(info["runnerId"])
                except BuilderError as err:
                    log(f"reconcile: runner {info.get('runner')} deferred to the sweep: {err}")
        held = {f"aeon-job-{k}" for k in self.state.load()["slots"]}
        for name in self.lima.instances():
            if (name.startswith("aeon-job-") and name not in held) or name == "aeon-probe":
                self.lima.delete(name)

    def claim_slot(self, job, run):
        if not self.minting_allowed():
            return None
        if not self.check_ruleset():
            return None
        claimed = []

        def claim(data):
            if not self.minting_allowed(data) or data.get("hostGated") or self.weak_window_reason(run, data):
                return
            now = time.time()
            last = data.get("lastClaimAt")
            if last is not None and 0 <= now - last < self.cfg["claimSpacingSeconds"]:
                return
            for slot in range(self.cfg["slots"]):
                if str(slot) not in data["slots"]:
                    data["slots"][str(slot)] = {
                        "jobId": job["id"], "runId": run["id"], "attempt": run.get("run_attempt"), "event": run["event"],
                        "since": now_utc().isoformat(), "phase": "cloning",
                    }
                    data["lastClaimAt"] = now
                    claimed.append(slot)
                    return
        self.state.update(claim)
        return claimed[0] if claimed else None

    def set_slot(self, slot, **fields):
        self.state.update(lambda d: d["slots"].get(str(slot), {}).update(fields))

    def release_slot(self, slot):
        self.state.update(lambda d: d["slots"].pop(str(slot), None))

    def mint_runner(self, slot, run, name, labels, checked_windows):
        """Check both sides of the POST without holding up quarantine entry.
        A response spanning a quarantine is discarded and its runner retired."""
        with self.state.locked():
            data = self.state.load()
            if not self.minting_allowed(data) or self.weak_window_reason(run, data) \
                    or len(data.get("rulesetRejectedWindows", [])) != checked_windows:
                return None
            info = data["slots"].get(str(slot))
            if info is None:
                return None
            info.update(phase="minting", runner=name)
            self.state.save(data)
            entries = list(data.get("rulesetQuarantineEntries", []))
        jit = self.gh.jit(name, labels)
        with self.state.locked():
            data = self.state.load()
            info = data["slots"].get(str(slot))
            allowed = info is not None and self.minting_allowed(data) and not self.weak_window_reason(run, data) \
                and len(data.get("rulesetRejectedWindows", [])) == checked_windows \
                and data.get("rulesetQuarantineEntries", []) == entries
            if allowed:
                info.update(phase="waiting", runnerId=jit["runner"]["id"])
                self.state.save(data)
                return jit
        try:
            self.gh.delete_runner(jit["runner"]["id"])
        except BuilderError as err:
            log(f"discarded JIT runner cleanup deferred to the sweep: {err}")
        return None

    # -- one job VM
    def serve(self, slot, run, job):
        vm = f"aeon-job-{slot}"
        runner_id = None
        disk = None
        self.slot_used_cache[slot] = False
        try:
            disk, fresh = self.prepare_disk(slot, run)
            self.slot_fresh[slot] = fresh
            self.lima.delete(vm)
            self.lima.run("clone", "--tty=false", BASE_VM, vm, "--set", clone_expression(self.cfg, slot, disk, fresh))
            self.lima.run("start", "--tty=false", vm)
            self.set_slot(slot, phase="probing", vm=vm, disk=disk)
            if self.cfg["requireNetworkBlock"]:
                probe = self.lima.run("shell", "--workdir", "/", vm, "--", "bash", "-c", PROBE, "probe",
                                      *host_probe_targets(self.cfg), check=False)
                if probe.returncode != 0:
                    self.pause(f"network block check failed in {vm}: {probe.stdout.strip() or probe.stderr.strip()[-200:]}")
                    return
            if not self.minting_allowed() or not self.check_ruleset(force=True):
                return
            checked_windows = len(self.state.load().get("rulesetRejectedWindows", []))
            labels = mint_labels(self.cfg, run)
            if self.unverified_label_runs(labels):
                log(f"slot {slot}: unverified mbp2606 jobs were queued; cancelled them, not minting this tick")
                return
            current = self.gh.job(job["id"])
            if current.get("status") != "queued":
                log(f"job {job['id']} no longer queued ({current.get('status')}); not minting")
                return
            if not self.minting_allowed():
                return
            name = f"mbp2606-s{slot}-{job['id']}-{secrets.token_hex(3)}"
            jit = self.mint_runner(slot, run, name, labels, checked_windows)
            if jit is None:
                return
            runner_id = jit["runner"]["id"]
            log(f"slot {slot}: runner {name} for run {run['id']} attempt {run.get('run_attempt')} job {job['id']} ({run['event']}, disk {disk})")
            if not self.minting_allowed():
                return
            self.lima.run("shell", "--workdir", "/", vm, "--", "sudo", "/opt/aeon/start-runner", input=jit["encoded_jit_config"])
            outcome = self.wait_for_runner(slot, vm, name, job)
            if outcome == "ran":
                if not self.post_job_check(slot, vm, name, job):
                    self.tainted.add(slot)
            elif outcome in ("denied", "unverified", "unattributed", "api-unavailable"):
                self.tainted.add(slot)
            elif outcome == "class-mismatch":
                log(f"slot {slot}: VM stopped before unlocking; the job it took fails and needs a rerun")
            if slot not in self.tainted:
                self.lima.run("shell", "--workdir", "/", vm, "--", "sudo", "/opt/aeon/cache-lock", "lock", check=False)
        except Exception as err:  # noqa: BLE001 - one slot must never kill the pool
            log(f"slot {slot}: {err}")
            self.tainted.add(slot)
        finally:
            # Local cleanup first and unconditionally; GitHub last (a stale
            # registration is swept later, a leaked VM is not).
            self.retire_slot(slot, vm, disk)
            if runner_id:
                try:
                    self.gh.delete_runner(runner_id)
                except BuilderError as err:
                    log(f"slot {slot}: runner cleanup deferred to the sweep: {err}")

    def unverified_label_runs(self, labels):
        """Before every mint of a runner with `labels`: every queued job that
        could take it (its runs-on a subset) must be a class-correct job of a
        verified run. Cancel the runs of all others, whatever their event or ref,
        and report whether any existed (the caller then does not mint)."""
        data = self.state.load()
        found = []
        for run in self.gh.active_runs():
            if not self.minting_allowed():
                break
            if run["id"] in found:
                continue
            takers = [j for j in self.gh.jobs(run["id"]) if j.get("status") == "queued" and could_take(j, labels)]
            if not takers:
                continue
            if run["id"] in data["cancelledRuns"]:
                found.append(run["id"])
                # The tick reserves only one attempt, but a failed cancel must
                # be retried before another mint, once per run in this sweep.
                if self.minting_allowed():
                    try:
                        self.gh.cancel(run["id"])
                    except BuilderError as err:
                        log(f"cancel {run['id']} failed: {err}")
                continue
            reason = self.weak_window_reason(run)
            if reason:
                self.cancel_rejected_run(run["id"], reason)
                found.append(run["id"])
                continue
            if run["id"] in data["verifiedRuns"]:
                ok, reason = True, "ok"
            else:
                ok, reason = verify_run(run, self.cfg, self.gh.sha_on_branch)
                if ok:
                    self.state.update(lambda d, r=run["id"]: d["verifiedRuns"].append(r))
            if ok and all(class_ok(j, run, self.cfg) for j in takers):
                continue
            if ok:
                reason = "a queued job lacks its exact class label"
            self.cancel_rejected_run(run["id"], reason)
            found.append(run["id"])
        return found

    # -- cache disks: trusted slot disk for verified pushes, throwaway clone otherwise
    def disk_file(self, name):
        return HOME / ".lima/_disks" / name / "datadisk"

    def good_copy(self, slot):
        return STATE_DIR / "good" / f"aeon-cache-{slot}.datadisk"

    def slot_key(self, slot):
        path = CONFIG_DIR / "cache-keys" / f"slot-{slot}"
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            atomic_write(path, secrets.token_hex(64))
        return path.read_text().strip()

    def prepare_disk(self, slot, run):
        """Returns (disk name, fresh). Only a disk created right here is fresh:
        Lima repartitions a `format: true` disk on every boot (its label probe
        races udev), so an existing disk is always attached with format false."""
        cache = f"aeon-cache-{slot}"
        good = self.good_copy(slot)
        if uses_cache_disk(run, self.cfg):
            if cache in self.lima.disks():
                return cache, False
            self.lima.run("disk", "create", cache, "--size", f"{self.cfg['cacheDiskGiB']}GiB", "--format", "raw")
            if good.exists():
                subprocess.run(["/bin/cp", "-c", str(good), str(self.disk_file(cache))], check=True)
                return cache, False
            return cache, True
        # Non-push jobs read the last known-good cache, write only a disposable clone.
        scratch = f"aeon-scratch-{slot}"
        self.drop_scratch(slot)
        self.lima.run("disk", "create", scratch, "--size", f"{self.cfg['cacheDiskGiB']}GiB", "--format", "raw")
        if good.exists():
            subprocess.run(["/bin/cp", "-c", str(good), str(self.disk_file(scratch))], check=True)
            return scratch, False
        return scratch, True

    def finish_disk(self, slot, disk):
        """Keep a known-good APFS clone after a clean verified push; restore it
        after any deny, pause or mismatch (the unlocked cache was root-readable)."""
        if not disk or disk.startswith("aeon-scratch-"):
            # The trusted disk was never attached: nothing to snapshot or restore.
            self.drop_scratch(slot)
            self.slot_used_cache.pop(slot, None)
            self.tainted.discard(slot)
            return
        good = self.good_copy(slot)
        if slot in self.tainted:
            log(f"slot {slot}: cache disk tainted; restoring the last known-good copy")
            if good.exists():
                subprocess.run(["/bin/cp", "-c", str(good), str(self.disk_file(disk))], check=True)
            else:
                self.lima.delete_disk(disk)  # raises: retire_slot then holds the slot
            self.tainted.discard(slot)
            return
        if self.slot_used_cache.pop(slot, False):
            good.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            tmp = good.with_suffix(".tmp")
            tmp.unlink(missing_ok=True)
            subprocess.run(["/bin/cp", "-c", str(self.disk_file(disk)), str(tmp)], check=True)
            os.replace(tmp, good)

    def drop_scratch(self, slot):
        scratch = f"aeon-scratch-{slot}"
        if scratch in self.lima.disks():
            self.lima.delete_disk(scratch)

    # -- the job's lifetime
    def vm_running(self, vm):
        return (self.lima.instances().get(vm) or {}).get("status") == "Running"

    def wait_for_runner(self, slot, vm, name, job):
        """Returns ran | idle | denied | unverified | unattributed | api-unavailable |
        class-mismatch | timeout | stopped."""
        deadline = time.time() + self.cfg["maxJobMinutes"] * 60
        idle_since = None
        unlocked = False
        while time.time() < deadline:
            if self.mode() == "stopping":
                log(f"slot {slot}: hard stop")
                return "stopped"
            if not self.vm_running(vm):
                self.pause(f"slot {slot}: {vm} powered off during a job (the hook denies by powering off)")
                return "denied"
            if self.lima.shell(vm, "grep -q '^aeon-hook deny' /var/lib/aeon/hook.log", check=False).returncode == 0:
                self.pause(f"slot {slot}: the job-started hook denied a job on {name}")
                return "denied"
            active = self.lima.shell(vm, "systemctl is-active aeon-runner", check=False).stdout.strip()
            admitted = self.lima.shell(vm, "test -e /var/lib/aeon/admitted", check=False).returncode == 0
            if admitted and not unlocked:
                verdict = self.admit(slot, vm, name, job)
                if verdict != "ok":
                    return verdict
                unlocked = True
            if active != "active":
                return "ran" if admitted else "idle"
            if not admitted:
                try:
                    current = self.gh.job(job["id"])
                except TransientGitHubError as err:
                    log(f"slot {slot}: transient GitHub error polling job {job['id']}: {err}")
                else:
                    if current.get("status") != "queued":
                        idle_since = idle_since or time.time()
                        if time.time() - idle_since > 60:
                            log(f"slot {slot}: job {job['id']} went elsewhere ({current.get('status')}); retiring idle runner")
                            return "idle"
            time.sleep(3)
        log(f"slot {slot}: job exceeded {self.cfg['maxJobMinutes']} min; stopping VM")
        return "timeout"

    def record_admission_api_unavailable(self):
        """Keep a bounded, thread-safe history for this controller's lifetime.
        Isolated outages retire only their VM; repeated outages pause the pool."""
        with self.lock:
            now = time.monotonic()
            self.admission_api_failures.append(now)
            while self.admission_api_failures and now - self.admission_api_failures[0] > ADMISSION_API_UNAVAILABLE_WINDOW_SECONDS:
                self.admission_api_failures.popleft()
            trip = len(self.admission_api_failures) >= ADMISSION_API_UNAVAILABLE_LIMIT
            if trip:
                self.admission_api_failures.clear()
        if trip:
            minutes = ADMISSION_API_UNAVAILABLE_WINDOW_SECONDS // 60
            self.pause(f"GitHub API unavailable during admission x{ADMISSION_API_UNAVAILABLE_LIMIT} in {minutes} min")

    def admit(self, slot, vm, name, job):
        """The hook admitted a job; confirm through the API which job this runner
        took, then hand the cache key over. Anything else kills the VM. API-only
        exhaustion or verified admission timeouts leave the pool on until the circuit breaker trips;
        a successful attribution read with no matching job still pauses it."""
        deadline = time.monotonic() + ADMISSION_WAIT_SECONDS
        ran = None
        metadata = None
        attempt = 0
        answered_unattributed = False
        last_error = None
        while time.monotonic() < deadline and attempt < 10:
            if self.mode() == "stopping":
                return "stopped"
            attempt += 1
            try:
                if ran is None:
                    ran = self.find_runner_job(name, job)
                    last_error = None
                    answered_unattributed = ran is None
                if self.mode() == "stopping":
                    return "stopped"
                if ran:
                    verified = set(self.state.load()["verifiedRuns"])
                    if ran.get("run_id") not in verified:
                        self.pause(f"slot {slot}: {name} took job {ran.get('id')} of unverified run {ran.get('run_id')} attempt {ran.get('run_attempt')}")
                        return "unverified"
                if time.monotonic() >= deadline:
                    break
                if ran:
                    metadata = self.gh.run(ran["run_id"])
                    last_error = None
                    break
            except TransientGitHubError as err:
                last_error = str(err)
                log(f"slot {slot}: transient GitHub error admitting {name}: {err}")
            if self.mode() == "stopping":
                return "stopped"
            remaining = deadline - time.monotonic()
            if attempt < 10 and remaining > 0:
                time.sleep(min(2, remaining))
        if self.mode() == "stopping":
            return "stopped"
        expired = time.monotonic() >= deadline
        if ran is None or metadata is None or expired:
            if ran is not None and expired:
                log(f"slot {slot}: {name} attributed to verified job {ran.get('id')} but admission window expired; retiring VM without unlocking cache")
                self.record_admission_api_unavailable()
                return "api-unavailable"
            if last_error is not None and not answered_unattributed:
                log(f"slot {slot}: GitHub API unavailable during admission for {name}; retiring VM without unlocking cache; last error: {last_error}")
                self.record_admission_api_unavailable()
                return "api-unavailable"
            self.pause(f"slot {slot}: hook admitted a job the API cannot attribute to {name}")
            return "unattributed"
        disk = self.state.load()["slots"].get(str(slot), {}).get("disk") or ""
        event = metadata.get("event")
        if disk.startswith("aeon-cache-") and event not in self.cfg["cacheWriteEvents"]:
            # The runner was minted for a push but took a verified non-push job.
            # The trusted disk is attached, so never unlock it for this job.
            log(f"slot {slot}: {name} took {event} job {ran.get('id')} but holds the trusted cache disk; stopping the VM unlocked")
            return "class-mismatch"
        self.set_slot(slot, phase="running", ranJob=ran.get("id"), ranRun=ran.get("run_id"), ranAttempt=ran.get("run_attempt"), ranEvent=event)
        size = max(self.cfg["cacheDiskGiB"] - 4, 8)
        init = ["--init"] if self.slot_fresh.get(slot) else []
        self.lima.run("shell", "--workdir", "/", vm, "--", "sudo", "/opt/aeon/cache-lock", "unlock", str(size), *init,
                      input=self.slot_key(slot))
        self.slot_used_cache[slot] = disk.startswith("aeon-cache-")
        log(f"slot {slot}: admitted job {ran.get('id')} run {ran.get('run_id')} attempt {ran.get('run_attempt')}; cache unlocked")
        return "ok"

    def find_runner_job(self, name, job):
        """Which run, attempt and job did this runner actually take? Asked of the
        API, never of the VM: the job had root there and could rewrite its logs."""
        target = self.gh.job(job["id"])
        if target.get("runner_name") == name:
            return target
        data = self.state.load()
        run_ids = list(dict.fromkeys(data["verifiedRuns"][-20:] + [r["id"] for r in self.gh.recent_runs()]))
        for run_id in run_ids:
            for item in self.gh.all_jobs(run_id):
                if item.get("runner_name") == name:
                    return item
        return None

    def post_job_check(self, slot, vm, name, job):
        ran = self.find_runner_job(name, job)
        verified = set(self.state.load()["verifiedRuns"])
        if ran is None:
            self.pause(f"slot {slot}: runner {name} ran a job the API cannot attribute")
            return False
        if ran.get("run_id") not in verified:
            self.pause(f"slot {slot}: runner {name} ran job {ran.get('id')} of unverified run {ran.get('run_id')} (attempt {ran.get('run_attempt')})")
            return False
        log(f"slot {slot}: post-job ok, {name} ran job {ran.get('id')} run {ran.get('run_id')} attempt {ran.get('run_attempt')} ({ran.get('conclusion')})")
        return True

    def run_forever(self):
        lock = acquire_controller_lock()
        if lock is None:
            log("another controller holds the lock; exiting")
            return
        self.state.update(lambda d: d.pop("rulesetExact", None))
        atomic_write(STATE_DIR / "controller.pid", str(os.getpid()))

        def terminate(*_):
            # Only a flag: the handler may interrupt a State update in this
            # thread. The loop turns it into `stopping` (like off --now).
            self.terminate_requested = True
        signal.signal(signal.SIGTERM, terminate)
        log("controller started")
        self.reconcile()
        publisher = threading.Thread(target=self.publisher, daemon=True)
        publisher.start()
        try:
            while True:
                try:
                    mode = self.tick()
                except Exception as err:  # noqa: BLE001 - keep polling through API hiccups
                    log(f"tick failed: {err}")
                    mode = self.mode()
                self.reap_finished_workers()
                if self.terminate_requested:
                    self.state.update(lambda d: stop_pool(d, "stopping") if d.get("mode") in ("on", "draining", "paused") else None,
                                      then=lambda d: write_busy_file(self.cfg, d))
                    mode = self.mode()
                busy = bool(self.workers) or bool(self.proof and self.proof.is_alive())
                if mode in ("off", "paused") and not busy:
                    break
                if mode == "stopping" and not busy:
                    self.state.update(lambda d: stop_pool(d) if d.get("mode") == "stopping" else None,
                                      then=lambda d: write_busy_file(self.cfg, d))
                    break
                time.sleep(self.cfg["pollSeconds"])
        finally:
            self.stop_event.set()
            if self.proof and self.proof.is_alive():
                self.proof.join(timeout=180)
            self.lima.delete("aeon-probe")

            def clear(data):
                write_busy_file(self.cfg, data)
                try:
                    self.gh.clear()
                except BuilderError as err:
                    log(f"clear availability failed: {err}")
            self.state.update(lambda d: None, then=clear)
            (STATE_DIR / "controller.pid").unlink(missing_ok=True)
            log("controller stopped")
            lock.close()


# ---------------------------------------------------------------- commands


def cancel_label_runs(gh, cfg, statuses=("queued", "in_progress")):
    cancelled = []
    for run in gh.active_runs():
        if run["id"] in cancelled:
            continue
        if any(could_take(j, pool_labels(cfg)) and j.get("status") in statuses for j in gh.jobs(run["id"])):
            gh.cancel(run["id"])
            cancelled.append(run["id"])
    return cancelled


def load_config(path):
    return json.loads(Path(path).read_text())


def acquire_controller_lock():
    """One controller per user: an flock held for the controller's lifetime."""
    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    handle = open(STATE_DIR / "controller.lock", "a")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        return None
    return handle


def controller_pid():
    """The running controller's pid, or None. The lock, not the pid file, decides."""
    probe = acquire_controller_lock()
    if probe is not None:
        probe.close()
        return None
    try:
        return int((STATE_DIR / "controller.pid").read_text())
    except (FileNotFoundError, ValueError):
        return -1


def lab_vms(cfg):
    busy = []
    for user in cfg["labGuardUsers"]:
        proc = subprocess.run(["/usr/bin/pgrep", "-u", user, "-f", "limactl hostagent|colima|qemu-system"], capture_output=True, text=True)
        if proc.stdout.strip():
            busy.append(user)
    return busy


def prepare_base(cfg, lima, force=False):
    marker = HOME / ".lima" / BASE_VM / "aeon-base-id"
    if not force and marker.exists() and marker.read_text().strip() == cfg["baseId"]:
        return False
    if controller_pid():
        raise BuilderError("the pool is running; `aeon-builder off` before the base VM can be rebuilt")
    log(f"building base VM {cfg['baseId'][:12]}")
    lima.delete(BASE_VM)
    lima.run("create", "--tty=false", "--name", BASE_VM, "--set", base_expression(cfg), cfg["baseTemplate"])
    lima.run("start", "--tty=false", BASE_VM)
    with tempfile.TemporaryDirectory() as tmp:
        allow = Path(tmp) / "allowlist.json"
        allow.write_text(json.dumps(allowlist_document(cfg), indent=2))
        for src, dst in ((cfg["provisionScript"], "/tmp/provision-base.sh"), (cfg["hookScript"], "/tmp/job-started.sh"),
                         (cfg["startRunnerScript"], "/tmp/start-runner"), (cfg["cacheLockScript"], "/tmp/cache-lock"),
                         (str(allow), "/tmp/allowlist.json")):
            lima.run("copy", src, f"{BASE_VM}:{dst}")
    lima.run("shell", "--workdir", "/", BASE_VM, "--", "sudo", "bash", "/tmp/provision-base.sh",
             cfg["runner"]["version"], cfg["runner"]["sha256"], *cfg["prePullImages"], timeout=1800)
    lima.run("stop", BASE_VM)
    marker.write_text(cfg["baseId"] + "\n")
    log("base VM sealed")
    return True


def cmd_on(cfg, args):
    busy = lab_vms(cfg)
    if busy and not args.force:
        raise BuilderError(f"a lab VM of {', '.join(busy)} is running; stop it first (memory)")
    state = State()
    data = state.load()
    if data.get("mode") == "paused" and not args.resume:
        raise BuilderError(f"paused: {data.get('alert')}\n  investigate, then `aeon-builder on --resume`")
    lima = Lima(cfg)
    prepare_base(cfg, lima)
    gh = GitHub(cfg)
    problems = ruleset_problems(gh.ruleset(), cfg["ruleset"]["expected"])
    if problems:
        raise BuilderError("main ruleset check failed: " + "; ".join(problems))
    if cfg["requireNetworkBlock"]:
        ok, detail = prove_network_block(cfg, lima)
        if not ok:
            raise BuilderError(f"network block missing ({detail}); install it: sudo aeon-builder pf-install")
        state.update(lambda d: d.update(networkProof=now_utc().isoformat()))
    state.update(lambda d: (d.update(mode="on"), d.pop("alert", None), d.pop("rulesetExact", None)),
                 then=lambda d: write_busy_file(cfg, d))
    if controller_pid():
        print("aeon-builder: on (controller already running)")
        return
    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(STATE_DIR / "controller.out", "a") as out:
        subprocess.Popen([sys.executable, os.path.abspath(__file__), "--config", args.config, "controller"],
                         stdin=subprocess.DEVNULL, stdout=out, stderr=out, start_new_session=True)
    for _ in range(20):
        if controller_pid():
            break
        time.sleep(0.25)
    print(f"aeon-builder: on — {cfg['slots']} slots × {cfg['slotCpus']} CPU / {cfg['slotMemoryGiB']} GiB for {cfg['repo']}")


def cmd_off(cfg, args):
    """Local state first, GitHub second: an API outage must never keep the pool
    running. Returns 2 while the pool is still draining, so callers (the
    mbp2606-builder wrapper) do not hand the machine back too early."""
    state = State()
    running = controller_pid()
    try:
        gh = GitHub(cfg)
    except Exception as err:  # noqa: BLE001 - broken credentials must not block a local stop
        print(f"aeon-builder: warning, GitHub App unusable ({err}); stopping locally only", file=sys.stderr)
        gh = None

    def clear(data):
        write_busy_file(cfg, data)
        if gh is None:
            return
        try:
            gh.clear()
        except BuilderError as err:
            print(f"aeon-builder: warning, availability not cleared ({err}); it expires in 30 s", file=sys.stderr)
    if args.now:
        state.update(lambda d: stop_pool(d, "stopping" if running else "off"), then=clear)
    else:
        def drain(data):
            if not running:
                stop_pool(data)
            elif data.get("mode") in ("on", "paused"):
                data.update(mode="draining")
        state.update(drain, then=clear)
    if args.now and gh is not None:
        try:
            cancelled = cancel_label_runs(gh, cfg)
            print(f"aeon-builder: hard stop, cancelled {len(cancelled)} run(s)")
        except BuilderError as err:
            print(f"aeon-builder: warning, cancelling runs failed ({err})", file=sys.stderr)
    else:
        print("aeon-builder: draining — availability cleared, queued mbp2606 jobs are still served")
    deadline = time.time() + args.wait * 60
    while time.time() < deadline and controller_pid():
        data = state.load()
        print(f"  {data.get('mode')}: {len(data['slots'])} job VM(s) busy", flush=True)
        time.sleep(10)
    if controller_pid():
        print("aeon-builder: still draining in the background; `aeon-builder status` shows progress")
        return 2
    lima = Lima(cfg)
    try:
        leftovers = [n for n in lima.instances() if n.startswith("aeon-job-") or n == "aeon-probe"]
        stuck = [n for n in leftovers if not lima.delete(n)]
    except BuilderError as err:
        print(f"aeon-builder: cannot list VMs ({err}); the machine is NOT known to be free", file=sys.stderr)
        return 3
    if stuck:
        print(f"aeon-builder: could not delete {', '.join(stuck)}; the machine is NOT free", file=sys.stderr)
        return 3
    if gh is None:
        state.update(lambda d: stop_pool(d), then=lambda d: write_busy_file(cfg, d))
        print("aeon-builder: off locally — no job VMs; GitHub cleanup skipped")
        return 0
    try:
        for runner in gh.runners():
            if runner["name"].startswith("mbp2606-"):
                try:
                    gh.delete_runner(runner["id"])
                except BuilderError as err:
                    print(f"aeon-builder: runner {runner['name']} not deleted yet ({err})", file=sys.stderr)
    except BuilderError as err:
        print(f"aeon-builder: warning, runner cleanup failed ({err})", file=sys.stderr)
    state.update(lambda d: stop_pool(d), then=lambda d: write_busy_file(cfg, d))
    print("aeon-builder: off — no job VMs")
    return 0


def cmd_status(cfg, args):
    data = State().load()
    pid = controller_pid()
    lima = Lima(cfg)
    vms = lima.instances()
    marker = HOME / ".lima" / BASE_VM / "aeon-base-id"
    base = "missing"
    if BASE_VM in vms:
        base = "ready" if marker.exists() and marker.read_text().strip() == cfg["baseId"] else "outdated (rebuilt on next on)"
    print(f"mode:        {data.get('mode')}{'  ⚠ ' + data['alert'] if data.get('alert') else ''}")
    quarantine = data.get("rulesetQuarantine") if data.get("mode") in ("on", "draining") else None
    count = sum(1 for at in data.get("rulesetQuarantineEntries", []) if time.time() - at < 86400)
    limit = cfg.get("rulesetQuarantineMaxPerDay", 3)
    if quarantine:
        since = dt.datetime.fromtimestamp(quarantine["since"], dt.timezone.utc).isoformat()
        grace = max(0, int(cfg.get("rulesetQuarantineGraceSeconds", 600) - (time.time() - quarantine["since"])))
        print(f"quarantine:  since {since}; clean reads {quarantine['cleanReads']}/{cfg.get('rulesetQuarantineCleanReads', 2)}; grace left {grace} s; count/24 h {count}/{limit}")
    else:
        print(f"quarantine:  inactive; count/24 h {count}/{limit}")
    print(f"controller:  {'pid ' + str(pid) if pid else 'not running'}")
    gate = 'ON' if data.get('loadGated') else 'OFF'
    print(f"load gate:   {gate}  1-min load {data.get('load1', 'unknown')} (last sampled; high {cfg['loadHigh']}, low {cfg['loadLow']})")
    mem_gate = 'ON' if data.get('memGated') else 'OFF'
    free = data.get('memFreePercent')
    memory_status = f"{mem_gate}  free {str(free) + '%' if free is not None else 'unknown'}"
    since = data.get('memUnreadableSince')
    if since is not None:
        iso = dt.datetime.fromtimestamp(since, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        memory_status = f"{mem_gate}  held since {iso}" if data.get('memSampled') else f"disabled (unreadable since {iso})"
    print(f"memory gate: {memory_status} (last sampled; low {cfg.get('memFreeLow', 35)}, high {cfg.get('memFreeHigh', 45)})")
    print(f"host gate:   {'ON (' + data['hostGateReason'] + ')' if data.get('hostGated') else 'OFF'}")
    last = data.get('lastClaimAt')
    print(f"last claim:  {str(max(0, int(time.time() - last))) + ' s ago' if last is not None else 'never'}")
    print(f"base VM:     {base}")
    print(f"net block:   last proven {data.get('networkProof', 'never')[:19]}")
    print(f"slots:       {len(data['slots'])}/{cfg['slots']} busy ({cfg['slotCpus']} CPU / {cfg['slotMemoryGiB']} GiB each)")
    for slot, info in sorted(data["slots"].items()):
        print(f"  slot {slot}: {info.get('phase')} run {info.get('runId')} job {info.get('jobId')} {info.get('event')} since {info.get('since', '')[:19]}")
    load = subprocess.run(["/usr/sbin/sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout.strip()
    pressure = subprocess.run(["/usr/bin/memory_pressure", "-Q"], capture_output=True, text=True).stdout.strip().splitlines()
    print(f"host:        load {load}  {pressure[-1] if pressure else ''}")
    lab = lab_vms(cfg)
    if lab:
        print(f"lab VMs:     running for {', '.join(lab)}")


def cmd_pf_rules(cfg, args):
    sys.stdout.write(pf_rules(cfg, args.user))


def cmd_pf_install(cfg, args):
    if os.geteuid() != 0:
        raise BuilderError("run with sudo: sudo aeon-builder pf-install")
    anchor = Path("/etc/pf.anchors/at.inspr.aeon-builder")
    atomic_write(anchor, pf_rules(cfg, args.user), mode=0o600)
    plist = Path("/Library/LaunchDaemons/at.inspr.aeon-builder-pf.plist")
    load = f"/sbin/pfctl -E; /sbin/pfctl -a com.apple/aeon-builder -f {anchor}"
    atomic_write(plist, f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>at.inspr.aeon-builder-pf</string>
  <key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>{load}</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
""", mode=0o600)
    subprocess.run(["/bin/launchctl", "bootout", "system", str(plist)], capture_output=True)
    subprocess.run(["/bin/launchctl", "bootstrap", "system", str(plist)], check=True)
    time.sleep(1)
    rules = subprocess.run(["/sbin/pfctl", "-a", "com.apple/aeon-builder", "-sr"], capture_output=True, text=True).stdout
    print(rules or "warning: anchor shows no rules")


def cmd_controller(cfg, args):
    Controller(cfg).run_forever()


def cmd_busy_file(cfg, args):
    # Atomic state saves allow a read-only snapshot without the writer lock.
    write_busy_file(cfg, State().load())


def main(argv=None):
    parser = argparse.ArgumentParser(prog="aeon-builder", description="mbp2606 runner pool for inspr-at/paimos (NIX-600)")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG))
    sub = parser.add_subparsers(dest="command", required=True,
                               metavar="{on,off,status,rebuild-base,pf-rules,pf-install}")
    on = sub.add_parser("on", help="build the base if needed and start serving verified jobs")
    on.add_argument("--resume", action="store_true", help="clear a pause after investigating its alert")
    on.add_argument("--force", action="store_true", help="start even while a lab VM runs")
    off = sub.add_parser("off", help="clear availability, finish queued jobs, remove every runner and job VM")
    off.add_argument("--now", action="store_true", help="hard stop: cancel queued and running mbp2606 runs")
    off.add_argument("--wait", type=int, default=30, help="minutes to wait for the drain (default 30)")
    sub.add_parser("status")
    sub.add_parser("rebuild-base", help="rebuild the sealed base VM")
    pf = sub.add_parser("pf-rules", help="print the pf anchor")
    pf.add_argument("--user", default="ci")
    pfi = sub.add_parser("pf-install", help="install the pf anchor and its boot loader (sudo)")
    pfi.add_argument("--user", default="ci")
    sub.add_parser("controller", help=argparse.SUPPRESS)
    sub.add_parser("busy-file")
    args = parser.parse_args(argv)
    cfg = load_config(args.config)
    try:
        if args.command == "rebuild-base":
            prepare_base(cfg, Lima(cfg), force=True)
        else:
            code = {"on": cmd_on, "off": cmd_off, "status": cmd_status, "pf-rules": cmd_pf_rules,
                    "pf-install": cmd_pf_install, "controller": cmd_controller,
                    "busy-file": cmd_busy_file}[args.command](cfg, args)
            return code or 0
    except BuilderError as err:
        print(f"aeon-builder: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
