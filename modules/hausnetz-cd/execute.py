"""Detached, root-only executor. The shared flock covers the entire transaction."""

import argparse
import fcntl
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import urllib.parse

from common import (Manual, RESULT_SCHEMA, atomic_bytes, atomic_json, cache_repo,
                    evidence, gate_closures, gate_g1, gate_g2, gate_units, http_get, now,
                    parse_export, private_dir, require, revision, run, strict_json)


def health(config, rev):
    # Both endpoints are target-local; no redirects, proxies or remote peers.
    for name in ("version_url", "health_url"):
        value = config.get(name)
        parsed = urllib.parse.urlsplit(value or "")
        require(parsed.scheme == "http" and parsed.hostname == "127.0.0.1"
                and parsed.port == 8377 and not parsed.username and not parsed.password
                and not parsed.fragment, "version_or_health_endpoint_unset_or_invalid")
    field = config.get("version_field")
    require(isinstance(field, str) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*", field),
            "version_field_unset_or_invalid")
    deadline = time.monotonic() + min(config.get("health_timeout", 120), 120)
    while time.monotonic() < deadline:
        try:
            remaining = max(0.01, min(5, deadline - time.monotonic()))
            body = http_get(config["version_url"], remaining)
            value = strict_json(body)
            for key in field.split("."):
                value = value[key]
            require(value == rev, "health_revision_mismatch")
            remaining = max(0.01, min(5, deadline - time.monotonic()))
            http_get(config["health_url"], remaining)
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


