"""mbp2607 timer tick. Never evaluates/builds NixOS on the workstation."""

import argparse
import datetime
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import sys
import time
import unicodedata
import uuid

from common import (ACCEPTANCE_TIMEOUT, EXECUTOR_TERMINAL, Manual, POLL_BUDGET, POLL_INTERVAL, RESULT_SCHEMA, SSH_RETRY_TIMEOUT,
                    TERMINAL, UNIT_RUNTIME_MAX, atomic_bytes, atomic_json, blob, cache_repo,
                    diagnostics, evidence, gate_g1, gate_g2, gate_g4, git, lock_pin, now,
                    parse_export, private_dir, require, revision, run, strict_json,
                    child_group_alive, controller_children)


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
variant=${10:-}
one_shot=${11:-}
state=/var/lib/hausnetz-cd
if [ "$action" != evidence ]; then
  [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || exit 2
  [[ "$run_id" =~ ^[0-9a-f]{32}$ ]] || exit 2
fi
case "$action" in
  evidence) sudo -n cat /etc/pharos-deployment/evidence.json ;;
  generation) sudo -n readlink /nix/var/nix/profiles/system ;;
  ack-live)
    sudo -n install -d -m 0700 "$state"
    [[ "$digest" == "$run_id" ]] || exit 2
    printf '%s\n' "$run_id" | sudo -n tee "$state/ack-live-$run_id" >/dev/null
    sudo -n chmod 0600 "$state/ack-live-$run_id"
    ;;
  acceptance)
    [[ "$digest" == pass || "$digest" == fail ]] || exit 2
    temporary=$(sudo -n mktemp "$state/.acceptance-$run_id.XXXXXX")
    printf '%s\n' "$digest" | sudo -n tee "$temporary" >/dev/null
    sudo -n chmod 0600 "$temporary"
    sudo -n mv -fT "$temporary" "$state/acceptance-$run_id"
    ;;
  rehearse)
    [[ "$variant" == A || "$variant" == B ]] || exit 2
    [[ "$one_shot" =~ ^[0-9a-f]{32}$ ]] || exit 2
    sudo -n install -d -m 0700 "$state"
    printf '%s\n' "$one_shot" | sudo -n tee "$state/rehearsal-token-$run_id" >/dev/null
    sudo -n chmod 0600 "$state/rehearsal-token-$run_id"
    sudo -n systemd-run --quiet --collect --unit="hausnetz-cd-$run_id" \
      --property=Type=exec --property=Nice=19 --property=CPUQuota=200% \
      --property=IOSchedulingClass=idle --property=UMask=0077 --property=TimeoutStopSec=300 \
      --property=MemoryAccounting=yes --property=MemoryHigh=1G --property=MemoryMax=1500M \
      --property=RuntimeMaxSec=@RUNTIME@ --property=KillMode=process --property=SendSIGKILL=no \
      /run/current-system/sw/bin/hausnetz-cd-execute rehearse --variant "$variant" --token "$one_shot" --run-id "$run_id"
    ;;
  start)
    extra=()
    if [[ "$variant" == trial ]]; then
      [[ "$mode" == dry-run ]] || exit 2
      extra=(--trial)
    fi
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
      /run/current-system/sw/bin/hausnetz-cd-execute ${extra[@]+"${extra[@]}"} "$rev" "$expected" "$mode" \
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
           version="", manifest_sha="", running="", variant="", one_shot="", binary=False):
    args = [action, rev, expected, mode, digest, run_id, version, manifest_sha, running, variant, one_shot]
    command = "bash -s -- " + " ".join(shlex.quote(value) for value in args)
    return run("ssh", ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                "-o", "StrictHostKeyChecking=yes", config["target"], command],
               data=REMOTE.encode() if binary else REMOTE, binary=binary, timeout=45)


def log_line(result):
    gates = result.get("gates", {})
    prefix = "TEST (no action): " if result.get("rehearsal") else ""
    hausnetz = result.get("old_hausnetz_rev") if result.get("rehearsal") else result["hausnetz_rev"]
    return (prefix + "hausnetz-cd nixcfg=" + result["nixcfg_rev"] + " hausnetz=" + (hausnetz or "unknown")
            + " generation=" + str(result.get("generation") or "unknown")
            + " gates=" + ",".join(key + ":" + gates.get(key, "not_run") for key in ("G1", "G2", "G3", "G4", "G5"))
            + " health=" + result.get("health", "not_run")
            + " rollback=" + result.get("rollback", "not_required")
            + " changed_paths=" + json.dumps(diagnostics(result.get("changed_paths", [])), separators=(",", ":"))
            + " problems=" + json.dumps(diagnostics(result.get("problems", [])), separators=(",", ":"))
            + " removed_stale_boot_entries=" + json.dumps(result.get("removed_stale_boot_entries", []), separators=(",", ":"))
            + " acceptance=" + result.get("acceptance", "not_run")
            + " failed_units_after_activation=" + json.dumps(diagnostics(result.get("failed_units_after_activation", [])), separators=(",", ":"))
            + " memory_peak_bytes=" + str(result.get("memory_peak_bytes") or "unknown")
            + " mode=" + result["mode"] + " status=" + result["status"]
            + (" rehearsal_reason=" + json.dumps(result.get("rehearsal_reason")) if result.get("rehearsal") else ""))


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


def operator_reason(value, command):
    value = value if isinstance(value, str) else ""
    reason = value.strip()
    require(reason, command + " requires --reason <text>")
    require(len(value) <= 500, command + " --reason must be at most 500 characters")
    require(all(unicodedata.category(c) not in {"Cc", "Cf", "Cs", "Zl", "Zp"} for c in value),
            command + " --reason must contain no control characters")
    return reason


