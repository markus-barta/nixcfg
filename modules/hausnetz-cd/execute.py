"""Detached, root-only executor. The shared flock covers the entire transaction."""

import argparse
import fcntl
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import time
import urllib.parse

from common import (ACK_TIMEOUT, BUILD_TIMEOUT, G3_COMMAND_TIMEOUT, HEALTH_TIMEOUT, Manual, RESULT_SCHEMA,
                    atomic_bytes, atomic_json, cache_repo, coordinate, digest as validate_digest,
                    evidence, gate_closures, gate_g1, gate_units, http_get, now,
                    parse_export, private_dir, require, revision, run,
                    run_id as validate_run_id, strict_json)


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
        pid = run(["systemctl", "show", "hausnetz.service", "--property=MainPID", "--value"],
                  timeout=remaining()).strip()
        require(re.fullmatch(r"[1-9][0-9]*", pid), "hausnetz_pid_missing")
        executable = run(["readlink", "/proc/" + pid + "/exe"], timeout=remaining()).rstrip("\n")
        require(executable == proof["exe"], "health_executable_mismatch")
        return pid

    while time.monotonic() < deadline:
        try:
            pid = process()
            value = strict_json(http_get("http://127.0.0.1:8377/api/meta", remaining()))
            require(isinstance(value, dict) and value.get("version") == proof["version"],
                    "health_version_mismatch")
            require(value.get("capabilities_sha256") == proof["manifest_sha256"],
                    "health_capabilities_mismatch")
            ready = strict_json(http_get("http://127.0.0.1:8377/readyz", remaining()))
            require(isinstance(ready, dict) and ready.get("ok") is True, "health_not_ready")
            require(ready.get("version") == proof["version"], "health_readyz_version_mismatch")
            checks = ready.get("checks")
            require(isinstance(checks, dict) and {"engine", "site", "ui"}.issubset(checks)
                    and all(checks.values()), "health_readyz_checks_failed")
            require(process() == pid and time.monotonic() < deadline, "health_process_changed")
            return True
        except (Manual, KeyError, TypeError):
            time.sleep(min(2, max(0, deadline - time.monotonic())))
    return False


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
        run(["curl", "--disable", "--fail", "--silent", "--noproxy", "*", "--proto", "=https",
             "--max-time", "10", "--config", "-"], data=curl_config, timeout=12)
        return True
    except (Manual, OSError, KeyError):
        return False


