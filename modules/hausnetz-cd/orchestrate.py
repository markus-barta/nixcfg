"""mbp2607 timer tick. Never evaluates/builds NixOS on the workstation."""

import argparse
import fcntl
import ipaddress
import json
from pathlib import Path
import re
import shlex
import sys
import time
import uuid

from common import (Manual, POLL_BUDGET, POLL_INTERVAL, RESULT_SCHEMA, SSH_RETRY_TIMEOUT,
                    TERMINAL, UNIT_RUNTIME_MAX, atomic_bytes, atomic_json, blob, cache_repo,
                    diagnostics, evidence, gate_g1, gate_g2, gate_g4, git, lock_pin, now,
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
running=${9:-}
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
    [[ "$running" =~ ^[0-9a-f]{40}$ ]] || exit 2
    sudo -n systemd-run --quiet --collect --unit="hausnetz-cd-$run_id" \
      --property=Type=exec --property=Nice=19 --property=CPUQuota=200% \
      --property=IOSchedulingClass=idle --property=UMask=0077 --property=TimeoutStopSec=300 \
      --property=MemoryAccounting=yes \
      --property=MemoryHigh=1G --property=MemoryMax=1500M --property=RuntimeMaxSec=@RUNTIME@ \
      --property=KillMode=process --property=SendSIGKILL=no \
      /run/current-system/sw/bin/hausnetz-cd-execute "$rev" "$expected" "$mode" \
      "$version" "$manifest_sha" "$running" "$run_id"
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
           version="", manifest_sha="", running="", binary=False):
    args = [action, rev, expected, mode, digest, run_id, version, manifest_sha, running]
    command = "bash -s -- " + " ".join(shlex.quote(value) for value in args)
    return run("ssh", ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                "-o", "StrictHostKeyChecking=yes", config["target"], command],
               data=REMOTE.encode() if binary else REMOTE, binary=binary, timeout=45)


def log_line(result):
    gates = result.get("gates", {})
    return ("hausnetz-cd nixcfg=" + result["nixcfg_rev"] + " hausnetz=" + result["hausnetz_rev"]
            + " generation=" + str(result.get("generation") or "unknown")
            + " gates=" + ",".join(key + ":" + gates.get(key, "not_run") for key in ("G1", "G2", "G3", "G4", "G5"))
            + " health=" + result.get("health", "not_run")
            + " rollback=" + result.get("rollback", "not_required")
            + " changed_paths=" + json.dumps(diagnostics(result.get("changed_paths", [])), separators=(",", ":"))
            + " problems=" + json.dumps(diagnostics(result.get("problems", [])), separators=(",", ":"))
            + " memory_peak_bytes=" + str(result.get("memory_peak_bytes") or "unknown")
            + " mode=" + result["mode"] + " status=" + result["status"])


def comment(config, message):
    run(config.get("paimos", "paimos"), ["--instance", "ppm", "issue", "comment",
         config["release_ticket"], "--body", message], timeout=30)


