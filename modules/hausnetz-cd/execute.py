"""Detached, root-only executor. The shared flock covers the entire transaction."""

import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import time
import urllib.parse

from common import (ACCEPTANCE_TIMEOUT, ACK_TIMEOUT, BUILD_TIMEOUT, G3_COMMAND_TIMEOUT, HEALTH_TIMEOUT, Manual, RESULT_SCHEMA,
                    atomic_bytes, atomic_json, blob, cache_repo, coordinate, digest as validate_digest,
                    evidence, gate_closures, gate_g1, gate_units, http_get, now,
                    lock_pin, parse_export, private_dir, require, revision, run,
                    run_id as validate_run_id, state_path, strict_json)


def package_proof(config, system):
    unit = Path(system, "etc/systemd/system/hausnetz.service").read_text()
    commands = re.findall(r"(?m)^ExecStart=(.+)$", unit)
    require(len(commands) == 1, "hausnetz_exec_start_missing_or_ambiguous")
    command = shlex.split(commands[0])
    require(command, "hausnetz_exec_start_missing_or_ambiguous")
    pattern = config.get("package_pattern", r"/nix/store/[0-9a-z]{32}-hausnetz-([^/]+)/bin/hausnetz")
    match = re.fullmatch(pattern, command[0])
    require(match is not None, "hausnetz_exec_start_not_a_package")
    version = coordinate(match[1])
    executable = str(Path(command[0]).resolve(strict=True))
    require(Path(executable).is_file(), "hausnetz_binary_unreadable")
    return {"exe": executable, "version": version}


def health(config, proof):
    require(config.get("require_readyz", True) is True, "readyz_required_for_live")
    deadline = time.monotonic() + min(config.get("health_timeout", HEALTH_TIMEOUT), HEALTH_TIMEOUT)

    def remaining():
        value = min(5, deadline - time.monotonic())
        require(value > 0, "health_deadline")
        return value

    def process():
        pid = run("systemctl", ["show", "hausnetz.service", "--property=MainPID", "--value"],
                  timeout=remaining()).strip()
        require(re.fullmatch(r"[1-9][0-9]*", pid), "hausnetz_pid_missing")
        executable = run("readlink", ["/proc/" + pid + "/exe"], timeout=remaining()).rstrip("\n")
        require(executable == proof["exe"], "health_executable_mismatch")
        return pid

    while time.monotonic() < deadline:
        try:
            if "revision" in proof:
                require(revision(proof.get("expected_revision")) == revision(proof["revision"]),
                        "health_revision_mismatch")
            pid = process()
            value = strict_json(http_get("http://127.0.0.1:8377/api/meta", remaining()))
            require(isinstance(value, dict) and value.get("version") == proof["version"],
                    "health_version_mismatch")
            require(value.get("capabilities_sha256") == proof["manifest_sha256"],
                    "health_capabilities_mismatch")
            capabilities = http_get("http://127.0.0.1:8377/api/host-capabilities", remaining())
            # Both the metadata and exact body must independently match the
            # trusted prepare digest, which also proves they match each other.
            require(hashlib.sha256(capabilities).hexdigest() == proof["manifest_sha256"],
                    "health_capabilities_body_mismatch")
            ready = strict_json(http_get("http://127.0.0.1:8377/readyz", remaining()))
            require(isinstance(ready, dict) and ready.get("ok") is True, "health_not_ready")
            require(ready.get("version") == proof["version"], "health_readyz_version_mismatch")
            checks = ready.get("checks")
            require(isinstance(checks, dict) and set(checks) == {"instance", "engine", "site", "ui"}
                    and all(value is True for value in checks.values()), "health_readyz_checks_failed")
            require(process() == pid and time.monotonic() < deadline, "health_process_changed")
            return True
        except (Manual, KeyError, TypeError):
            time.sleep(min(2, max(0, deadline - time.monotonic())))
    return False