def rehearsal_reason(value):
    return operator_reason(value, "rehearse")


def disable_marker(config):
    return Path(config["state_file"]).parent / "operator-disable.json"


def read_disable(config):
    path = disable_marker(config)
    try:
        try:
            path.lstat()
        except FileNotFoundError:
            return None
        require(not path.is_symlink(), "invalid_operator_disable_marker")
        value = strict_json(path.read_bytes())
        require(isinstance(value, dict) and value.get("operator") is True
                and isinstance(value.get("at"), str) and value["at"]
                and operator_reason(value.get("reason"), "--disable") == value["reason"],
                "invalid_operator_disable_marker")
        require(datetime.datetime.fromisoformat(value["at"]).tzinfo is not None,
                "invalid_operator_disable_marker")
        return value
    except (Manual, OSError, KeyError, TypeError, ValueError):
        if not config.get("_malformed_disable_logged"):
            print("hausnetz-cd: malformed or unreadable operator disable marker; disabled (fail-closed)", flush=True)
            config["_malformed_disable_logged"] = True
        return {"operator": True, "at": now(), "reason": "invalid_operator_disable_marker"}


def merge_disable(config, state):
    require("disabled" not in state or isinstance(state["disabled"], dict), "invalid_disable_latch")
    marker = read_disable(config)
    if marker is not None:
        state["operator_stop"] = {**marker, "operator": True}
        save_state(config, state)
        return True
    return "operator_stop" in state


class AlarmRouteUnavailable(Manual):
    pass


def rehearsal_probe_command(config, route):
    """Reuse alarm SSH arguments, replacing the complete remote command."""
    if route == "csb1":
        command = config.get("secondary_telegram_command")
        require(isinstance(command, list) and len(command) >= 3
                and all(isinstance(arg, str) and arg for arg in command)
                and Path(command[0]).name == "ssh", "invalid_secondary_telegram_command")
        return [*command[:-1], "true"]
    require(route == "remote mailbox", "invalid_probe_route")
    host, port, user = mailbox_target(config["mailbox_remote_file"])
    return ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=yes", "-p", str(port), user + "@" + host, "true"]


def rehearsal_preflight(config):
    routes = ["csb1"]
    # An absent endpoint file means remote mailbox delivery is unconfigured;
    # the existing local mailbox fallback remains available in that case.
    if config.get("mailbox_remote_file") and Path(config["mailbox_remote_file"]).exists():
        routes.append("remote mailbox")
    for route in routes:
        try:
            command = rehearsal_probe_command(config, route)
            run(command[0], command[1:], data="", timeout=45)
        except (Manual, OSError, UnicodeError, KeyError, TypeError, ValueError):
            raise AlarmRouteUnavailable("alarm route unavailable: " + route) from None


def alarm_route_failed(route):
    # Values and command diagnostics are deliberately excluded from logs.
    print("hausnetz-cd: alarm route failed: " + route, file=sys.stderr, flush=True)


def alarm_ticket_args(config):
    ticket = config.get("alarm_ticket")
    if ticket is None:
        return []
    require(isinstance(ticket, str) and re.fullmatch(r"[A-Z][A-Z0-9]+-[0-9]+", ticket),
            "invalid_alarm_ticket")
    return ["-t", ticket]


def alarm(config, result, label="ROLLBACK FAILED", *, pre_pair=False, test=False):
    if result["mode"] != "live" and not pre_pair and not test and not result.get("rehearsal"):
        return False
    ticket_args = alarm_ticket_args(config)
    result = {**result, "changed_paths": diagnostics(result.get("changed_paths")),
              "problems": diagnostics(result.get("problems"))}
    if result.get("rehearsal"):
        # Rehearsal transport identity uses the running nixcfg rev in both
        # slots; operator messages identify the actual running hausnetz pin.
        result["hausnetz_rev"] = revision(result["old_hausnetz_rev"]) if result.get("old_hausnetz_rev") else "unknown"
    message = (label + " nixcfg=" + result["nixcfg_rev"] + " hausnetz=" + result["hausnetz_rev"]
               + " generation=" + str(result.get("generation") or "unknown")[:200]
               + " reason=" + str(result.get("reason") or "unknown")[:200])
    message += " failed_units_after_activation=" + json.dumps(diagnostics(result.get("failed_units_after_activation", [])), separators=(",", ":"))
    if result.get("ack_command"):
        message += " run_token=" + result["run_id"] + " ack_command=" + result["ack_command"]
    if result.get("alarm_id"):
        message += " alarm_id=" + result["alarm_id"]
    if not test:
        atomic_json(Path(config["alarm_file"]), {"at": now(), "message": message, "result": result})
    fallback = False
    delivered = False
    try:
        host, port, user = mailbox_target(config["mailbox_remote_file"])
    except (Manual, OSError, UnicodeError, KeyError, TypeError, ValueError):
        fallback = True
        alarm_route_failed("remote mailbox file missing/invalid")
    else:
        for recipient in ("mac-lead", "lead"):
            try:
                command = ("PATH=$HOME/.local/bin:$PATH mbx send " + recipient
                           + " -f mac-ops " + shlex.join(ticket_args + ["-m", "-"]))
                run("ssh", ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                            "-o", "StrictHostKeyChecking=yes", "-p", str(port), user + "@" + host,
                            command], data=message, timeout=45)
                delivered = True
            except Manual:
                fallback = True
                alarm_route_failed("remote mailbox " + recipient)
    if fallback:
        for recipient in ("mac-lead", "lead"):
            try:
                run(config["local_mailbox_command"], ["send", recipient, "-f", "mac-ops",
                    *ticket_args, "-m", "-"], data=message, timeout=45)
                delivered = True
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
            delivered = True
        except Manual:
            alarm_route_failed(route)
    return delivered


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
    # A stop may have arrived during the export read/copy.
    if read_disable(config) is None:
        remote(config, "ack", result["nixcfg_rev"], digest=digest, run_id=result["run_id"])


