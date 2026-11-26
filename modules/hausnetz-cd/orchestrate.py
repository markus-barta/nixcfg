"""mbp2607 timer tick. Never evaluates/builds NixOS on the workstation."""

import argparse
import fcntl
import os
from pathlib import Path
import re
import shlex
import time

from common import (Manual, RESULT_SCHEMA, TERMINAL, atomic_bytes, atomic_json,
                    blob, cache_repo, evidence, gate_g1, gate_g2, git, lock_pin,
                    now, parse_export, private_dir, require, revision, run, strict_json)


# The fleet login shell is fish. Every remote operation explicitly feeds bash,
# including read-only operations; no local interpolation of heredoc content.
REMOTE = r'''set -euo pipefail
action=$1
rev=${2:-}
expected=${3:-}
mode=${4:-}
digest=${5:-}
state=/var/lib/hausnetz-cd
if [ "$action" != evidence ]; then [[ "$rev" =~ ^[0-9a-f]{40}$ ]]; fi
case "$action" in
  evidence) sudo -n cat /etc/pharos-deployment/evidence.json ;;
  start)
    [[ "$expected" =~ ^[0-9a-f]{40}$ ]]
    [[ "$mode" == dry-run || "$mode" == live ]]
    sudo -n systemd-run --quiet --collect --unit="hausnetz-cd-$rev" \
      --property=Type=exec --property=Nice=19 --property=CPUQuota=200% \
      --property=IOSchedulingClass=idle --property=UMask=0077 --property=TimeoutStopSec=300 \
      /run/current-system/sw/bin/hausnetz-cd-execute "$rev" "$expected" "$mode"
    ;;
  status)
    if sudo -n test -r "$state/results/$rev.json"; then
      sudo -n cat "$state/results/$rev.json"
    else
      active=$(sudo -n systemctl show "hausnetz-cd-$rev.service" --property=ActiveState --value 2>/dev/null) || active=missing
      case "$active" in
        active|activating|deactivating) printf '{"status":"pending"}\n' ;;
        *) printf '{"status":"missing"}\n' ;;
      esac
    fi
    ;;
  export) sudo -n cat "$state/export" ;;
  ack)
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]]
    printf '%s\n' "$digest" | sudo -n tee "$state/ack-$rev" >/dev/null
    ;;
  *) exit 2 ;;
esac
'''