def mailbox_target(path):
    """Read only the local, non-repo endpoint; never source it as shell code."""
    with open(path, "rb") as source:
        raw = source.read(4097)
    require(len(raw) <= 4096, "invalid_mailbox_file")
    text = raw.decode("ascii")
    lines = text.removesuffix("\n").split("\n")
    require(len(lines) == 3, "invalid_mailbox_file")
    values = {}
    for line in lines:
        key, separator, value = line.partition("=")
        require(separator and key in {"host", "port", "user"} and key not in values,
                "invalid_mailbox_file")
        values[key] = value
    host = values["host"]
    try:
        ipaddress.ip_address(host)
    except ValueError:
        require(len(host) <= 253 and re.fullmatch(
            r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
            r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.?", host),
            "invalid_mailbox_host")
    # Exclude scoped IPv6 addresses and all shell/SSH option characters.
    require(re.fullmatch(r"[A-Za-z0-9.:-]+", host), "invalid_mailbox_host")
    require(re.fullmatch(r"[0-9]{1,5}", values["port"])
            and 1 <= int(values["port"]) <= 65535, "invalid_mailbox_port")
    require(re.fullmatch(r"[a-z_][a-z0-9_-]*", values["user"]), "invalid_mailbox_user")
    return host, int(values["port"]), values["user"]


def alarm_route_failed(route):
    # Values and command diagnostics are deliberately excluded from logs.
    print("hausnetz-cd: alarm route failed: " + route, file=sys.stderr, flush=True)


def alarm(config, result, label="ROLLBACK FAILED", *, pre_pair=False, test=False):
    if result["mode"] != "live" and not pre_pair and not test:
        return
    result = {**result, "changed_paths": diagnostics(result.get("changed_paths")),
              "problems": diagnostics(result.get("problems"))}
    message = (label + " nixcfg=" + result["nixcfg_rev"] + " hausnetz=" + result["hausnetz_rev"]
               + " generation=" + str(result.get("generation") or "unknown")[:200]
               + " reason=" + str(result.get("reason") or "unknown")[:200])
    if not test:
        atomic_json(Path(config["alarm_file"]), {"at": now(), "message": message, "result": result})
    fallback = False
    try:
        host, port, user = mailbox_target(config["mailbox_remote_file"])
    except (Manual, OSError, UnicodeError, KeyError, TypeError, ValueError):
        fallback = True
        alarm_route_failed("remote mailbox file missing/invalid")
    else:
        for recipient in ("mac-lead", "lead"):
            try:
                command = ("PATH=$HOME/.local/bin:$PATH mbx send " + recipient
                           + " -f mac-ops -t " + shlex.quote(config["release_ticket"]) + " -m -")
                run("ssh", ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                            "-o", "StrictHostKeyChecking=yes", "-p", str(port), user + "@" + host,
                            command], data=message, timeout=45)
            except Manual:
                fallback = True
                alarm_route_failed("remote mailbox " + recipient)
    if fallback:
        for recipient in ("mac-lead", "lead"):
            try:
                run(config["local_mailbox_command"], ["send", recipient, "-f", "mac-ops",
                    "-t", config["release_ticket"], "-m", "-"], data=message, timeout=45)
            except (Manual, KeyError):
                alarm_route_failed("local mailbox " + recipient)
    # Exactly one csb1 attempt, including when remote delivery needed fallback.
    for route, command in (("local hook", config.get("alarm_command")),
                           ("csb1 Telegram", config.get("secondary_telegram_command"))):
        if not command:
            if route == "csb1 Telegram":
                alarm_route_failed(route + " unconfigured")
            continue
        try:
            run(command[0], command[1:], data=message, timeout=45)
        except Manual:
            alarm_route_failed(route)


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
        require(result.get("gates") == {"G1": "pass", "G2": "controller_evidence",
                                        "G3": "pass", "G4": "controller_evidence"},
                "remote_result_gates")
        require(result.get("expected_version") == pending["expected_version"]
                and result.get("manifest_sha256") == pending["manifest_sha256"], "remote_result_coordinate")
        require(result.get("running_nixcfg_rev") == pending["running_nixcfg_rev"]
                and result.get("controller_evidence") == {
                    "running_nixcfg_rev": pending["running_nixcfg_rev"],
                    "hausnetz_rev": pending["hausnetz_rev"],
                    "version": pending["expected_version"],
                    "manifest_sha256": pending["manifest_sha256"]}, "remote_controller_evidence")
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
    if not entry["ticket"] and entry.get("ticket_attempts", 0) < 5:
        # Reserve before sending, so a crash cannot reset the retry budget.
        entry["ticket_attempts"] = entry.get("ticket_attempts", 0) + 1
        atomic_json(ledger(config, "outbox", key), entry)
        save_state(config, state)
        try:
            comment(config, log_line(result))
            entry["ticket"] = True
        except Manual:
            pass
        if entry["ticket"]:
            ledger(config, "outbox", key).unlink(missing_ok=True)
        else:
            atomic_json(ledger(config, "outbox", key), entry)
        save_state(config, state)
    if (not entry["ticket"] and entry.get("ticket_attempts", 0) >= 5
            and not entry.get("outbox_logged")):
        print("hausnetz-cd: ticket retries exhausted; report retained in local outbox key=" + key,
              flush=True)
        entry["outbox_logged"] = True
        atomic_json(ledger(config, "outbox", key), entry)
        save_state(config, state)