def validate_result(result, pending):
    require(isinstance(result, dict) and result.get("schema") == RESULT_SCHEMA
            and result.get("nixcfg_rev") == pending["nixcfg_rev"]
            and result.get("hausnetz_rev") == pending["hausnetz_rev"]
            and result.get("run_id") == pending["run_id"]
            and result.get("mode") == pending["mode"], "remote_result_identity")
    require(result.get("status") in EXECUTOR_TERMINAL | {"running"}, "remote_result_status")
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
                and result["mode"] == "live" and result.get("acceptance") == "pass", "remote_success_evidence")
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


def queue_alarm(config, state, key, result, label, *, pre_pair=False):
    if ledger(config, "alarms", key).exists():
        return
    state.setdefault("pending_alarms", {}).setdefault(key, {"result": {**result, "alarm_id": key}, "label": label, "pre_pair": pre_pair})
    save_state(config, state)


def deliver_alarms(config, state):
    # Stable alarm IDs allow operator-side deduplication if a process dies after
    # delivery but before its receipt is saved. Completed ticks never resend.
    for key, entry in list(state.get("pending_alarms", {}).items()):
        receipt = ledger(config, "alarms", key)
        if not receipt.exists():
            if not alarm(config, entry["result"], entry["label"], pre_pair=entry.get("pre_pair", False)):
                continue
            atomic_json(receipt, {"at": now()})
        state["pending_alarms"].pop(key)
        save_state(config, state)


def report(config, state, key):
    entry = state["reports"][key]
    result = entry["result"]
    if (result["status"] in {"rollback_failed", "unknown", "rehearsal_aborted"}
            and (result["mode"] == "live" or result.get("rehearsal")) and not entry["alarm"]):
        prefix = "TEST (no action): " if result.get("rehearsal") else ""
        label = "ROLLBACK STATUS UNKNOWN" if result["status"] == "unknown" else ("ROLLBACK FAILED" if result["status"] == "rollback_failed" else "REHEARSAL ABORTED")
        queue_alarm(config, state, result["run_id"] + "-terminal", result, prefix + label)
        entry["alarm"] = True
        if state.get("disabled", {}).get("run_id") == result.get("run_id"):
            state["disabled"]["alarmed"] = True
        save_state(config, state)
        deliver_alarms(config, state)
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
    if result["status"] == "preflight_refused":
        pending = state.get("pending") or {}
        running = result.get("running_nixcfg_rev") or pending.get("running_nixcfg_rev")
        if running:
            state["evaluated"] = {"main": result["nixcfg_rev"], "running": running,
                                  "at": time.time(), "check_running": True}
        state["attempted"].pop(key, None)
        ledger(config, "attempted", key).unlink(missing_ok=True)
        state["pending"] = None
        if key in state["reports"] and state["reports"][key]["result"]["status"] == "preflight_refused":
            save_state(config, state)
            return
        queue_alarm(config, state, result["run_id"] + "-preflight", result, "CD PREFLIGHT REFUSED")
        deliver_alarms(config, state)
    if result["status"] in {"fetch_failed", "vm_test_wait"} and key in state["reports"]:
        save_state(config, state)
        return  # One report per fetch outage/pair; the source remains retryable.
    state["sequence"] += 1
    order = state["sequence"]
    if result.get("operator_disabled") or result["status"] == "operator_disabled":
        # A stopped pair remains retryable after the stop is explicitly cleared.
        state["attempted"].pop(key, None)
        ledger(config, "attempted", key).unlink(missing_ok=True)
    if not result.get("operator_disabled") and result["status"] not in {"operator_disabled", "fetch_failed", "vm_test_wait", "preflight_refused"} and not result.get("trial") and not result.get("rehearsal"):
        state["attempted"][key] = {"status": result["status"], "order": order}
        atomic_json(ledger(config, "attempted", key), {"status": result["status"], "at": now()})
    if (result["status"] == "rollback_failed" or (result["status"] == "unknown" and result["mode"] != "dry-run")
            or result.get("rollback") == "failed" or result.get("disable_reason")):
        print("hausnetz-cd: disabled latch set after " + result["status"], flush=True)
        state.setdefault("disabled", {"at": now(), "run_id": result["run_id"],
                                      "reason": result.get("disable_reason") or result.get("rollback_reason") or result.get("reason") or result["status"], "alarmed": False,
                                      "test": bool(result.get("rehearsal"))})
    if result["status"] == "succeeded":
        if result["mode"] == "live" and state.get("attended_remaining", 3) > 0:
            state["attended_remaining"] -= 1
        state["last_deployed"] = result["nixcfg_rev"]
    elif not result.get("operator_disabled") and result["status"] in {"failed", "rolled_back", "rollback_failed", "manual", "unknown"} and not result.get("trial") and not result.get("rehearsal"):
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
            operator_disabled = merge_disable(config, state)
            if operator_disabled:
                pending["operator_disabled"] = True
                if pending["mode"] == "dry-run" or pending.get("phase") == "awaiting_ack":
                    finish(config, state, {**pending, "status": "operator_disabled", "phase": "complete",
                                           "completed_at": now(), "reason": "operator_disabled"})
                    return
                # The executor already accepts fail as an immediate rollback
                # request. Persisted stop intent always overrides acceptance.
                pending["acceptance"] = "fail"
                remote(config, "acceptance", pending["nixcfg_rev"], run_id=pending["run_id"], digest="fail")
            response = strict_json(remote(config, "status", pending["nixcfg_rev"], run_id=pending["run_id"]))
            require(isinstance(response, dict) and response.get("unit_state") in {
                "active", "activating", "deactivating", "inactive", "failed", "unknown"}, "remote_unit_state")
            result = response.get("result")
            # Never accept a stale status, including a skipped file. A live
            # unit may still be creating its own fresh starting record.
            matching = isinstance(result, dict) and result.get("run_id") == pending["run_id"]
            if matching:
                validate_result(result, pending)
                pending.update(generation=result.get("generation") or pending.get("generation"),
                               executor_reason=result.get("reason"))
                result["changed_paths"] = pending.get("changed_paths", [])
                result["problems"] = pending.get("problems", [])
                result.setdefault("gates", {})["G5"] = pending.get("vm_test", "not_run")
                result["vm_test_reason"] = pending.get("vm_test_reason", "not_run")
                result["run_key"] = pending["run_key"]
                result["trial"] = pending.get("trial", False)
                if pending.get("operator_disabled"):
                    result["operator_disabled"] = True
                if pending.get("rehearsal"):
                    require(result.get("rehearsal") == pending["rehearsal"], "rehearsal_result_variant")
                    result["rehearsal_reason"] = pending.get("rehearsal_reason")
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
                # Never acknowledge a backup once stopped: the executor's
                # backup_copy_not_acknowledged path exits without switching.
                if not pending.get("operator_disabled") and not merge_disable(config, state):
                    copy_export(config, result)
                else:
                    pending["operator_disabled"] = True
                    save_state(config, state)
            if matching and result.get("phase") == "acceptance_ready":
                if "acceptance" not in pending:
                    pending["acceptance"] = acceptance(config, pending)
                    if pending["acceptance"] != "pass":
                        queue_alarm(config, state, pending["run_id"] + "-acceptance",
                                    {**pending, "reason": "acceptance_failed_or_timeout"}, "ACCEPTANCE FAILED")
                    save_state(config, state)
                if merge_disable(config, state):
                    pending.update(acceptance="fail", operator_disabled=True)
                    save_state(config, state)
                # A stop observed before this write forces FAIL. A stop landing
                # during the SSH write of an already-decided PASS may not stop
                # that one pass; the executor can consume it before the next poll.
                remote(config, "acceptance", pending["nixcfg_rev"], run_id=pending["run_id"],
                       digest=pending["acceptance"])
                deliver_alarms(config, state)
        except (Manual, OSError, KeyError, TypeError, ValueError):
            since = pending.setdefault("unavailable_since", time.time())
            save_state(config, state)
            if time.time() - since >= retry:
                unknown("executor_status_unavailable")
                return
        time.sleep(min(interval, max(0, pending["deadline"] - time.time())))
    unknown("executor_pending_timeout")


