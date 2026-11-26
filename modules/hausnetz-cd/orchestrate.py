"""mbp2607 timer tick. Never evaluates/builds NixOS on the workstation."""

import argparse
import fcntl
from pathlib import Path
import re
import shlex
import time
import uuid

from common import (Manual, POLL_BUDGET, POLL_INTERVAL, RESULT_SCHEMA, SSH_RETRY_TIMEOUT,
                    TERMINAL, UNIT_RUNTIME_MAX, atomic_bytes, atomic_json, blob, cache_repo,
                    evidence, gate_g1, gate_g2, gate_g4, git, lock_pin, now,
                    parse_export, private_dir, require, revision, run, strict_json)


# Fleet login shells are fish: every operation explicitly feeds bash. The
# controller validates the same inputs again at the remote execution boundary.
REMOTE = r'''set -euo pipefail
action=$1
rev=${2:-}
expected=${3:-}
mode=${4:-}
digest=${5:-}
run_id=${6:-}
version=${7:-}
manifest_sha=${8:-}
state=/var/lib/hausnetz-cd
if [ "$action" != evidence ]; then
  [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || exit 2
  [[ "$run_id" =~ ^[0-9a-f]{32}$ ]] || exit 2
fi
case "$action" in
  evidence) sudo -n cat /etc/pharos-deployment/evidence.json ;;
  start)
    [[ "$expected" =~ ^[0-9a-f]{40}$ ]] || exit 2
    [[ "$mode" == dry-run || "$mode" == live ]] || exit 2
    [[ "$version" =~ ^[0-9]{12}\.0\.0$ ]] || exit 2
    [[ "$manifest_sha" =~ ^[0-9a-f]{64}$ ]] || exit 2
    sudo -n systemd-run --quiet --collect --unit="hausnetz-cd-$run_id" \
      --property=Type=exec --property=Nice=19 --property=CPUQuota=200% \
      --property=IOSchedulingClass=idle --property=UMask=0077 --property=TimeoutStopSec=300 \
      --property=MemoryHigh=1G --property=MemoryMax=1500M --property=RuntimeMaxSec=@RUNTIME@ \
      --property=KillMode=process --property=SendSIGKILL=no \
      /run/current-system/sw/bin/hausnetz-cd-execute "$rev" "$expected" "$mode" \
      "$version" "$manifest_sha" "$run_id"
    ;;
  status)
    active=$(sudo -n systemctl show "hausnetz-cd-$run_id.service" --property=ActiveState --value 2>/dev/null) || active=unknown
    case "$active" in active|activating|deactivating|inactive|failed) ;; *) active=unknown ;; esac
    printf '{"unit_state":"%s","result":' "$active"
    if sudo -n test -r "$state/results/$run_id.json"; then
      sudo -n cat "$state/results/$run_id.json"
    else
      printf 'null'
    fi
    printf '}\n'
    ;;
  export) sudo -n cat "$state/export" ;;
  ack)
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || exit 2
    printf '%s\n' "$digest" | sudo -n tee "$state/ack-$run_id" >/dev/null
    sudo -n chmod 0600 "$state/ack-$run_id" || true
    ;;
  *) exit 2 ;;
esac
'''.replace("@RUNTIME@", str(UNIT_RUNTIME_MAX))