def finish(config, state, result):
    for name in ("changed_paths", "problems"):
        result[name] = diagnostics(result.get(name))
    key = result["run_key"]
    if result["status"] == "skipped":
        state["attempted"].pop(key, None)
        ledger(config, "attempted", key).unlink(missing_ok=True)
        state["pending"] = None
        save_state(config, state)
        return
    if result["status"] == "fetch_failed" and key in state["reports"]:
        return  # One report per fetch outage/pair; the source remains retryable.
    state["sequence"] += 1
    order = state["sequence"]
    if result["status"] != "fetch_failed":
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
                result["changed_paths"] = pending.get("changed_paths", [])
                result["problems"] = pending.get("problems", [])
                result.setdefault("gates", {})["G5"] = pending.get("vm_test", "not_run")
                result["vm_test_reason"] = pending.get("vm_test_reason", "not_run")
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


def vm_test(rev):
    """Only the newest hosted workflow run for this exact commit can pass."""
    revision(rev)
    try:
        value = strict_json(run("gh", ["api", "--method", "GET",
            "repos/inspr-at/hausnetz/actions/workflows/vm-test.yml/runs?head_sha=" + rev + "&per_page=100"], timeout=30))
        runs = value["workflow_runs"]
        require(isinstance(runs, list), "vm_test_schema")
        require(runs, "vm_test_missing")
        require(all(isinstance(r, dict) and r.get("head_sha") == rev
                    and type(r.get("id")) is int for r in runs), "vm_test_revision_or_schema")
        latest = max(runs, key=lambda r: r["id"])
        require(latest.get("status") == "completed", "vm_test_pending")
        require(latest.get("conclusion") == "success", "vm_test_failed")
        return "pass", "vm_test_success"
    except (Manual, KeyError, TypeError, ValueError):
        return "manual", "vm_test_not_successful_or_unavailable"