def acceptance_settings(config):
    command = config.get("acceptance_command", [])
    require(isinstance(command, list) and command and all(isinstance(a, str) for a in command), "acceptance_unset")
    require(isinstance(config.get("acceptance_url"), str) and config["acceptance_url"], "acceptance_url_unset")
    require(0 < config.get("acceptance_timeout", ACCEPTANCE_TIMEOUT) <= ACCEPTANCE_TIMEOUT, "acceptance_timeout_invalid")
    require(all("{" + name + "}" in " ".join(command)
                for name in ("trusted_rev", "url", "version", "caps_sha256")), "acceptance_contract_unset")
    return command


def acceptance(config, pending):
    """Only an operator-configured CI-VM invocation may run the trusted checker."""
    try:
        command = acceptance_settings(config)
        # The VM adapter MUST materialize this exact pre-switch revision and run
        # just acceptance there. Its argv is configured, never candidate input.
        values = {"trusted_rev": revision(pending["trusted_hausnetz_rev"]),
                  "url": config["acceptance_url"], "version": pending["expected_version"],
                  "caps_sha256": pending["manifest_sha256"]}
        require(all("{" + name + "}" in " ".join(command) for name in values), "acceptance_contract_unset")
        argv = [arg.format_map(values) for arg in command]
        value = strict_json(run(argv[0], argv[1:], timeout=config.get("acceptance_timeout", ACCEPTANCE_TIMEOUT)))
        require(isinstance(value, dict) and value.get("ok") is True, "acceptance_red_or_schema")
        return "pass"
    except (Manual, OSError, KeyError, TypeError, ValueError):
        return "fail"