def remote(config, action, rev="", expected="", mode="", digest="", binary=False):
    args = [action, rev, expected, mode, digest]
    command = "bash -s -- " + " ".join(shlex.quote(value) for value in args)
    return run(["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                "-o", "StrictHostKeyChecking=yes", config["target"], command],
               data=REMOTE.encode() if binary else REMOTE, binary=binary, timeout=45)


def log_line(result):
    gates = result.get("gates", {})
    return ("hausnetz-cd nixcfg=" + result["nixcfg_rev"] + " hausnetz=" + result["hausnetz_rev"]
            + " generation=" + str(result.get("generation") or "unknown")
            + " gates=" + ",".join(key + ":" + gates.get(key, "not_run") for key in ("G1", "G2", "G3"))
            + " health=" + result.get("health", "not_run")
            + " rollback=" + result.get("rollback", "not_required")
            + " mode=" + result["mode"] + " status=" + result["status"])


def comment(config, message):
    run([config.get("paimos", "paimos"), "--instance", "ppm", "issue", "comment",
         config["release_ticket"], "--body", message], timeout=30)


def alarm(config, result, label="ROLLBACK FAILED"):
    message = label + " " + log_line(result)
    # Always persist the local alarm, even when the independent channels fail.
    atomic_json(Path(config["alarm_file"]), {"at": now(), "message": message, "result": result})
    for command in (config.get("alarm_command"), config.get("secondary_telegram_command")):
        if command:
            try:
                # Configured argv, never shell evaluation. The coordinator's
                # second argv must invoke csb1's sender over ssh on csb1 itself.
                run([*command, message], timeout=45)
            except Manual:
                pass
    try:
        comment(config, message)
    except Manual:
        pass


def copy_export(config, result):
    data = remote(config, "export", result["nixcfg_rev"], binary=True)
    export_format, digest = parse_export(data)
    require(digest == result["export_sha256"] and export_format == result["export_format"],
            "offhost_backup_mismatch")
    directory = private_dir(config["export_dir"])
    atomic_bytes(directory / ("export-" + result["nixcfg_rev"] + "." + export_format), data)
    owned = [p for p in directory.iterdir() if p.is_file() and not p.is_symlink()
             and re.fullmatch(r"export-[0-9a-f]{40}\.(json|zip)", p.name)]
    for path in sorted(owned, key=lambda p: p.stat().st_mtime_ns, reverse=True)[20:]:
        path.unlink()
    remote(config, "ack", result["nixcfg_rev"], digest=digest)


def validate_result(result, pending):
    require(result.get("schema") == RESULT_SCHEMA
            and result.get("nixcfg_rev") == pending["nixcfg_rev"]
            and result.get("hausnetz_rev") == pending["hausnetz_rev"]
            and result.get("mode") == pending["mode"], "remote_result_identity")
    require(result.get("status") in TERMINAL | {"running"}, "remote_result_status")
    if result["status"] in {"succeeded", "dry-run"}:
        require(result.get("gates") == {"G1": "pass", "G2": "pass", "G3": "pass"}, "remote_result_gates")
    if result["status"] == "succeeded":
        require(result.get("health") == "pass" and result.get("backup") == "copied"
                and result["mode"] == "live", "remote_success_evidence")
    return result


def report(config, state, result):
    # Durable outbox: ticket/alarm failures never cause a deployment retry.
    rev = result["nixcfg_rev"]
    entry = state["reports"].setdefault(rev, {"result": result, "ticket": False, "alarm": False})
    if result["status"] == "rollback_failed" and not entry["alarm"]:
        alarm(config, result)
        entry["alarm"] = True
        atomic_json(config["state_file"], state)
    if not entry["ticket"]:
        try:
            comment(config, log_line(result))
            entry["ticket"] = True
            atomic_json(config["state_file"], state)
        except Manual:
            pass


def finish(config, state, result):
    rev = result["nixcfg_rev"]
    if result["status"] == "skipped":
        # Busy deploy lock is explicitly exempt from once-only execution.
        state["attempted"].pop(rev, None)
        state["pending"] = None
        atomic_json(config["state_file"], state)
        return
    state["attempted"][rev] = result["status"]
    if result["status"] == "succeeded":
        state["last_deployed"] = rev
    elif result["status"] in {"failed", "rollback_failed", "manual"}:
        if rev not in state["failed"]:
            state["failed"].append(rev)
    state["pending"] = None
    state["reports"][rev] = {"result": result, "ticket": False, "alarm": False}
    atomic_json(config["state_file"], state)
    report(config, state, result)


def reconcile(config, state):
    pending = state["pending"]

    def unavailable(reason):
        if pending["mode"] == "live" and not pending.get("uncertainty_reported"):
            result = {**pending, "status": "unknown", "reason": reason}
            alarm(config, result, "ROLLBACK STATUS UNKNOWN")
            pending["uncertainty_reported"] = True
            atomic_json(config["state_file"], state)
        elif not pending.get("uncertainty_reported"):
            atomic_json(config["alarm_file"], {"at": now(), "reason": reason,
                                               "nixcfg_rev": pending["nixcfg_rev"]})

    deadline = time.monotonic() + min(config.get("poll_timeout", 720), 720)
    while time.monotonic() < deadline:
        try:
            result = strict_json(remote(config, "status", pending["nixcfg_rev"]))
            if result.get("status") == "missing":
                # A start might have reached the host just before an SSH loss.
                # Keep the reservation; never start that revision a second time.
                raise Manual("executor_result_missing")
            if result.get("status") != "pending":
                validate_result(result, pending)
                if result.get("phase") == "backup_ready":
                    copy_export(config, result)
                if result["status"] in TERMINAL and (
                    result["status"] == "skipped"
                    or (result.get("phase") == "complete" and result.get("completed_at"))
                ):
                    finish(config, state, result)
                    return
        except (Manual, OSError, KeyError, TypeError, ValueError):
            # Reconcile on the next timer tick. The detached executor continues
            # recovery without the Mac. Transport loss never means success.
            unavailable("executor_status_unavailable")
            return
        time.sleep(min(config.get("poll_interval", 2), max(0, deadline - time.monotonic())))
    unavailable("executor_pending_timeout")


def tick(config):
    # Disabled means no clones, SSH, host probes, tickets, or state changes.
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
                    and isinstance(state.get("reports"), dict) and "pending" in state, "invalid_local_state")
        else:
            state = {"schema": "inspr.hausnetz-cd-state.v1", "last_deployed": None,
                     "failed": [], "attempted": {}, "pending": None, "reports": {}}
        for item in list(state["reports"].values()):
            report(config, state, item["result"])
        if state["pending"]:
            reconcile(config, state)
            return
        repo = cache_repo(directory / "nixcfg.git", config["nixcfg_url"])
        new = revision(git(repo, "rev-parse", "refs/heads/main").strip())
        if new in state["attempted"] or new in state["failed"] or new == state["last_deployed"]:
            return
        expected = lock_pin(blob(repo, new, "flake.lock"))[0]
        result = {"schema": RESULT_SCHEMA, "nixcfg_rev": new, "hausnetz_rev": expected,
                  "mode": config["mode"], "status": "manual", "phase": "preflight",
                  "gates": {"G1": "not_run", "G2": "not_run", "G3": "not_run"},
                  "health": "not_run", "rollback": "not_required", "generation": None}
        try:
            old = evidence(remote(config, "evidence"))
            if old == new:
                return
            cache_repo(repo, config["nixcfg_url"], old, new)
            result["phase"] = "G1"
            a, b = gate_g1(repo, old, new)
            require(b == expected, "expected_revision_disagrees_with_lock")
            result["gates"]["G1"] = "pass"
            result["phase"] = "G2"
            require(config.get("manifest_path"), "G2_manifest_unset_or_invalid")
            hausnetz = cache_repo(directory / "hausnetz.git", config["hausnetz_url"], a, b)
            gate_g2(hausnetz, a, b, config["manifest_path"])
            result["gates"]["G2"] = "pass"
        except (Manual, OSError, KeyError, TypeError, ValueError) as exc:
            result["reason"] = str(exc) if isinstance(exc, Manual) else "input_error"
            if result["phase"] in result["gates"]:
                result["gates"][result["phase"]] = "manual"
            finish(config, state, result)
            return
        pending = {"nixcfg_rev": new, "hausnetz_rev": expected, "mode": config["mode"], "reserved_at": now()}
        state["attempted"][new] = "reserved"
        state["pending"] = pending
        # Reserve durably before SSH. Neither a crash nor a failed response
        # permits this immutable nixcfg revision to be launched again.
        atomic_json(config["state_file"], state)
        try:
            remote(config, "start", new, expected, config["mode"])
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
