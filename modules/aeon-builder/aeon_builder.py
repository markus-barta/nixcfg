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
import datetime as dt
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
CANCEL = {"actions": "write"}
ADMIN_READ = {"administration": "read"}
ADMIN_WRITE = {"administration": "write"}
VARIABLES = {"actions_variables": "write"}


class BuilderError(RuntimeError):
    pass


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
    if run.get("head_branch") != cfg["branch"]:
        return False, f"branch {run.get('head_branch') or 'missing'}"
    sha = run.get("head_sha") or ""
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        return False, "head sha missing"
    if not sha_on_branch(sha):
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


def availability_record(cfg, free_slots, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    return {
        "schema": 1,
        "repository": cfg["repo"],
        "os": "linux",
        "arch": "arm64",
        "online": True,
        "busy": free_slots <= 0,
        "observed_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "idle_runners": max(free_slots, 0),
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
    def __init__(self, cfg):
        self.cfg = cfg
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
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                parsed = json.loads(raw) if raw else {}
                if etag_key and resp.headers.get("ETag"):
                    self.etags[etag_key] = (resp.headers["ETag"], parsed)
                return parsed
        except urllib.error.HTTPError as err:
            if err.code == 304 and etag_key in self.etags:
                return self.etags[etag_key][1]
            detail = err.read()[:300].decode(errors="replace")
            raise BuilderError(f"{method} {path}: HTTP {err.code} {detail}") from None

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
        return self.call("GET", self.repo_path(f"/rulesets/{self.cfg['ruleset']['id']}"), ADMIN_READ)

    def jit(self, name):
        body = {"name": name, "runner_group_id": 1, "labels": self.cfg["runnerLabels"], "work_folder": "_work"}
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
        out = self.run("list", "--json", check=False).stdout
        return {item["name"]: item for item in (json.loads(line) for line in out.splitlines() if line.strip())}

    def disks(self):
        out = self.run("disk", "list", "--json", check=False).stdout
        return {item["name"]: item for item in (json.loads(line) for line in out.splitlines() if line.strip())}

    def shell(self, name, command, input=None, check=True, timeout=300):
        return self.run("shell", "--workdir", "/", name, "--", "bash", "-c", command, input=input, check=check, timeout=timeout)

    def delete(self, name):
        self.run("delete", "--force", name, check=False)


# ---------------------------------------------------------------- state


def now_utc():
    return dt.datetime.now(dt.timezone.utc)


def atomic_write(path, text, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    with os.fdopen(fd, "w") as handle:
        handle.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


class State:
    def __init__(self, root=STATE_DIR):
        self.root = root
        self.file = root / "state.json"

    def load(self):
        try:
            return json.loads(self.file.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return {"mode": "off", "slots": {}, "verifiedRuns": [], "cancelledRuns": []}

    def save(self, data):
        atomic_write(self.file, json.dumps(data, indent=2, sort_keys=True))

    def update(self, fn):
        data = self.load()
        fn(data)
        self.save(data)
        return data


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
    def __init__(self, cfg, gh=None, lima=None, state=None):
        self.cfg = cfg
        self.gh = gh or GitHub(cfg)
        self.lima = lima or Lima(cfg)
        self.state = state or State()
        self.lock = threading.Lock()
        self.workers = {}
        self.last_ruleset = 0.0
        self.ruleset_ok = False
        self.last_proof = time.time()
        self.tainted = set()
        self.slot_used_cache = {}
        self.slot_fresh = {}

    # -- slots
    def free_slots(self, data, pending):
        used = len(data["slots"]) + pending
        return self.cfg["slots"] - used

    def pause(self, reason):
        """A failed protection check: refuse availability, stop minting and
        cancel queued mbp2606 runs so nothing waits on a pool that is off."""
        log(f"PAUSE: {reason}")
        self.state.update(lambda d: d.update(mode="paused", alert=f"{now_utc().isoformat()} {reason}"))
        try:
            self.gh.clear()
        except BuilderError as err:
            log(f"clear availability failed: {err}")
        try:
            cancelled = cancel_label_runs(self.gh, self.cfg, statuses=("queued",))
            if cancelled:
                log(f"cancelled queued mbp2606 run(s): {', '.join(map(str, cancelled))}")
        except BuilderError as err:
            log(f"cancel after pause failed: {err}")

    def check_ruleset(self, force=False):
        if not force and time.time() - self.last_ruleset < 60 and self.ruleset_ok:
            return True
        problems = ruleset_problems(self.gh.ruleset(), self.cfg["ruleset"]["expected"])
        self.last_ruleset = time.time()
        self.ruleset_ok = not problems
        if problems:
            self.pause("main ruleset changed: " + "; ".join(problems))
        return self.ruleset_ok

    def tick(self):
        data = self.state.load()
        mode = data.get("mode")
        if mode not in ("on", "draining"):
            return mode
        candidates = []
        for run in self.gh.active_runs():
            for job in self.gh.jobs(run["id"]):
                if job.get("status") == "queued" and wants_label(job, self.cfg["label"]):
                    candidates.append((run, job))
        pending = 0
        for run, job in candidates:
            with self.lock:
                data = self.state.load()
                assigned = {s["jobId"] for s in data["slots"].values()}
            if job["id"] in assigned or job["id"] in self.workers:
                continue
            if run["id"] in data["cancelledRuns"]:
                continue
            ok, reason = (True, "ok") if run["id"] in data["verifiedRuns"] else verify_run(run, self.cfg, self.gh.sha_on_branch)
            if not ok:
                log(f"reject run {run['id']} ({run.get('event')} {run.get('head_repository', {}).get('full_name')}): {reason}; cancelling")
                try:
                    self.gh.cancel(run["id"])
                except BuilderError as err:
                    log(f"cancel {run['id']} failed: {err}")
                self.state.update(lambda d: d["cancelledRuns"].append(run["id"]))
                continue
            if run["id"] not in data["verifiedRuns"]:
                self.state.update(lambda d: d["verifiedRuns"].append(run["id"]))
            slot = self.claim_slot(job, run)
            if slot is None:
                pending += 1
                continue
            thread = threading.Thread(target=self.serve, args=(slot, run, job), daemon=True)
            self.workers[job["id"]] = thread
            thread.start()
        self.reap_finished_workers()
        data = self.state.load()
        if data.get("mode") == "on" and self.cfg["requireNetworkBlock"] and not data["slots"] \
                and time.time() - self.last_proof > self.cfg["proofMinutes"] * 60:
            ok, detail = prove_network_block(self.cfg, self.lima)
            self.last_proof = time.time()
            if not ok:
                self.pause(f"network block proof failed: {detail}")
                return "paused"
            self.state.update(lambda d: d.update(networkProof=now_utc().isoformat()))
            data = self.state.load()
        if data.get("mode") == "on" and self.check_ruleset():
            self.gh.publish(availability_record(self.cfg, self.free_slots(data, pending)))
        if data.get("mode") == "draining" and not candidates and not data["slots"] and not self.workers:
            self.state.update(lambda d: d.update(mode="off"))
            log("drained; pool is off")
            return "off"
        for key in ("verifiedRuns", "cancelledRuns"):
            if len(data[key]) > 500:
                self.state.update(lambda d, k=key: d.__setitem__(k, d[k][-300:]))
        return data.get("mode")

    def reap_finished_workers(self):
        for job_id, thread in list(self.workers.items()):
            if not thread.is_alive():
                del self.workers[job_id]

    def claim_slot(self, job, run):
        if not self.check_ruleset():
            return None
        with self.lock:
            data = self.state.load()
            for slot in range(self.cfg["slots"]):
                if str(slot) not in data["slots"]:
                    data["slots"][str(slot)] = {
                        "jobId": job["id"], "runId": run["id"], "attempt": run.get("run_attempt"), "event": run["event"],
                        "since": now_utc().isoformat(), "phase": "cloning",
                    }
                    self.state.save(data)
                    return slot
        return None

    def set_slot(self, slot, **fields):
        with self.lock:
            self.state.update(lambda d: d["slots"][str(slot)].update(fields))

    def release_slot(self, slot):
        with self.lock:
            self.state.update(lambda d: d["slots"].pop(str(slot), None))

    # -- one job VM
    def serve(self, slot, run, job):
        vm = f"aeon-job-{slot}"
        runner_id = None
        disk = None
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
            if not self.check_ruleset(force=True):
                return
            if self.unverified_label_runs():
                log(f"slot {slot}: unverified mbp2606 jobs were queued; cancelled them, not minting this tick")
                return
            current = self.gh.job(job["id"])
            if current.get("status") != "queued":
                log(f"job {job['id']} no longer queued ({current.get('status')}); not minting")
                return
            name = f"mbp2606-s{slot}-{job['id']}-{secrets.token_hex(3)}"
            jit = self.gh.jit(name)
            runner_id = jit["runner"]["id"]
            self.set_slot(slot, phase="waiting", runner=name, runnerId=runner_id)
            log(f"slot {slot}: runner {name} for run {run['id']} attempt {run.get('run_attempt')} job {job['id']} ({run['event']}, disk {disk})")
            self.lima.run("shell", "--workdir", "/", vm, "--", "sudo", "/opt/aeon/start-runner", input=jit["encoded_jit_config"])
            outcome = self.wait_for_runner(slot, vm, name, job)
            if outcome == "ran":
                if not self.post_job_check(slot, vm, name, job):
                    self.tainted.add(slot)
            elif outcome in ("denied", "unverified", "unattributed"):
                self.tainted.add(slot)
            if slot not in self.tainted:
                self.lima.run("shell", "--workdir", "/", vm, "--", "sudo", "/opt/aeon/cache-lock", "lock", check=False)
        except Exception as err:  # noqa: BLE001 - one slot must never kill the pool
            log(f"slot {slot}: {err}")
            self.tainted.add(slot)
        finally:
            if runner_id:
                try:
                    self.gh.delete_runner(runner_id)
                except BuilderError as err:
                    log(f"slot {slot}: runner cleanup failed: {err}")
            self.lima.delete(vm)
            self.finish_disk(slot, disk)
            self.release_slot(slot)

    def unverified_label_runs(self):
        """Before every mint: no queued job that could take an mbp2606 runner
        (its labels a subset of ours) may belong to an unverified run, whatever
        its event or ref. Cancel those runs and report whether any existed."""
        data = self.state.load()
        found = []
        for run in self.gh.active_runs():
            if run["id"] in data["verifiedRuns"] or run["id"] in found:
                continue
            if not any(j.get("status") == "queued" and could_take(j, self.cfg["runnerLabels"]) for j in self.gh.jobs(run["id"])):
                continue
            ok, reason = verify_run(run, self.cfg, self.gh.sha_on_branch)
            if ok:
                self.state.update(lambda d, r=run["id"]: d["verifiedRuns"].append(r))
                continue
            log(f"reject run {run['id']} ({run.get('event')}): {reason}; cancelling")
            try:
                self.gh.cancel(run["id"])
            except BuilderError as err:
                log(f"cancel {run['id']} failed: {err}")
            self.state.update(lambda d, r=run["id"]: d["cancelledRuns"].append(r))
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
        # Dispatch: read the last known-good cache, write only a disposable clone.
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
        if disk and disk.startswith("aeon-scratch-"):
            self.drop_scratch(slot)
            return
        if not disk:
            return
        good = self.good_copy(slot)
        if slot in self.tainted:
            log(f"slot {slot}: cache disk tainted; restoring the last known-good copy")
            if good.exists():
                subprocess.run(["/bin/cp", "-c", str(good), str(self.disk_file(disk))], check=True)
            else:
                self.lima.run("disk", "delete", "--force", disk, check=False)
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
            self.lima.run("disk", "delete", "--force", scratch, check=False)

    # -- the job's lifetime
    def vm_running(self, vm):
        return (self.lima.instances().get(vm) or {}).get("status") == "Running"

    def wait_for_runner(self, slot, vm, name, job):
        """Returns ran | idle | denied | unverified | unattributed | timeout | stopped."""
        deadline = time.time() + self.cfg["maxJobMinutes"] * 60
        idle_since = None
        unlocked = False
        while time.time() < deadline:
            if self.state.load().get("mode") == "stopping":
                log(f"slot {slot}: hard stop")
                return "stopped"
            if not self.vm_running(vm):
                self.pause(f"slot {slot}: {vm} powered off during a job (the hook denies by powering off)")
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
                current = self.gh.job(job["id"])
                if current.get("status") != "queued":
                    idle_since = idle_since or time.time()
                    if time.time() - idle_since > 60:
                        log(f"slot {slot}: job {job['id']} went elsewhere ({current.get('status')}); retiring idle runner")
                        return "idle"
            time.sleep(3)
        log(f"slot {slot}: job exceeded {self.cfg['maxJobMinutes']} min; stopping VM")
        return "timeout"

    def admit(self, slot, vm, name, job):
        """The hook admitted a job; confirm through the API which job this runner
        took, then hand the cache key over. Anything else kills the VM."""
        ran = None
        for _ in range(10):
            ran = self.find_runner_job(name, job)
            if ran:
                break
            time.sleep(2)
        verified = set(self.state.load()["verifiedRuns"])
        if ran is None:
            self.pause(f"slot {slot}: hook admitted a job the API cannot attribute to {name}")
            return "unattributed"
        if ran.get("run_id") not in verified:
            self.pause(f"slot {slot}: {name} took job {ran.get('id')} of unverified run {ran.get('run_id')} attempt {ran.get('run_attempt')}")
            return "unverified"
        self.set_slot(slot, phase="running", ranJob=ran.get("id"), ranRun=ran.get("run_id"), ranAttempt=ran.get("run_attempt"))
        size = max(self.cfg["cacheDiskGiB"] - 4, 8)
        init = ["--init"] if self.slot_fresh.get(slot) else []
        self.lima.run("shell", "--workdir", "/", vm, "--", "sudo", "/opt/aeon/cache-lock", "unlock", str(size), *init,
                      input=self.slot_key(slot))
        self.slot_used_cache[slot] = True
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
        pidfile = STATE_DIR / "controller.pid"
        atomic_write(pidfile, str(os.getpid()))
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        log("controller started")
        try:
            while True:
                try:
                    mode = self.tick()
                except Exception as err:  # noqa: BLE001 - keep polling through API hiccups
                    log(f"tick failed: {err}")
                    mode = self.state.load().get("mode")
                if mode in ("off", "paused") and not self.workers:
                    break
                if mode == "stopping" and not self.workers:
                    self.state.update(lambda d: d.update(mode="off"))
                    break
                time.sleep(self.cfg["pollSeconds"])
        finally:
            try:
                self.gh.clear()
            except BuilderError as err:
                log(f"clear availability failed: {err}")
            pidfile.unlink(missing_ok=True)
            log("controller stopped")


# ---------------------------------------------------------------- commands


def cancel_label_runs(gh, cfg, statuses=("queued", "in_progress")):
    cancelled = []
    for run in gh.active_runs():
        if run["id"] in cancelled:
            continue
        if any(could_take(j, cfg["runnerLabels"]) and j.get("status") in statuses for j in gh.jobs(run["id"])):
            gh.cancel(run["id"])
            cancelled.append(run["id"])
    return cancelled


def load_config(path):
    return json.loads(Path(path).read_text())


def controller_pid():
    try:
        pid = int((STATE_DIR / "controller.pid").read_text())
        os.kill(pid, 0)
        return pid
    except (FileNotFoundError, ValueError, ProcessLookupError, PermissionError):
        return None


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
    state.update(lambda d: (d.update(mode="on"), d.pop("alert", None)))
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
    state = State()
    gh = GitHub(cfg)
    gh.clear()
    if args.now:
        state.update(lambda d: d.update(mode="stopping"))
        cancelled = cancel_label_runs(gh, cfg)
        print(f"aeon-builder: hard stop, cancelled {len(cancelled)} run(s)")
    else:
        data = state.load()
        if data.get("mode") in ("on", "paused"):
            state.update(lambda d: d.update(mode="draining" if controller_pid() else "off"))
        print("aeon-builder: draining — availability cleared, queued mbp2606 jobs are still served")
    deadline = time.time() + args.wait * 60
    while time.time() < deadline and controller_pid():
        data = state.load()
        print(f"  {data.get('mode')}: {len(data['slots'])} job VM(s) busy", flush=True)
        time.sleep(10)
    lima = Lima(cfg)
    if controller_pid():
        print("aeon-builder: still draining in the background; `aeon-builder status` shows progress")
        return
    for name in lima.instances():
        if name.startswith("aeon-job-"):
            lima.delete(name)
    for runner in gh.runners():
        if runner["name"].startswith("mbp2606-"):
            gh.delete_runner(runner["id"])
    state.update(lambda d: (d.update(mode="off"), d.__setitem__("slots", {})))
    print("aeon-builder: off — no runners, no job VMs")


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
    print(f"controller:  {'pid ' + str(pid) if pid else 'not running'}")
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
    anchor.write_text(pf_rules(cfg, args.user))
    anchor.chmod(0o644)
    plist = Path("/Library/LaunchDaemons/at.inspr.aeon-builder-pf.plist")
    load = f"/sbin/pfctl -E; /sbin/pfctl -a com.apple/aeon-builder -f {anchor}"
    plist.write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>at.inspr.aeon-builder-pf</string>
  <key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>{load}</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
""")
    plist.chmod(0o644)
    subprocess.run(["/bin/launchctl", "bootout", "system", str(plist)], capture_output=True)
    subprocess.run(["/bin/launchctl", "bootstrap", "system", str(plist)], check=True)
    time.sleep(1)
    rules = subprocess.run(["/sbin/pfctl", "-a", "com.apple/aeon-builder", "-sr"], capture_output=True, text=True).stdout
    print(rules or "warning: anchor shows no rules")


def cmd_controller(cfg, args):
    Controller(cfg).run_forever()


def main(argv=None):
    parser = argparse.ArgumentParser(prog="aeon-builder", description="mbp2606 runner pool for inspr-at/paimos (NIX-600)")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG))
    sub = parser.add_subparsers(dest="command", required=True)
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
    args = parser.parse_args(argv)
    cfg = load_config(args.config)
    try:
        if args.command == "rebuild-base":
            prepare_base(cfg, Lima(cfg), force=True)
        else:
            {"on": cmd_on, "off": cmd_off, "status": cmd_status, "pf-rules": cmd_pf_rules,
             "pf-install": cmd_pf_install, "controller": cmd_controller}[args.command](cfg, args)
    except BuilderError as err:
        print(f"aeon-builder: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