def start_pending(config, state):
    pending = state["pending"]
    if merge_disable(config, state):
        finish(config, state, {**pending, "status": "operator_disabled", "phase": "complete",
                               "completed_at": now(), "reason": "operator_disabled", "operator_disabled": True})
        return False
    if pending["mode"] == "live":
        ack = Path(config["state_file"]).parent / ("ack-live-" + pending["run_id"])
        if pending.get("attended_required"):
            valid_ack = (ack.is_file() and not ack.is_symlink()
                         and ack.read_text().strip() == pending["run_id"]
                         and pending["ack_requested_at"] <= ack.stat().st_mtime <= pending["ack_deadline"])
            if not valid_ack and time.time() >= pending["ack_deadline"]:
                if not pending.get("ack_timeout_alarmed"):
                    pending["ack_timeout_alarmed"] = True
                    queue_alarm(config, state, pending["run_id"] + "-ack-timeout",
                                {**pending, "reason": "attended_ack_timeout"}, "ack timeout, release left manual")
                    deliver_alarms(config, state)
                finish(config, state, {**pending, "status": "ack_timeout", "phase": "complete", "completed_at": now(),
                                       "reason": "attended_ack_timeout"})
                return False
            if not valid_ack:
                print("hausnetz-cd: awaiting attended ack run_token=" + pending["run_id"], flush=True)
                return False
        remote(config, "ack-live", pending["nixcfg_rev"], run_id=pending["run_id"], digest=pending["run_id"])
    pending["phase"] = "executor"
    pending["deadline"] = time.time() + fixture_limit(config, "poll_timeout", POLL_BUDGET)
    if not pending.get("trial"):
        state["sequence"] += 1
        state["attempted"][pending["run_key"]] = {"status": "reserved", "order": state["sequence"]}
        atomic_json(ledger(config, "attempted", pending["run_key"]), {"status": "reserved", "at": now()})
    save_state(config, state)
    try:
        remote(config, "start", pending["nixcfg_rev"], pending["hausnetz_rev"], pending["mode"],
               run_id=pending["run_id"], version=pending["expected_version"],
               manifest_sha=pending["manifest_sha256"], running=pending["running_nixcfg_rev"],
               variant="trial" if pending.get("trial") else "")
    except Manual:
        pass  # uncertain submission is reconciled by run ID, never resubmitted
    return True


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
        require(latest.get("conclusion") in {"success", "failure", "cancelled", "timed_out", "action_required",
                                             "neutral", "skipped", "stale", "startup_failure"}, "vm_test_schema")
        if latest.get("conclusion") != "success":
            return "failed", "vm_test_completed_" + str(latest.get("conclusion"))
        return "pass", "vm_test_success"
    except (Manual, KeyError, TypeError, ValueError):
        return "manual", "vm_test_not_successful_or_unavailable"


def acceptance_entrypoint(repo, trusted_rev):
    for filename in ("justfile", "Justfile", ".justfile"):
        try:
            text = blob(repo, trusted_rev, filename)
        except Manual:
            continue
        if re.search(r"(?m)^acceptance(?:[ \t]+[^:\n]*)?:", text):
            return True
    return False


def pre_pair_failure(config, state):
    failure = state.setdefault("pre_pair_failure", {"since": time.time(), "alarmed": False})
    if time.time() - failure["since"] >= 6 * 60 * 60 and not failure["alarmed"]:
        key = failure.setdefault("alarm_id", uuid.uuid4().hex + "-pre-pair")
        queue_alarm(config, state, key,
                    {"mode": config["mode"], "nixcfg_rev": "unknown", "hausnetz_rev": "unknown",
                     "reason": "source_or_running_evidence_unavailable_6h"},
                    "CD PREFLIGHT UNAVAILABLE", pre_pair=True)
        failure["alarmed"] = True
        deliver_alarms(config, state)
    save_state(config, state)


def clear_child(config, reason, *, force=False, pgid=None):
    path = Path(config["state_file"]).parent / "controller-children.json"
    if not path.exists():
        print("hausnetz-cd: child record already clear", flush=True)
        return
    require(not path.is_symlink(), "clear-child: record is a symlink; cannot verify recorded pid/pgid")
    try:
        before = path.read_bytes()
    except OSError:
        raise Manual("clear-child: record unreadable; cannot verify recorded pid/pgid") from None
    groups = []
    seen = "pid=unknown pgid=unknown"
    try:
        entries = strict_json(before)
        require(isinstance(entries, list), "invalid_child_record")
        for entry in entries:
            require(isinstance(entry, dict), "invalid_child_record")
            seen = "pid=" + str(entry.get("pid") if type(entry.get("pid")) is int else "invalid")
            seen += " pgid=" + str(entry.get("pgid") if type(entry.get("pgid")) is int else "invalid")
            groups.append(entry.get("pgid"))
            require(not child_group_alive(entry),
                    "clear-child: child alive pid=" + str(entry.get("pid")) + " pgid=" + str(entry.get("pgid")))
    except Manual as exc:
        if str(exc).startswith("clear-child:"):
            raise
        require(force, "clear-child: record malformed (" + seen + "); inspect and use --force --pgid <group> only after it exits")
    except (OSError, KeyError, TypeError, ValueError):
        require(force, "clear-child: record malformed or unverifiable (" + seen + "); inspect before forced recovery")
    if force:
        # Include every recoverable recorded group, not just the supplied one.
        try:
            raw = strict_json(before)
            raw_entries = raw if isinstance(raw, list) else [raw]
            groups.extend(e["pgid"] for e in raw_entries if isinstance(e, dict) and "pgid" in e)
        except (Manual, ValueError):
            pass
        for group in [*groups, pgid]:
            require(type(group) is int and group > 1,
                    "clear-child: invalid pgid; cannot verify group death")
            try:
                os.killpg(group, 0)
            except ProcessLookupError:
                continue
            except OSError:
                raise Manual("clear-child: cannot verify pgid=" + str(group)) from None
            raise Manual("clear-child: group alive pgid=" + str(group) + "; force refused")
    require(not path.is_symlink() and path.read_bytes() == before,
            "clear-child: record changed; retry after inspecting it")
    # Keep recovery attribution separate from controller state: no tick lock.
    atomic_json(path.with_name("child-cleared.json"), {"at": now(), "reason": reason,
                                                      "forced": force, "pgid": pgid})
    path.unlink()
    print("hausnetz-cd: cleared dead child record", flush=True)


def tick(config):
    config = {**config, "_malformed_disable_logged": False}
    record = Path(config["state_file"]).parent / "controller-children.json"
    with controller_children(record):
        tick_owned(config, record)