def execute(config, new_rev, expected, mode):
    revision(new_rev)
    revision(expected)
    require(os.geteuid() == 0 or config.get("fixture_root") is True, "executor_requires_root")
    require(mode in {"dry-run", "live"}, "invalid_mode")
    state = private_dir(config["state_dir"])
    result_path = state / "results" / (new_rev + ".json")

    def unattempted():
        if result_path.exists():
            prior = strict_json(result_path.read_bytes())
            require(prior.get("status") == "skipped", "revision_already_attempted")

    unattempted()
    with open(config["lock_file"], "a", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            unattempted()
            # No attempt has run. A later tick may try again.
            atomic_json(state / "results" / (new_rev + ".json"), {
                "schema": RESULT_SCHEMA, "nixcfg_rev": new_rev, "hausnetz_rev": expected,
                "mode": mode, "status": "skipped", "phase": "lock", "reason": "lock_busy",
                "completed_at": now(), "rollback": "not_required", "gates": {}, "health": "not_run",
            })
            return
        unattempted()
        result = {
            "schema": RESULT_SCHEMA, "host": "hsb0", "action": "hausnetz-cd", "mode": mode,
            "nixcfg_rev": new_rev, "hausnetz_rev": expected, "running_nixcfg_rev": None,
            "old_hausnetz_rev": None, "status": "running", "phase": "preflight",
            "started_at": now(), "updated_at": now(), "completed_at": None,
            "old_system": None, "new_system": None, "old_generation": None, "generation": None,
            "gates": {"G1": "not_run", "G2": "not_run", "G3": "not_run"},
            "health": "not_run", "rollback": "not_required", "rollback_health": "not_run",
            "backup": "not_run", "telegram": "not_required", "reason": None,
        }
        switched = False

        def save(phase=None):
            if phase:
                result["phase"] = phase
            result["updated_at"] = now()
            atomic_json(result_path, result)

        def interrupted(_signum, _frame):
            raise Manual("executor_interrupted")

        signal.signal(signal.SIGTERM, interrupted)
        signal.signal(signal.SIGINT, interrupted)
        save()
        try:
            require(mode != "live" or config.get("allow_live") is True, "live_disabled")
            old_rev = evidence(Path(config["evidence_file"]).read_bytes())
            result["running_nixcfg_rev"] = old_rev
            repo = cache_repo(state / "nixcfg.git", config["nixcfg_url"], old_rev, new_rev)
            save("G1")
            a, b = gate_g1(repo, old_rev, new_rev)
            require(b == expected, "expected_revision_disagrees_with_lock")
            result["old_hausnetz_rev"] = a
            result["gates"]["G1"] = "pass"
            save("G2")
            # Check before any private fetch when the manifest path is absent.
            require(config.get("manifest_path"), "G2_manifest_unset_or_invalid")
            hausnetz = cache_repo(state / "hausnetz.git", config["hausnetz_url"], a, b)
            gate_g2(hausnetz, a, b, config["manifest_path"])
            result["gates"]["G2"] = "pass"
            save("preflight_health")
            # Without the exact-revision endpoint there can be no live switch.
            if mode == "live":
                require(config.get("version_url") and config.get("version_field")
                        and config.get("health_url"), "version_endpoint_unset")
                credentials = telegram_credentials(config)
                require(health(config, a), "old_health_failed")
            save("record_previous")
            old_system = str(Path(config["current_system"]).resolve(strict=True))
            require(re.fullmatch(config["store_pattern"], old_system), "invalid_old_system")
            result["old_system"] = old_system
            result["old_generation"] = os.readlink(config["system_profile"])
            require(str(Path(config["system_profile"]).resolve(strict=True)) == old_system,
                    "profile_disagrees_with_running_system")
            result["generation"] = result["old_generation"]
            save("build")
            target = "git+file://" + str(repo) + "?rev=" + new_rev
            new_system = run(["nix", "build", "--no-link", "--print-out-paths",
                              "--no-update-lock-file", "--max-jobs", "1", "--cores", "2",
                              target + "#nixosConfigurations.hsb0.config.system.build.toplevel"], timeout=600).strip()
            require(re.fullmatch(config["store_pattern"], new_system), "invalid_new_system")
            require(Path(new_system, "bin/switch-to-configuration").is_file(), "missing_switch_program")
            result["new_system"] = new_system
            save("G3")
            gate_closures(run(["nix", "store", "diff-closures", old_system, new_system]),
                          old_system, new_system)
            # dry-activate diagnostics are part of the gate, not discarded.
            activation = subprocess.run([new_system + "/bin/switch-to-configuration", "dry-activate"],
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                        text=True, timeout=60, check=False)
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
                deadline = time.monotonic() + min(config.get("backup_ack_timeout", 120), 120)
                ack = state / ("ack-" + new_rev)
                while not ack.exists() and time.monotonic() < deadline:
                    time.sleep(min(1, max(0, deadline - time.monotonic())))
                require(ack.is_file() and ack.read_text().strip() == digest, "backup_copy_not_acknowledged")
                result["backup"] = "copied"
                save("switch")
                # Set this before invoking switch: a nonzero switch can have
                # partially activated the new generation and needs recovery.
                switched = True
                run(["nix-env", "--profile", config["system_profile"], "--set", new_system])
                run([new_system + "/bin/switch-to-configuration", "switch"], timeout=120)
                result["generation"] = str(Path(config["system_profile"]).resolve(strict=True))
                save("health")
                require(str(Path(config["current_system"]).resolve(strict=True)) == new_system
                        and evidence(Path(config["evidence_file"]).read_bytes()) == new_rev,
                        "switched_system_evidence_mismatch")
                require(health(config, expected), "expected_health_failed")
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
                    run([result["old_system"] + "/bin/switch-to-configuration", "switch"], timeout=120)
                    require(str(Path(config["current_system"]).resolve(strict=True)) == result["old_system"],
                            "rollback_system_mismatch")
                    require(health(config, result["old_hausnetz_rev"]), "rollback_health_failed")
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
    args = parser.parse_args()
    try:
        config = strict_json(Path(args.config).read_bytes())
        execute(config, args.nixcfg_rev, args.hausnetz_rev, args.mode)
    except (Manual, OSError, KeyError, TypeError, ValueError):
        raise SystemExit("hausnetz-cd: executor refused; inspect root-owned status") from None


if __name__ == "__main__":
    main()