def rehearsal_readback(config):
    """Fail closed unless both boot configuration and service identity are readable."""
    profile = config["system_profile"]
    generations = run("nix-env", ["--profile", profile, "--list-generations"]).strip()
    require(generations, "rehearsal_generations_unreadable")
    # grub.cfg contains its configured default and entries; grubenv contains any
    # saved/next default. systemd-boot additionally exposes EFI overrides below.
    boot = Path(config.get("boot_dir", "/boot"))
    files = [boot / "grub/grub.cfg", boot / "grub/grubenv", boot / "loader/loader.conf"]
    files += sorted((boot / "loader/entries").glob("*.conf"))
    entries = {str(path.relative_to(boot)): hashlib.sha256(path.read_bytes()).hexdigest()
               for path in files if path.exists()}
    require("grub/grub.cfg" in entries or (
        "loader/loader.conf" in entries and any(k.startswith("loader/entries/") for k in entries)),
        "rehearsal_boot_unreadable")
    defaults = None
    if "grub/grub.cfg" in entries:
        text = (boot / "grub/grub.cfg").read_text()
        assignments = re.findall(r"(?m)^[ \t]*set default=(.+)$", text)
        menu = re.findall(r"(?m)^[ \t]*(?:menuentry|submenu) .+$", text)
        require(assignments and menu, "rehearsal_boot_default_unreadable")
        environment = None
        if "grub/grubenv" in entries:
            environment = (boot / "grub/grubenv").read_text()
        require(not any("saved" in value or "next_entry" in value for value in assignments)
                or environment, "rehearsal_boot_saved_default_unreadable")
        defaults = {"assignments": assignments, "menu_entries": menu,
                    "environment": re.findall(r"(?m)^(?:saved_entry|next_entry)=[^\n]*$", environment or "")}
    if "loader/loader.conf" in entries:
        defaults = run("bootctl", ["--no-pager", "status"], timeout=15)
        require(defaults.strip(), "rehearsal_boot_default_unreadable")
    pid = run("systemctl", ["show", "hausnetz.service", "--property=MainPID", "--value"]).strip()
    invocation = run("systemctl", ["show", "hausnetz.service", "--property=InvocationID", "--value"]).strip()
    require(re.fullmatch(r"[1-9][0-9]*", pid) and re.fullmatch(r"[0-9a-f]{32}", invocation),
            "rehearsal_service_identity_unreadable")
    return {"generations": generations, "current_system": str(Path(config["current_system"]).resolve(strict=True)),
            "profile": os.readlink(profile), "boot_entries": entries, "boot_default": defaults,
            "MainPID": pid, "InvocationID": invocation}


def rehearsal_units(text):
    chatter = {"dry activating the configuration...", "would activate the configuration...",
               "would run sysinit-reactivation", "setting up /etc..."}
    require(all(not line.strip() or line in chatter for line in text.splitlines()),
            "rehearsal_activation_not_empty")


def await_acceptance(config, state, token):
    deadline = time.monotonic() + config.get("acceptance_timeout", ACCEPTANCE_TIMEOUT) + 60
    decision = state_path(state / ("acceptance-" + token))
    while not decision.exists() and time.monotonic() < deadline:
        time.sleep(min(1, max(0, deadline - time.monotonic())))
    require(decision.is_file() and decision.read_text().strip() == "pass", "acceptance_failed_or_timeout")


def telegram_credentials(config):
    # Explicitly authorized runtime-only access. Never pass the credential
    # in argv, diagnostics, status JSON, exports, or the orchestrator.
    lines = Path(config["telegram_file"]).read_text().splitlines()
    require(len(lines) == 2 and re.fullmatch(r"[0-9]+:[A-Za-z0-9_-]+", lines[0])
            and re.fullmatch(r"-?[0-9]+", lines[1]), "telegram_credential_format")
    return lines


def telegram(lines, message):
    try:
        data = urllib.parse.urlencode({"chat_id": lines[1], "text": message})
        curl_config = 'url = "https://api.telegram.org/bot' + lines[0] + '/sendMessage"\n'
        curl_config += 'data = "' + data + '"\n'
        run("curl", ["--disable", "--fail", "--silent", "--noproxy", "*", "--proto", "=https",
             "--max-time", "10", "--config", "-"], data=curl_config, timeout=12)
        return True
    except (Manual, OSError, KeyError):
        return False