def tick_owned(config, child_record):
    marker = read_disable(config)
    if config.get("enabled") is not True and marker is None:
        return
    if config.get("rehearsal"):
        rehearsal_reason(config.get("rehearsal_reason"))
    private_dir(Path(config["state_file"]).parent)
    directory = private_dir(config["cache_dir"])
    with open(directory / "orchestrator.lock", "a", encoding="utf-8") as lock:
        lock_deadline = time.monotonic() + (5 if config.get("clear_disable") or config.get("clear_failed") else 0)
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= lock_deadline:
                    if config.get("clear_disable") or config.get("clear_failed"):
                        raise Manual("busy: a tick holds the lock; retry")
                    return
                time.sleep(0.05)
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
        merge_disable(config, state)
        if child_record.exists():
            # Never overlap an earlier controller's group, including malformed
            # ownership evidence. Keep the diagnostic distinct from a live group.
            problem = "earlier controller child still alive"
            try:
                children = strict_json(child_record.read_bytes())
                require(isinstance(children, list), "invalid_child_record")
                alive = any(child_group_alive(entry) for entry in children)
            except (Manual, OSError, KeyError, TypeError, ValueError):
                alive = True
                problem = "earlier controller child record malformed or unreadable"
            if alive:
                blocked = state.setdefault("child_blocked", {"since": time.time(), "alarmed": False})
                print("hausnetz-cd: tick skipped; " + problem, flush=True)
                if time.time() - blocked["since"] > 30 * 60 and not blocked["alarmed"]:
                    key = blocked.setdefault("alarm_id", uuid.uuid4().hex + "-child-blocked")
                    queue_alarm(config, state, key,
                                {"mode": config["mode"], "nixcfg_rev": "unknown", "hausnetz_rev": "unknown",
                                 "reason": problem.replace(" ", "_") + "_30m"},
                                "CD CHILD RECORD MALFORMED" if "malformed" in problem else "CD CHILD STILL ALIVE", pre_pair=True)
                    blocked["alarmed"] = True
                save_state(config, state)
                if blocked["alarmed"]:
                    deliver_alarms(config, state)
                if config.get("clear_disable") or config.get("clear_failed"):
                    raise Manual("blocked: " + problem + "; inspect and use --clear-child --reason <text>")
                return
            child_record.unlink()
        if state.pop("child_blocked", None) is not None:
            save_state(config, state)
        if config.get("clear_failed"):
            require(not state["pending"], "pending_refuses_clear_failed")
            target = revision(config["clear_failed"])
            def matches_attempt(key):
                parts = key.removeprefix("trial-").split("-", 1)
                return (len(parts) == 2 and re.fullmatch(r"[0-9a-f]{40}", parts[0])
                        and parts[1] == target)
            state["failed"] = [rev for rev in state["failed"] if rev != target]
            state["attempted"] = {key: entry for key, entry in state["attempted"].items()
                                  if not matches_attempt(key)}
            state.pop("evaluated", None)
            state.setdefault("failed_cleared", []).append({"at": now(), "rev": target, "reason": config["clear_reason"]})
            state["failed_cleared"] = state["failed_cleared"][-200:]
            save_state(config, state)
            # Persist the operator's reason before opening any retry path.
            for path in ledger(config, "attempted", "unused").parent.glob("*.json"):
                if matches_attempt(path.stem):
                    path.unlink()
            for path in ledger(config, "failed", "unused").parent.glob("*.json"):
                if path.stem == target:
                    path.unlink(missing_ok=True)
            return
        if config.get("clear_disable"):
            require(not state["pending"], "pending_refuses_clear_disable")
            if config.get("clear_latch"):
                state.pop("disabled", None)
                cleared = "safety latch"
            elif "operator_stop" in state or disable_marker(config).exists():
                disable_marker(config).unlink(missing_ok=True)
                state.pop("operator_stop", None)
                cleared = "operator stop"
            else:
                require("disabled" not in state, "safety latch present; use --clear-disable --latch --reason <text>")
                cleared = "operator stop (already clear)"
            print("hausnetz-cd: cleared " + cleared, flush=True)
            state["disable_cleared"] = {"at": now(), "reason": config["clear_reason"], "cleared": cleared}
            save_state(config, state)
            return
        if "operator_stop" in state:
            print("hausnetz-cd: operator stop set; operator clear required", flush=True)
            if state["pending"]:
                reconcile(config, state)
            # Acceptance/recovery owns the foreground until reconciliation ends.
            if not state["pending"] or state["pending"].get("phase") == "awaiting_ack":
                deliver_alarms(config, state)
                for key in list(state["reports"]):
                    report(config, state, key)
            if "disabled" not in state:
                return
        if "disabled" in state:
            require(isinstance(state["disabled"], dict), "invalid_disable_latch")
            print("hausnetz-cd: disabled latch set; operator clear required", flush=True)
            deliver_alarms(config, state)
            if not state["disabled"].get("alarmed"):
                for key, entry in state["reports"].items():
                    if (entry["result"].get("run_id") == state["disabled"].get("run_id")
                            and not entry["alarm"]):
                        report(config, state, key)
                        if entry["alarm"]:
                            return
                        break  # a legacy dry-run report still needs CD DISABLED
                prefix = "TEST (no action): " if state["disabled"].get("test") else ""
                key = state["disabled"].setdefault("alarm_id", uuid.uuid4().hex + "-disabled")
                queue_alarm(config, state, key,
                      {"mode": config["mode"], "nixcfg_rev": "unknown", "hausnetz_rev": "unknown"},
                      prefix + "CD DISABLED", pre_pair=True)
                state["disabled"]["alarmed"] = True
                save_state(config, state)
                deliver_alarms(config, state)
            for key in list(state["reports"]):
                report(config, state, key)
            return
        require(config["mode"] in {"dry-run", "live", "rehearse"}, "invalid_mode")
        require(re.fullmatch(r"HNET-[0-9]+", config.get("release_ticket") or ""), "release_ticket_unset")
        alarm_ticket_args(config)
        if config["mode"] == "live":
            require(config.get("secondary_telegram_command"), "independent_alert_path_unset")
        # No executor acceptance window exists while waiting for human ack.
        # Retry its durable notifications before starting the executor.
        if not state["pending"] or state["pending"].get("phase") == "awaiting_ack":
            deliver_alarms(config, state)
        if config["mode"] == "live":
            state.setdefault("attended_remaining", 3)
            require(type(state["attended_remaining"]) is int and 0 <= state["attended_remaining"] <= 3,
                    "invalid_attended_counter")
            save_state(config, state)
        if config.get("rehearsal"):
            require(not state["pending"] or state["pending"].get("rehearsal") == config["rehearsal"],
                    "other_pending_refuses_rehearsal")
        if config.get("manual_dry_run"):
            require(not state["pending"] or state["pending"]["mode"] == "dry-run", "live_pending_refuses_dry_run")
        for key in list(state["reports"]) if not state["pending"] else []:
            if not config.get("manual_dry_run") or state["reports"][key]["result"]["mode"] == "dry-run":
                report(config, state, key)
        if state["pending"]:
            if state["pending"].get("phase") == "awaiting_ack" and not start_pending(config, state):
                return
            reconcile(config, state)
            return
        if config.get("rehearsal"):
            rehearsal_preflight(config)
            if merge_disable(config, state):
                return
            running = evidence(remote(config, "evidence"))
            token = uuid.uuid4().hex
            pending = {"nixcfg_rev": running, "hausnetz_rev": running, "mode": "rehearse",
                       "run_id": token, "run_key": "rehearse-" + token, "rehearsal": config["rehearsal"],
                       "rehearsal_reason": config["rehearsal_reason"],
                       "deadline": time.time() + fixture_limit(config, "poll_timeout", POLL_BUDGET)}
            state["pending"] = pending
            save_state(config, state)
            try:
                remote(config, "rehearse", running, run_id=token, variant=config["rehearsal"], one_shot=uuid.uuid4().hex)
            except Manual:
                pass
            reconcile(config, state)
            return
        # Nothing is a delivery attempt until both hausnetz revisions are known
        # and different. Transport/source failures must remain retryable.
        try:
            repo = cache_repo(directory / "nixcfg.git", config["nixcfg_url"])
            new = revision(git(repo, "rev-parse", "refs/heads/main").strip())
            expected, new_lock = lock_pin(blob(repo, new, "flake.lock"))
            evaluated = state.get("evaluated", {})
            old = evidence(remote(config, "evidence")) if evaluated.get("check_running") else None
            if (evaluated.get("main") == new and time.time() - evaluated.get("at", 0) < 30 * 60
                    and (not evaluated.get("check_running") or evaluated.get("running") == old)
                    and not state.get("pre_pair_failure") and not config.get("manual_dry_run")):
                revision(evaluated["running"])
                return
            old = old or evidence(remote(config, "evidence"))
            cache_repo(repo, config["nixcfg_url"], old, new)
            running = lock_pin(blob(repo, old, "flake.lock"))[0]
            generation = remote(config, "generation", new, run_id=uuid.uuid4().hex).strip()
            require(generation and len(generation) <= 200, "running_generation_unavailable")
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
        key = ("trial-" if config.get("manual_dry_run") else "") + running + "-" + expected
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
            elif result["phase"] == "G5" and result.get("vm_test_reason", "").startswith("vm_test_completed_"):
                result.update(status="failed", reason=result["vm_test_reason"])
                result["gates"]["G5"] = "failed"
            elif result["phase"] == "G5" and config["mode"] == "live":
                result.update(status="vm_test_wait", run_key=key + "-vm-test")
                outage = state.setdefault("vm_test_wait", {"rev": expected, "since": time.time(), "alarmed": False})
                if outage["rev"] != expected:
                    outage = state["vm_test_wait"] = {"rev": expected, "since": time.time(), "alarmed": False}
                if time.time() - outage["since"] >= config.get("vm_test_wait_timeout", 1800) and not outage["alarmed"]:
                    alarm_id = outage.setdefault("alarm_id", uuid.uuid4().hex + "-vm-test")
                    queue_alarm(config, state, alarm_id, result, "VM-TEST WAIT EXCEEDED")
                    outage["alarmed"] = True
                    deliver_alarms(config, state)
            else:
                evaluated_tick()
            result["trial"] = bool(config.get("manual_dry_run"))
            finish(config, state, result)
            return
        state.pop("vm_test_wait", None)
        if config["mode"] == "live":
            acceptance_settings(config)
            if not acceptance_entrypoint(hausnetz, a):
                evaluated_tick()
                finish(config, state, {**result, "status": "preflight_refused",
                                      "reason": "trusted_acceptance_entrypoint_missing", "trial": False})
                return
        pending = {"nixcfg_rev": new, "hausnetz_rev": expected, "mode": config["mode"],
                   "running_nixcfg_rev": old, "trusted_hausnetz_rev": a,
                   "trial": bool(config.get("manual_dry_run")),
                   "run_id": result["run_id"], "run_key": key, "reserved_at": now(), "generation": generation,
                   "expected_version": prepared["version"], "manifest_sha256": prepared["manifest_sha256"],
                   "changed_paths": prepared["changed_paths"], "problems": prepared["problems"],
                   "vm_test": result["gates"]["G5"], "vm_test_reason": result["vm_test_reason"],
                   "deadline": time.time() + fixture_limit(config, "poll_timeout", POLL_BUDGET)}
        state["pending"] = pending
        if merge_disable(config, state):
            finish(config, state, {**pending, "status": "operator_disabled", "phase": "complete",
                                   "completed_at": now(), "reason": "operator_disabled", "operator_disabled": True})
            return
        if config["mode"] == "live" and state["attended_remaining"] > 0:
            pending.update(phase="awaiting_ack", attended_required=True, ack_requested_at=time.time(),
                           ack_deadline=time.time() + 60 * config.get("attended_ack_minutes", 30))
            ack_path = Path(config["state_file"]).parent / ("ack-live-" + pending["run_id"])
            pending["ack_command"] = "printf '%s\\n' " + shlex.quote(pending["run_id"]) + " > " + shlex.quote(str(ack_path))
            pending["reason"] = "attended_ack_required"
            queue_alarm(config, state, pending["run_id"] + "-awaiting-ack", pending, "awaiting attended ack")
            deliver_alarms(config, state)
        if not start_pending(config, state):
            return
        reconcile(config, state)
        if key in state["attempted"]:
            evaluated_tick()