def remote(config, action, rev="", expected="", mode="", digest="", run_id="",
           version="", manifest_sha="", binary=False):
    args = [action, rev, expected, mode, digest, run_id, version, manifest_sha]
    command = "bash -s -- " + " ".join(shlex.quote(value) for value in args)
    return run(["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                "-o", "StrictHostKeyChecking=yes", config["target"], command],
               data=REMOTE.encode() if binary else REMOTE, binary=binary, timeout=45)


def log_line(result):
    gates = result.get("gates", {})
    return ("hausnetz-cd nixcfg=" + result["nixcfg_rev"] + " hausnetz=" + result["hausnetz_rev"]
            + " generation=" + str(result.get("generation") or "unknown")
            + " gates=" + ",".join(key + ":" + gates.get(key, "not_run") for key in ("G1", "G2", "G3", "G4"))
            + " health=" + result.get("health", "not_run")
            + " rollback=" + result.get("rollback", "not_required")
            + " mode=" + result["mode"] + " status=" + result["status"])


def comment(config, message):
    run([config.get("paimos", "paimos"), "--instance", "ppm", "issue", "comment",
         config["release_ticket"], "--body", message], timeout=30)


def alarm(config, result, label="ROLLBACK FAILED"):
    message = label + " " + log_line(result)
    atomic_json(Path(config["alarm_file"]), {"at": now(), "message": message, "result": result})
    if result["mode"] != "live":
        return
    for command in (config.get("alarm_command"), config.get("secondary_telegram_command")):
        if command:
            try:
                run([*command, message], timeout=45)
            except Manual:
                pass


def copy_export(config, result):
    data = remote(config, "export", result["nixcfg_rev"], run_id=result["run_id"], binary=True)
    export_format, digest = parse_export(data)
    require(digest == result["export_sha256"] and export_format == result["export_format"],
            "offhost_backup_mismatch")
    directory = private_dir(config["export_dir"])
    atomic_bytes(directory / ("export-" + result["nixcfg_rev"] + "." + export_format), data)
    owned = [p for p in directory.iterdir() if p.is_file() and not p.is_symlink()
             and re.fullmatch(r"export-[0-9a-f]{40}\.(json|zip)", p.name)]
    for path in sorted(owned, key=lambda p: p.stat().st_mtime_ns, reverse=True)[20:]:
        path.unlink()
    remote(config, "ack", result["nixcfg_rev"], digest=digest, run_id=result["run_id"])


def validate_result(result, pending):
    require(isinstance(result, dict) and result.get("schema") == RESULT_SCHEMA
            and result.get("nixcfg_rev") == pending["nixcfg_rev"]
            and result.get("hausnetz_rev") == pending["hausnetz_rev"]
            and result.get("run_id") == pending["run_id"]
            and result.get("mode") == pending["mode"], "remote_result_identity")
    require(result.get("status") in TERMINAL | {"running"}, "remote_result_status")
    if result["status"] in {"succeeded", "dry-run"}:
        require(result.get("gates") == {"G1": "pass", "G2": "pass", "G3": "pass", "G4": "pass"},
                "remote_result_gates")
        require(result.get("expected_version") == pending["expected_version"]
                and result.get("manifest_sha256") == pending["manifest_sha256"], "remote_result_coordinate")
    if result["status"] == "succeeded":
        require(result.get("health") == "pass" and result.get("backup") == "copied"
                and result["mode"] == "live", "remote_success_evidence")
    return result


def ledger(config, kind, key):
    # Compact state is bounded; durable tombstones preserve once-only behavior
    # after entries leave those newest-200 summaries. No credentials here.
    require(re.fullmatch(r"[a-z0-9-]+", key), "invalid_ledger_key")
    return Path(config["state_file"]).parent / "hausnetz-cd-ledger" / kind / (key + ".json")


def save_state(config, state):
    state["failed"] = state["failed"][-200:]
    for name in ("attempted", "reports"):
        newest = sorted(state[name].items(), key=lambda item: item[1]["order"])[-200:]
        state[name] = dict(newest)
    atomic_json(config["state_file"], state)


def report(config, state, key):
    entry = state["reports"][key]
    result = entry["result"]
    if result["status"] in {"rollback_failed", "unknown"} and not entry["alarm"]:
        alarm(config, result, "ROLLBACK STATUS UNKNOWN" if result["status"] == "unknown" else "ROLLBACK FAILED")
        entry["alarm"] = True
        save_state(config, state)
    if not entry["ticket"]:
        try:
            comment(config, log_line(result))
            entry["ticket"] = True
            save_state(config, state)
        except Manual:
            pass


def finish(config, state, result):
    key = result["run_key"]
    if result["status"] == "skipped":
        state["attempted"].pop(key, None)
        ledger(config, "attempted", key).unlink(missing_ok=True)
        state["pending"] = None
        save_state(config, state)
        return
    state["sequence"] += 1
    order = state["sequence"]
    state["attempted"][key] = {"status": result["status"], "order": order}
    atomic_json(ledger(config, "attempted", key), {"status": result["status"], "at": now()})
    if result["status"] == "succeeded":
        state["last_deployed"] = result["nixcfg_rev"]
    elif result["status"] in {"failed", "rollback_failed", "manual", "unknown"}:
        target = result["hausnetz_rev"]
        if re.fullmatch(r"[0-9a-f]{40}", target):
            state["failed"] = [rev for rev in state["failed"] if rev != target] + [target]
            atomic_json(ledger(config, "failed", target), {"status": result["status"], "at": now()})
    state["pending"] = None
    state["reports"][key] = {"result": result, "ticket": False, "alarm": False, "order": order}
    save_state(config, state)
    report(config, state, key)


def fixture_limit(config, name, default):
    return config.get(name, default) if config.get("fixture_root") is True else default


def reconcile(config, state):
    pending = state["pending"]
    interval = fixture_limit(config, "poll_interval", POLL_INTERVAL)
    retry = fixture_limit(config, "ssh_retry_timeout", SSH_RETRY_TIMEOUT)

    def unknown(reason):
        finish(config, state, {**pending, "status": "unknown", "phase": "complete",
                               "completed_at": now(), "reason": reason})

    while time.time() < pending["deadline"]:
        try:
            response = strict_json(remote(config, "status", pending["nixcfg_rev"], run_id=pending["run_id"]))
            require(isinstance(response, dict) and response.get("unit_state") in {
                "active", "activating", "deactivating", "inactive", "failed", "unknown"}, "remote_unit_state")
            result = response.get("result")
            # Never accept a stale status, including a skipped file. A live
            # unit may still be creating its own fresh starting record.
            matching = isinstance(result, dict) and result.get("run_id") == pending["run_id"]
            if matching:
                validate_result(result, pending)
                result["run_key"] = pending["run_key"]
                if result["status"] in TERMINAL and (
                    result["status"] == "skipped"
                    or (result.get("phase") == "complete" and result.get("completed_at"))
                ):
                    finish(config, state, result)
                    return
                if result.get("phase") == "switch_unknown":
                    unknown("switch_status_unknown")
                    return
            if response["unit_state"] not in {"active", "activating", "deactivating"}:
                if not matching:
                    # An uncertain SSH start may still be submitting the
                    # unit. With no status from OUR run, allow the same five
                    # minute grace as a transport failure before alarming.
                    raise Manual("executor_result_missing")
                unknown("executor_crashed_or_missing")
                return
            pending.pop("unavailable_since", None)
            save_state(config, state)
            if matching and result.get("phase") == "backup_ready":
                copy_export(config, result)
        except (Manual, OSError, KeyError, TypeError, ValueError):
            since = pending.setdefault("unavailable_since", time.time())
            save_state(config, state)
            if time.time() - since >= retry:
                unknown("executor_status_unavailable")
                return
        time.sleep(min(interval, max(0, pending["deadline"] - time.time())))
    unknown("executor_pending_timeout")


def tick(config):
    if config.get("enabled") is not True:
        return
    require(config["mode"] in {"dry-run", "live"}, "invalid_mode")
    require(re.fullmatch(r"HNET-[0-9]+", config.get("release_ticket") or ""), "release_ticket_unset")
    if config["mode"] == "live":
        require(config.get("secondary_telegram_command"), "independent_alert_path_unset")
    private_dir(Path(config["state_file"]).parent)
    directory = private_dir(config["cache_dir"])
    with open(directory / "orchestrator.lock", "a", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        state_path = Path(config["state_file"])
        if state_path.exists():
            state = strict_json(state_path.read_bytes())
            require(state.get("schema") == "inspr.hausnetz-cd-state.v1"
                    and isinstance(state.get("attempted"), dict) and isinstance(state.get("failed"), list)
                    and isinstance(state.get("reports"), dict) and "pending" in state
                    and type(state.get("sequence")) is int, "invalid_local_state")
        else:
            state = {"schema": "inspr.hausnetz-cd-state.v1", "last_deployed": None,
                     "failed": [], "attempted": {}, "pending": None, "reports": {}, "sequence": 0}
        for key in list(state["reports"]):
            report(config, state, key)
        if state["pending"]:
            reconcile(config, state)
            return
        repo = cache_repo(directory / "nixcfg.git", config["nixcfg_url"])
        new = revision(git(repo, "rev-parse", "refs/heads/main").strip())
        manual_key = "manual-" + new
        if ledger(config, "attempted", manual_key).exists():
            return
        result = {"schema": RESULT_SCHEMA, "nixcfg_rev": new, "hausnetz_rev": "unknown",
                  "run_key": manual_key, "run_id": uuid.uuid4().hex,
                  "mode": config["mode"], "status": "manual", "phase": "preflight",
                  "gates": {"G1": "not_run", "G2": "not_run", "G3": "not_run", "G4": "not_run"},
                  "health": "not_run", "rollback": "not_required", "generation": None}
        try:
            # Parse failures belong to this tick's once-only manual outcome.
            expected, new_lock = lock_pin(blob(repo, new, "flake.lock"))
            result["hausnetz_rev"] = expected
            old = evidence(remote(config, "evidence"))
            cache_repo(repo, config["nixcfg_url"], old, new)
            running = lock_pin(blob(repo, old, "flake.lock"))[0]
            if expected == running:
                return  # no delivery: no reservation, failure entry or comment
            key = running + "-" + expected
            result["run_key"] = key
            if (key in state["attempted"] or expected in state["failed"]
                    or ledger(config, "attempted", key).exists()
                    or ledger(config, "failed", expected).exists()):
                return
            result["phase"] = "G1"
            a, b = gate_g1(repo, old, new)
            require(b == expected, "expected_revision_disagrees_with_lock")
            result["gates"]["G1"] = "pass"
            hausnetz = cache_repo(directory / "hausnetz", config["hausnetz_url"], a, b, worktree=True)
            result["phase"] = "G4"
            gate_g4(hausnetz, a, b)
            result["gates"]["G4"] = "pass"
            result["phase"] = "G2"
            prepared = gate_g2(hausnetz, a, b, new_lock["nodes"]["hausnetz"]["locked"]["narHash"])
            result["gates"]["G2"] = "pass"
        except (Manual, OSError, KeyError, TypeError, ValueError) as exc:
            result["reason"] = str(exc) if isinstance(exc, Manual) else "input_error"
            if result["phase"] in result["gates"]:
                result["gates"][result["phase"]] = "manual"
            finish(config, state, result)
            return
        pending = {"nixcfg_rev": new, "hausnetz_rev": expected, "mode": config["mode"],
                   "run_id": result["run_id"], "run_key": key, "reserved_at": now(),
                   "expected_version": prepared["version"], "manifest_sha256": prepared["manifest_sha256"],
                   "deadline": time.time() + fixture_limit(config, "poll_timeout", POLL_BUDGET)}
        state["sequence"] += 1
        state["attempted"][key] = {"status": "reserved", "order": state["sequence"]}
        state["pending"] = pending
        atomic_json(ledger(config, "attempted", key), {"status": "reserved", "at": now()})
        save_state(config, state)
        try:
            remote(config, "start", new, expected, config["mode"], run_id=pending["run_id"],
                   version=prepared["version"], manifest_sha=prepared["manifest_sha256"])
        except Manual:
            pass
        reconcile(config, state)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    try:
        config = strict_json(Path(args.config).read_bytes())
        tick(config)
    except (Manual, OSError, KeyError, TypeError, ValueError):
        raise SystemExit("hausnetz-cd: manual; configuration, source or evidence unavailable") from None


if __name__ == "__main__":
    main()