def execute(config, new_rev, expected, mode, expected_version, manifest_sha, gated_running, run_token, *, rehearsal=None, one_shot=None, trial=False):
    revision(new_rev)
    revision(expected)
    revision(gated_running)
    validate_run_id(run_token)
    require(os.geteuid() == 0 or config.get("fixture_root") is True, "executor_requires_root")
    require(mode in {"dry-run", "live", "rehearse"}, "invalid_mode")
    require(not trial or mode == "dry-run", "trial_requires_dry_run")
    state = private_dir(config["state_dir"])
    result_path = state_path(state / "results" / (run_token + ".json"))
    result = {
        "schema": RESULT_SCHEMA, "host": "hsb0", "action": "hausnetz-cd", "mode": mode,
        "run_id": run_token, "nixcfg_rev": new_rev, "hausnetz_rev": expected,
        "running_nixcfg_rev": None, "old_hausnetz_rev": None,
        "status": "running", "phase": "starting",
        "started_at": now(), "updated_at": now(), "completed_at": None,
        "old_system": None, "new_system": None, "old_generation": None, "generation": None,
        "gates": {"G1": "not_run", "G2": "not_run", "G3": "not_run", "G4": "not_run"},
        "health": "not_run", "rollback": "not_required", "rollback_health": "not_run",
        "backup": "not_run", "telegram": "not_required", "reason": None,
        "memory_peak_bytes": None, "acceptance": "not_run",
        "rehearsal": rehearsal,
    }

    def save(phase=None):
        if phase:
            result["phase"] = phase
        result["updated_at"] = now()
        atomic_json(result_path, result)

    def refuse(reason, path=None):
        result.update(status="manual", phase="complete", reason=reason, completed_at=now(), updated_at=now())
        atomic_json(path or result_path, result)
        raise Manual(reason)

    if result_path.exists():
        # Preserve the original run's evidence, including a possibly active
        # transaction. The duplicate invocation gets its own terminal refusal.
        refuse("run_already_started", state_path(state / "refusals" / (run_token + ".json")))
    # A run-scoped starting record precedes lock checks, source access or work.
    save()
    attempt = state_path(state / "attempted" / (new_rev + ".json"))
    if mode != "rehearse" and not trial and attempt.exists():
        refuse("revision_already_attempted")
    try:
        lock_file = open(config["lock_file"], "r", encoding="utf-8")
    except OSError:
        refuse("deploy_lock_missing_or_unreadable")
    with lock_file as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            result.update(status="skipped", reason="lock_busy", completed_at=now())
            save("lock")
            return
        if mode != "rehearse" and not trial and attempt.exists():
            refuse("revision_already_attempted")
        if mode != "rehearse" and not trial:
            atomic_json(attempt, {"run_id": run_token, "at": now()})
        switched = False
        switching = False

        def interrupted(_signum, _frame):
            if switching:
                # systemd sends TERM only to this process (KillMode=process).
                # Keep the lock and wait for activation; never race rollback
                # against it, and never SIGKILL switch-to-configuration.
                result["reason"] = "switch_status_unknown"
                save("switch_unknown")
                return
            raise Manual("executor_interrupted")

        signal.signal(signal.SIGTERM, interrupted)
        signal.signal(signal.SIGINT, interrupted)
        save("preflight")
        try:
            require(mode != "live" or config.get("allow_live") is True, "live_disabled")
            require(mode != "live" or config.get("require_readyz", True) is True, "readyz_required_for_live")
            if mode == "rehearse":
                require(rehearsal in {"A", "B"}, "rehearsal_variant")
                validate_run_id(one_shot)
                token_file = state_path(state / ("rehearsal-token-" + run_token))
                require(token_file.is_file() and token_file.read_text().strip() == one_shot,
                        "rehearsal_token_missing_or_mismatch")
                token_file.unlink()  # consume once while holding the deploy lock
                require(new_rev == gated_running and expected == gated_running,
                        "rehearsal_real_target_forbidden")
            coordinate(expected_version)
            validate_digest(manifest_sha)
            result.update(expected_version=expected_version, manifest_sha256=manifest_sha)
            old_rev = evidence(Path(config["evidence_file"]).read_bytes())
            require(old_rev == gated_running, "running_baseline_changed")
            result["running_nixcfg_rev"] = old_rev
            if mode != "rehearse":
                repo = cache_repo(state / "nixcfg.git", config["nixcfg_url"], old_rev, new_rev)
                save("G1")
                a, b = gate_g1(repo, old_rev, new_rev)
                require(b == expected, "expected_revision_disagrees_with_lock")
                result["old_hausnetz_rev"] = a
                result["gates"]["G1"] = "pass"
                save("G2")
                # The authenticated controller supplies the validated cd-prepare
                # coordinate only after G2 + G4. The app runs on the Mac, never here.
                result["gates"]["G2"] = "controller_evidence"
                result["gates"]["G4"] = "controller_evidence"
                result["controller_evidence"] = {
                    "running_nixcfg_rev": gated_running, "hausnetz_rev": expected,
                    "version": expected_version, "manifest_sha256": manifest_sha,
                }
            else:
                # Resolve only the running source pin, never a rehearsal target.
                repo = cache_repo(state / "nixcfg.git", config["nixcfg_url"], old_rev)
                a = lock_pin(blob(repo, old_rev, "flake.lock"))[0]
                result["old_hausnetz_rev"] = a
            save("record_previous")
            old_system = str(Path(config["current_system"]).resolve(strict=True))
            require(re.fullmatch(config["store_pattern"], old_system), "invalid_old_system")
            result["old_system"] = old_system
            result["old_generation"] = os.readlink(config["system_profile"])
            require(str(Path(config["system_profile"]).resolve(strict=True)) == old_system,
                    "profile_disagrees_with_running_system")
            # Indirect roots protect both systems from concurrent external GC.
            # Keep the bounded pair of roots after completion for inspection;
            # only a later transaction holding this lock may replace them.
            run("nix-store", ["--add-root", state / "old-system", "--indirect", "--realise", old_system])
            result["generation"] = result["old_generation"]
            result["old_proof"] = {**package_proof(config, old_system), "revision": a, "expected_revision": a}
            if mode in {"live", "rehearse"}:
                credentials = telegram_credentials(config)
                metadata = strict_json(http_get("http://127.0.0.1:8377/api/meta", 5))
                require(isinstance(metadata, dict), "old_metadata_invalid")
                old_manifest = validate_digest(metadata.get("capabilities_sha256"))
                result["old_proof"]["manifest_sha256"] = old_manifest
                if mode == "rehearse":
                    manifest_sha = old_manifest
                    result["manifest_sha256"] = old_manifest
                require(old_manifest == manifest_sha, "running_manifest_disagrees_with_prepare")
                require(health(config, result["old_proof"]), "old_health_failed")
            if mode == "rehearse":
                result["readback_before"] = rehearsal_readback(config)
                new_system = old_system
                result["new_system"] = new_system
                result["new_proof"] = {**result["old_proof"], "expected_revision": "0" * 40}
                require(a != "0" * 40, "rehearsal_invalid_running_revision")
                if rehearsal == "B":
                    result["old_proof"] = {**result["old_proof"], "expected_revision": "0" * 40}
                save("G3")
                require(str(Path(new_system).resolve(strict=True)) == str(Path(config["current_system"]).resolve(strict=True)),
                        "rehearsal_target_not_current")
                activation = subprocess.run([new_system + "/bin/switch-to-configuration", "dry-activate"],
                                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                            text=True, timeout=G3_COMMAND_TIMEOUT, check=False)
                require(activation.returncode == 0, "G3_dry_activate_failed")
                rehearsal_units(activation.stdout)
                require(rehearsal_readback(config) == result["readback_before"], "rehearsal_pre_switch_changed")
            else:
                save("build")
                target = "git+file://" + str(repo) + "?rev=" + new_rev
                new_system = run("nix", ["build", "--out-link", state / "new-system", "--print-out-paths",
                                  "--no-update-lock-file", "--max-jobs", "1", "--cores", "2",
                                  target + "#nixosConfigurations.hsb0.config.system.build.toplevel"], timeout=BUILD_TIMEOUT).strip()
                require(re.fullmatch(config["store_pattern"], new_system), "invalid_new_system")
                require(Path(new_system, "bin/switch-to-configuration").is_file(), "missing_switch_program")
                result["new_system"] = new_system
                result["new_proof"] = {**package_proof(config, new_system), "revision": b, "expected_revision": expected}
                result["new_proof"]["manifest_sha256"] = manifest_sha
                require(result["new_proof"]["version"] == expected_version, "built_version_disagrees_with_prepare")
                save("G3")
                gate_closures(run("nix", ["store", "diff-closures", old_system, new_system],
                                  timeout=G3_COMMAND_TIMEOUT, binary=True).decode("utf-8"),
                              old_system, new_system)
                # dry-activate diagnostics are part of the gate, not discarded.
                activation = subprocess.run([new_system + "/bin/switch-to-configuration", "dry-activate"],
                                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                            text=True, timeout=G3_COMMAND_TIMEOUT, check=False)
                require(activation.returncode == 0, "G3_dry_activate_failed")
                gate_units(activation.stdout)
            require(evidence(Path(config["evidence_file"]).read_bytes()) == old_rev
                    and str(Path(config["current_system"]).resolve(strict=True)) == old_system,
                    "running_system_changed")
            result["gates"]["G3"] = "pass"
            if mode == "dry-run":
                result["status"] = "dry-run"
                result["would"] = ["export", "copy_export", "switch", "verify_expected_revision", "rollback_on_failure"]
            else:
                if mode == "live":
                    live_ack = state_path(state / ("ack-live-" + run_token))
                    require(live_ack.is_file() and live_ack.read_text().strip() == run_token, "attended_ack_missing")
                if mode == "live":
                    save("backup")
                    data = http_get("http://127.0.0.1:8377/api/export", 30)
                    export_format, digest = parse_export(data)
                    atomic_bytes(state / "export", data)
                    result.update(backup="ready", export_sha256=digest, export_format=export_format)
                    save("backup_ready")
                    deadline = time.monotonic() + min(config.get("backup_ack_timeout", ACK_TIMEOUT), ACK_TIMEOUT)
                    ack = state_path(state / ("ack-" + run_token))
                    while not ack.exists() and time.monotonic() < deadline:
                        time.sleep(min(1, max(0, deadline - time.monotonic())))
                    require(ack.is_file() and ack.read_text().strip() == digest, "backup_copy_not_acknowledged")
                    result["backup"] = "copied"
                require(evidence(Path(config["evidence_file"]).read_bytes()) == old_rev
                        and str(Path(config["current_system"]).resolve(strict=True)) == old_system
                        and str(Path(config["system_profile"]).resolve(strict=True)) == old_system,
                        "running_system_changed_before_switch")
                save("switch")
                # Set this before invoking switch: a nonzero switch can have
                # partially activated the new generation and needs recovery.
                switched = True
                if mode != "rehearse":
                    run("nix-env", ["--profile", config["system_profile"], "--set", new_system])
                switching = True
                try:
                    run(new_system + "/bin/switch-to-configuration", ["switch"], timeout=None)
                finally:
                    switching = False
                result["generation"] = str(Path(config["system_profile"]).resolve(strict=True))
                if mode == "rehearse":
                    result["readback_after_switch"] = rehearsal_readback(config)
                    require(result["readback_after_switch"] == result["readback_before"], "rehearsal_switch_changed")
                save("health")
                require(str(Path(config["current_system"]).resolve(strict=True)) == new_system
                        and evidence(Path(config["evidence_file"]).read_bytes()) == new_rev,
                        "switched_system_evidence_mismatch")
                require(health(config, result["new_proof"]), "expected_health_failed")
                require(mode != "rehearse", "rehearsal_health_unexpectedly_passed")
                result["health"] = "pass"
                save("acceptance_ready")
                result["acceptance"] = "fail"
                await_acceptance(config, state, run_token)
                result["acceptance"] = "pass"
                result["status"] = "succeeded"
                result["generation"] = run("readlink", [config["system_profile"]]).strip()
        except Exception as exc:
            result["reason"] = str(exc) if isinstance(exc, Manual) else "input_or_execution_error"
            gate = result["phase"]
            if gate in result["gates"]:
                result["gates"][gate] = "manual"
            result["status"] = "manual"
            rehearsal_changed = mode == "rehearse" and result["reason"].startswith("rehearsal_")
            if mode == "rehearse" and not switched:
                result["status"] = "rehearsal_aborted"
            if rehearsal_changed:
                result["status"] = "rehearsal_aborted"
            if switched and not rehearsal_changed:
                result["health"] = "fail"
                result["status"] = "failed"
                result["rollback"] = "failed"
                save("rollback")
                try:
                    if mode != "rehearse":
                        run("nix-env", ["--profile", config["system_profile"], "--set", result["old_system"]])
                    else:
                        require(str(Path(config["current_system"]).resolve(strict=True)) == result["old_system"],
                                "rehearsal_changed_before_rollback")
                        check = subprocess.run([result["old_system"] + "/bin/switch-to-configuration", "dry-activate"],
                                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                               text=True, timeout=G3_COMMAND_TIMEOUT, check=False)
                        require(check.returncode == 0, "rehearsal_rollback_dry_activate_failed")
                        rehearsal_units(check.stdout)
                        require(rehearsal_readback(config) == result["readback_before"], "rehearsal_changed_before_rollback")
                    switching = True
                    try:
                        run(result["old_system"] + "/bin/switch-to-configuration", ["switch"], timeout=None)
                    finally:
                        switching = False
                    require(str(Path(config["current_system"]).resolve(strict=True)) == result["old_system"],
                            "rollback_system_mismatch")
                    require(health(config, result["old_proof"]), "rollback_health_failed")
                    result["rollback"] = "succeeded"
                    result["rollback_health"] = "pass"
                    if mode == "rehearse":
                        result["status"] = "rolled_back"
                except Exception as rollback_exc:
                    result["status"] = "rollback_failed"
                    if mode == "rehearse" and isinstance(rollback_exc, Manual) and str(rollback_exc).startswith("rehearsal_"):
                        result.update(status="rehearsal_aborted", reason=str(rollback_exc))
                    result["rollback_health"] = "fail"
                message = ("auto-rollback" if result["rollback"] == "succeeded" else "ROLLBACK FAILED")
                if mode == "rehearse":
                    message = "TEST (no action): " + message
                message += " hsb0 nixcfg=" + new_rev + " hausnetz=" + expected
                result["telegram"] = "sent" if telegram(credentials, message) else "failed"
            result["generation"] = os.readlink(config["system_profile"]) if Path(config["system_profile"]).is_symlink() else None
        if mode == "rehearse":
            try:
                result["readback_after"] = rehearsal_readback(config)
                require(result.get("readback_before") == result["readback_after"], "rehearsal_readback_changed")
            except Exception:
                result.update(status="rehearsal_aborted", reason=result.get("reason") or "rehearsal_readback_changed_or_unavailable")
        if mode == "dry-run":
            try:
                peak = run("systemctl", ["show", "hausnetz-cd-" + run_token + ".service",
                           "--property=MemoryPeak", "--value"]).strip()
                require(re.fullmatch(r"[0-9]{1,20}", peak) and 0 < int(peak) < 2**64 - 1,
                        "memory_peak_unavailable")
                result["memory_peak_bytes"] = int(peak)
            except Manual:
                result["memory_peak_reason"] = "systemd_memory_peak_unavailable"
        result["completed_at"] = now()
        save("complete")