def execute(config, new_rev, expected, mode, expected_version, manifest_sha, run_token):
    revision(new_rev)
    revision(expected)
    validate_run_id(run_token)
    require(os.geteuid() == 0 or config.get("fixture_root") is True, "executor_requires_root")
    require(mode in {"dry-run", "live"}, "invalid_mode")
    state = private_dir(config["state_dir"])
    result_path = state / "results" / (run_token + ".json")
    require(not result_path.exists(), "run_already_started")
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
    }

    def save(phase=None):
        if phase:
            result["phase"] = phase
        result["updated_at"] = now()
        atomic_json(result_path, result)

    # A run-scoped starting record precedes lock checks, source access or work.
    save()
    attempt = state / "attempted" / (new_rev + ".json")
    require(not attempt.exists(), "revision_already_attempted")
    with open(config["lock_file"], "r", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            result.update(status="skipped", reason="lock_busy", completed_at=now())
            save("lock")
            return
        require(not attempt.exists(), "revision_already_attempted")
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
            coordinate(expected_version)
            validate_digest(manifest_sha)
            result.update(expected_version=expected_version, manifest_sha256=manifest_sha)
            old_rev = evidence(Path(config["evidence_file"]).read_bytes())
            result["running_nixcfg_rev"] = old_rev
            repo = cache_repo(state / "nixcfg.git", config["nixcfg_url"], old_rev, new_rev)
            save("G1")
            a, b = gate_g1(repo, old_rev, new_rev)
            require(b == expected, "expected_revision_disagrees_with_lock")
            result["old_hausnetz_rev"] = a
            result["gates"]["G1"] = "pass"
            save("G2")
            # The authenticated controller supplies the validated cd-prepare
            # coordinate only after G2 + G4. The app runs on the Mac, never here.
            result["gates"]["G2"] = "pass"
            result["gates"]["G4"] = "pass"
            save("record_previous")
            old_system = str(Path(config["current_system"]).resolve(strict=True))
            require(re.fullmatch(config["store_pattern"], old_system), "invalid_old_system")
            result["old_system"] = old_system
            result["old_generation"] = os.readlink(config["system_profile"])
            require(str(Path(config["system_profile"]).resolve(strict=True)) == old_system,
                    "profile_disagrees_with_running_system")
            result["generation"] = result["old_generation"]
            result["old_proof"] = package_proof(config, old_system)
            if mode == "live":
                credentials = telegram_credentials(config)
                metadata = strict_json(http_get("http://127.0.0.1:8377/api/meta", 5))
                require(isinstance(metadata, dict), "old_metadata_invalid")
                old_manifest = validate_digest(metadata.get("capabilities_sha256"))
                result["old_proof"]["manifest_sha256"] = old_manifest
                require(old_manifest == manifest_sha, "running_manifest_disagrees_with_prepare")
                require(health(config, result["old_proof"]), "old_health_failed")
            save("build")
            target = "git+file://" + str(repo) + "?rev=" + new_rev
            new_system = run(["nix", "build", "--no-link", "--print-out-paths",
                              "--no-update-lock-file", "--max-jobs", "1", "--cores", "2",
                              target + "#nixosConfigurations.hsb0.config.system.build.toplevel"], timeout=BUILD_TIMEOUT).strip()
            require(re.fullmatch(config["store_pattern"], new_system), "invalid_new_system")
            require(Path(new_system, "bin/switch-to-configuration").is_file(), "missing_switch_program")
            result["new_system"] = new_system
            result["new_proof"] = package_proof(config, new_system)
            result["new_proof"]["manifest_sha256"] = manifest_sha
            require(result["new_proof"]["version"] == expected_version, "built_version_disagrees_with_prepare")
            save("G3")
            gate_closures(run(["nix", "store", "diff-closures", old_system, new_system], timeout=G3_COMMAND_TIMEOUT),
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
                save("backup")
                data = http_get("http://127.0.0.1:8377/api/export", 30)
                export_format, digest = parse_export(data)
                atomic_bytes(state / "export", data)
                result.update(backup="ready", export_sha256=digest, export_format=export_format)
                save("backup_ready")
                deadline = time.monotonic() + min(config.get("backup_ack_timeout", ACK_TIMEOUT), ACK_TIMEOUT)
                ack = state / ("ack-" + run_token)
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
                run(["nix-env", "--profile", config["system_profile"], "--set", new_system])
                switching = True
                try:
                    run([new_system + "/bin/switch-to-configuration", "switch"], timeout=None)
                finally:
                    switching = False
                result["generation"] = str(Path(config["system_profile"]).resolve(strict=True))
                save("health")
                require(str(Path(config["current_system"]).resolve(strict=True)) == new_system
                        and evidence(Path(config["evidence_file"]).read_bytes()) == new_rev,
                        "switched_system_evidence_mismatch")
                require(health(config, result["new_proof"]), "expected_health_failed")
                result["health"] = "pass"
                result["status"] = "succeeded"
                result["generation"] = run(["readlink", config["system_profile"]]).strip()
        except Exception as exc:
            result["reason"] = str(exc) if isinstance(exc, Manual) else "input_or_execution_error"
            gate = result["phase"]
            if gate in result["gates"]:
                result["gates"][gate] = "manual"
            result["status"] = "manual"
            if switched:
                result["health"] = "fail"
                result["status"] = "failed"
                result["rollback"] = "failed"
                save("rollback")
                try:
                    run(["nix-env", "--profile", config["system_profile"], "--set", result["old_system"]])
                    switching = True
                    try:
                        run([result["old_system"] + "/bin/switch-to-configuration", "switch"], timeout=None)
                    finally:
                        switching = False
                    require(str(Path(config["current_system"]).resolve(strict=True)) == result["old_system"],
                            "rollback_system_mismatch")
                    require(health(config, result["old_proof"]), "rollback_health_failed")
                    result["rollback"] = "succeeded"
                    result["rollback_health"] = "pass"
                except Exception:
                    result["status"] = "rollback_failed"
                    result["rollback_health"] = "fail"
                message = ("auto-rollback" if result["rollback"] == "succeeded" else "ROLLBACK FAILED")
                message += " hsb0 nixcfg=" + new_rev + " hausnetz=" + expected
                result["telegram"] = "sent" if telegram(credentials, message) else "failed"
            result["generation"] = os.readlink(config["system_profile"]) if Path(config["system_profile"]).is_symlink() else None
        result["completed_at"] = now()
        save("complete")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("nixcfg_rev")
    parser.add_argument("hausnetz_rev")
    parser.add_argument("mode", choices=["dry-run", "live"])
    parser.add_argument("version")
    parser.add_argument("manifest_sha256")
    parser.add_argument("run_id")
    args = parser.parse_args()
    try:
        config = strict_json(Path(args.config).read_bytes())
        execute(config, args.nixcfg_rev, args.hausnetz_rev, args.mode,
                args.version, args.manifest_sha256, args.run_id)
    except (Manual, OSError, KeyError, TypeError, ValueError):
        raise SystemExit("hausnetz-cd: executor refused; inspect root-owned status") from None


if __name__ == "__main__":
    main()