def pre_pair_failure(config, state):
    failure = state.setdefault("pre_pair_failure", {"since": time.time(), "alarmed": False})
    if time.time() - failure["since"] >= 6 * 60 * 60 and not failure["alarmed"]:
        alarm(config, {"mode": config["mode"], "nixcfg_rev": "unknown", "hausnetz_rev": "unknown",
                       "reason": "source_or_running_evidence_unavailable_6h"},
              "CD PREFLIGHT UNAVAILABLE", pre_pair=True)
        failure["alarmed"] = True
    save_state(config, state)


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
        if config.get("manual_dry_run"):
            require(not state["pending"] or state["pending"]["mode"] == "dry-run", "live_pending_refuses_dry_run")
        for key in list(state["reports"]):
            if not config.get("manual_dry_run") or state["reports"][key]["result"]["mode"] == "dry-run":
                report(config, state, key)
        if state["pending"]:
            reconcile(config, state)
            return
        # Nothing is a delivery attempt until both hausnetz revisions are known
        # and different. Transport/source failures must remain retryable.
        try:
            repo = cache_repo(directory / "nixcfg.git", config["nixcfg_url"])
            new = revision(git(repo, "rev-parse", "refs/heads/main").strip())
            expected, new_lock = lock_pin(blob(repo, new, "flake.lock"))
            evaluated = state.get("evaluated", {})
            if (evaluated.get("main") == new and time.time() - evaluated.get("at", 0) < 30 * 60
                    and not state.get("pre_pair_failure") and not config.get("manual_dry_run")):
                revision(evaluated["running"])
                return
            old = evidence(remote(config, "evidence"))
            cache_repo(repo, config["nixcfg_url"], old, new)
            running = lock_pin(blob(repo, old, "flake.lock"))[0]
        except (Manual, OSError, KeyError, TypeError, ValueError):
            pre_pair_failure(config, state)
            print("hausnetz-cd: tick skipped; source or running evidence unavailable", flush=True)
            return
        state.pop("pre_pair_failure", None)
        def evaluated_tick():
            state["evaluated"] = {"main": new, "running": old, "at": time.time()}
            save_state(config, state)
        if expected == running:
            evaluated_tick()
            return  # no delivery: no reservation, failure entry or comment
        key = running + "-" + expected
        if (key in state["attempted"] or expected in state["failed"]
                or ledger(config, "attempted", key).exists()
                or ledger(config, "failed", expected).exists()):
            evaluated_tick()
            return
        result = {"schema": RESULT_SCHEMA, "nixcfg_rev": new, "hausnetz_rev": "unknown",
                  "run_key": key, "run_id": uuid.uuid4().hex,
                  "mode": config["mode"], "status": "manual", "phase": "preflight",
                  "gates": {"G1": "not_run", "G2": "not_run", "G3": "not_run", "G4": "not_run", "G5": "not_run"},
                  "health": "not_run", "rollback": "not_required", "generation": None,
                  "changed_paths": [], "problems": []}
        try:
            result["hausnetz_rev"] = expected
            result["phase"] = "G1"
            a, b = gate_g1(repo, old, new)
            require(b == expected, "expected_revision_disagrees_with_lock")
            result["gates"]["G1"] = "pass"
            result["phase"] = "fetch"
            hausnetz = cache_repo(directory / "hausnetz", config["hausnetz_url"], a, b, worktree=True)
            result["phase"] = "G4"
            gate_g4(hausnetz, a, b)
            result["gates"]["G4"] = "pass"
            result["phase"] = "G2"
            prepared = gate_g2(hausnetz, a, b, new_lock["nodes"]["hausnetz"]["locked"]["narHash"])
            result["gates"]["G2"] = "pass"
            result["phase"] = "G5"
            result["gates"]["G5"], result["vm_test_reason"] = vm_test(b)
            require(config["mode"] == "dry-run" or result["gates"]["G5"] == "pass", "G5_vm_test_required")
        except (Manual, OSError, KeyError, TypeError, ValueError) as exc:
            result["reason"] = str(exc) if isinstance(exc, Manual) else "input_error"
            if isinstance(exc, Manual) and exc.problems is not None:
                result["problems"] = exc.problems
            if isinstance(exc, Manual) and exc.changed_paths is not None:
                result["changed_paths"] = exc.changed_paths
            if result["phase"] in result["gates"]:
                result["gates"][result["phase"]] = "manual"
            if result["phase"] == "fetch":
                result.update(status="fetch_failed", reason="hausnetz_fetch_failed", run_key=key + "-fetch")
            else:
                evaluated_tick()
            finish(config, state, result)
            return
        pending = {"nixcfg_rev": new, "hausnetz_rev": expected, "mode": config["mode"],
                   "running_nixcfg_rev": old,
                   "run_id": result["run_id"], "run_key": key, "reserved_at": now(),
                   "expected_version": prepared["version"], "manifest_sha256": prepared["manifest_sha256"],
                   "changed_paths": prepared["changed_paths"], "problems": prepared["problems"],
                   "vm_test": result["gates"]["G5"], "vm_test_reason": result["vm_test_reason"],
                   "deadline": time.time() + fixture_limit(config, "poll_timeout", POLL_BUDGET)}
        state["sequence"] += 1
        state["attempted"][key] = {"status": "reserved", "order": state["sequence"]}
        state["pending"] = pending
        atomic_json(ledger(config, "attempted", key), {"status": "reserved", "at": now()})
        save_state(config, state)
        try:
            remote(config, "start", new, expected, config["mode"], run_id=pending["run_id"],
                   version=prepared["version"], manifest_sha=prepared["manifest_sha256"], running=old)
        except Manual:
            pass
        reconcile(config, state)
        if key in state["attempted"]:
            evaluated_tick()


# Nix substitutes this store path before installing the production entrypoint.
CONFIG_FILE = "@CONFIG@"


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--test-alarm", action="store_true")
    args = parser.parse_args()
    if args.once != args.dry_run:
        parser.error("manual execution requires both --once and --dry-run")
    if args.test_alarm and (args.once or args.dry_run):
        parser.error("--test-alarm cannot be combined with deployment flags")
    try:
        require(not CONFIG_FILE.startswith("@"), "unsubstituted_configuration")
        config = strict_json(Path(CONFIG_FILE).read_bytes())
        if args.test_alarm:
            require(re.fullmatch(r"HNET-[0-9]+", config.get("release_ticket") or ""),
                    "release_ticket_unset")
            alarm(config, {"mode": "dry-run", "nixcfg_rev": "unknown", "hausnetz_rev": "unknown",
                           "reason": "operator_alarm_test"}, "TEST CD ALARM", test=True)
            return
        if args.once:
            config = {**config, "enabled": True, "mode": "dry-run", "manual_dry_run": True}
        tick(config)
    except (Manual, OSError, KeyError, TypeError, ValueError):
        raise SystemExit("hausnetz-cd: manual; configuration, source or evidence unavailable") from None


if __name__ == "__main__":
    main()