# Nix substitutes this store path before installing the production entrypoint.
CONFIG_FILE = "@CONFIG@"


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    if sys.argv[1:2] == ["rehearse"]:
        parser.add_argument("command", choices=["rehearse"])
        parser.add_argument("--variant", choices=["A", "B"], required=True)
        parser.add_argument("--token", required=True)
        parser.add_argument("--run-id", required=True)
        args = parser.parse_args()
        try:
            require(not CONFIG_FILE.startswith("@"), "unsubstituted_configuration")
            config = strict_json(Path(CONFIG_FILE).read_bytes())
            running = evidence(Path(config["evidence_file"]).read_bytes())
            proof = package_proof(config, str(Path(config["current_system"]).resolve(strict=True)))
            execute(config, running, running, "rehearse", proof["version"], "0" * 64, running,
                    args.run_id, rehearsal=args.variant, one_shot=args.token)
            return
        except (Manual, OSError, KeyError, TypeError, ValueError):
            raise SystemExit("hausnetz-cd: rehearsal refused; inspect root-owned status") from None
    parser.add_argument("--trial", action="store_true")
    parser.add_argument("nixcfg_rev")
    parser.add_argument("hausnetz_rev")
    parser.add_argument("mode", choices=["dry-run", "live"])
    parser.add_argument("version")
    parser.add_argument("manifest_sha256")
    parser.add_argument("running_nixcfg_rev")
    parser.add_argument("run_id")
    args = parser.parse_args()
    try:
        require(not CONFIG_FILE.startswith("@"), "unsubstituted_configuration")
        config = strict_json(Path(CONFIG_FILE).read_bytes())
        execute(config, args.nixcfg_rev, args.hausnetz_rev, args.mode,
                args.version, args.manifest_sha256, args.running_nixcfg_rev, args.run_id, trial=args.trial)
    except (Manual, OSError, KeyError, TypeError, ValueError):
        raise SystemExit("hausnetz-cd: executor refused; inspect root-owned status") from None


if __name__ == "__main__":
    main()