# Nix substitutes this store path before installing the production entrypoint.
CONFIG_FILE = "@CONFIG@"


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("command", nargs="?", choices=["rehearse"])
    parser.add_argument("--variant", choices=["A", "B"])
    parser.add_argument("--disable", action="store_true")
    parser.add_argument("--clear-disable", action="store_true")
    parser.add_argument("--latch", action="store_true")
    parser.add_argument("--clear-child", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--pgid", type=int)
    parser.add_argument("--clear-failed")
    parser.add_argument("--reason")
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--test-alarm", action="store_true")
    args = parser.parse_args()
    clear_failed = args.clear_failed is not None
    if bool(args.command) != bool(args.variant):
        parser.error("rehearse requires --variant A|B")
    reason_command = ("rehearse" if args.command else "--disable" if args.disable else
                      "--clear-disable" if args.clear_disable else "--clear-child" if args.clear_child else
                      "--clear-failed" if clear_failed else None)
    if reason_command:
        try:
            args.reason = operator_reason(args.reason, reason_command)
        except Manual as exc:
            parser.error(str(exc))
    elif args.reason is not None:
        parser.error("--reason requires rehearse, --disable, --clear-disable, --clear-failed or --clear-child")
    if args.latch and not args.clear_disable:
        parser.error("--latch requires --clear-disable")
    if (args.force or args.pgid is not None) and not args.clear_child:
        parser.error("--force and --pgid require --clear-child")
    if args.clear_child and (args.force != (args.pgid is not None)):
        parser.error("forced --clear-child requires both --force and --pgid <group>")
    if sum((bool(args.command), args.clear_disable, args.clear_child, args.test_alarm, args.once or args.dry_run, clear_failed)) > 1:
        parser.error("operator commands cannot be combined")
    if args.disable and (args.command or args.clear_disable or args.clear_child or clear_failed or args.test_alarm or args.once or args.dry_run):
        parser.error("operator commands cannot be combined")
    if args.once != args.dry_run:
        parser.error("manual execution requires both --once and --dry-run")
    try:
        require(not CONFIG_FILE.startswith("@"), "unsubstituted_configuration")
        config = strict_json(Path(CONFIG_FILE).read_bytes())
        if args.disable:
            try:
                atomic_json(disable_marker(config), {"reason": args.reason, "at": now(), "operator": True})
            except OSError:
                raise SystemExit("hausnetz-cd: could not write durable disable marker") from None
            print("hausnetz-cd: disabled by operator; durable stop marker written", flush=True)
            return
        if args.clear_child:
            clear_child(config, args.reason, force=args.force, pgid=args.pgid)
            return
        if args.test_alarm:
            alarm(config, {"mode": "dry-run", "nixcfg_rev": "unknown", "hausnetz_rev": "unknown",
                           "reason": "operator_alarm_test"}, "TEST (no action): CD ALARM", test=True)
            return
        if args.command:
            config = {**config, "enabled": True, "mode": "rehearse", "rehearsal": args.variant,
                      "rehearsal_reason": args.reason}
        if args.clear_disable:
            config = {**config, "enabled": True, "clear_disable": True, "clear_latch": args.latch, "clear_reason": args.reason}
        if clear_failed:
            config = {**config, "enabled": True, "clear_failed": revision(args.clear_failed), "clear_reason": args.reason}
        if args.once:
            config = {**config, "enabled": True, "mode": "dry-run", "manual_dry_run": True}
        tick(config)
    except AlarmRouteUnavailable as exc:
        raise SystemExit("hausnetz-cd: " + str(exc)) from None
    except Manual as exc:
        if (str(exc) == "busy: a tick holds the lock; retry" or str(exc).startswith(("blocked:", "clear-child:", "safety latch present"))
                or str(exc) in {"invalid_disable_latch", "pending_refuses_clear_disable", "pending_refuses_clear_failed"}):
            messages = {"invalid_disable_latch": "invalid safety latch; CD remains disabled",
                        "pending_refuses_clear_disable": "cannot clear disable while a run is pending; reconcile it first",
                        "pending_refuses_clear_failed": "cannot clear failed while a run is pending; reconcile it first"}
            raise SystemExit("hausnetz-cd: " + messages.get(str(exc), str(exc))) from None
        raise SystemExit("hausnetz-cd: manual; configuration, source or evidence unavailable") from None
    except (OSError, KeyError, TypeError, ValueError):
        raise SystemExit("hausnetz-cd: manual; configuration, source or evidence unavailable") from None


if __name__ == "__main__":
    main()
