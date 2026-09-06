"""Run Pi in the caller's terminal, sharing one localhost MTPLX server."""

import errno
import fcntl
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

BASE_URL = "http://127.0.0.1:8000"


def health():
    # Do not send even localhost traffic through an inherited HTTP proxy.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(BASE_URL + "/health", timeout=2) as response:
            result = json.load(response)
        if not isinstance(result, dict) or result.get("ok") is not True:
            raise RuntimeError("Port 8000 is occupied by a service that is not ready MTPLX.")
        return result
    except urllib.error.URLError as error:
        if isinstance(error.reason, OSError) and error.reason.errno == errno.ECONNREFUSED:
            return None
        raise RuntimeError("Port 8000 is occupied or unresponsive; no second server was started.") from error
    except (ValueError, TimeoutError) as error:
        raise RuntimeError("Port 8000 did not return MTPLX health; no second server was started.") from error


def validate_server(info, config):
    expected = {
        "model": config["modelId"],
        "context_window": config["contextWindow"],
        "generation_mode": "mtp",
        "mtp_enabled": True,
        "depth": 2,
    }
    mismatches = [key for key, value in expected.items() if info.get(key) != value]
    if mismatches or info.get("api_key_required"):
        raise RuntimeError(
            "Existing MTPLX settings differ (" + ", ".join(mismatches or ["API authentication"])
            + "). In MTPLX select Qwen 3.8 27B Optimized Speed, MTP D2, 262144 context, "
            "or stop the engine there and retry pi-local. The running server was left alone."
        )


def server_command(config):
    return [
        config["mtplx"], "serve", "--model", config["modelPath"],
        "--model-id", config["modelId"], "--host", "127.0.0.1", "--port", "8000",
        "--context-window", str(config["contextWindow"]), "--mtp", "--depth", "2",
        "--profile", "turbo", "--reasoning-effort", "medium", "--fan-mode", "smart",
        "--ssd-session-cache", "off", "--paged-kv-quantization", "off",
        "--scheduler-mode", "serial", "--batching-preset", "solo", "--no-stats-footer",
    ]


def ensure_server(config, state_dir, timeout=240):
    state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Lock only startup; separate Pi sessions can share the already-running server.
    with (state_dir / "startup.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        info = health()
        if info is not None:
            validate_server(info, config)
            return
        if not Path(config["modelPath"]).is_dir():
            raise RuntimeError("The configured Qwen model is missing. Install it in MTPLX first.")
        # A listener without a valid /health response must never get a second model.
        with socket.socket() as probe:
            try:
                probe.bind(("127.0.0.1", 8000))
            except OSError as error:
                raise RuntimeError("Port 8000 is already in use; wait for MTPLX or stop it in the app.") from error
        log_path = state_dir / "server.log"
        print("pi-local: loading Qwen with MTP D2 / 262K …", file=sys.stderr)
        with log_path.open("w") as log:
            process = subprocess.Popen(
                server_command(config), stdin=subprocess.DEVNULL, stdout=log,
                stderr=subprocess.STDOUT, start_new_session=True, cwd=str(Path.home()),
            )
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError(f"MTPLX startup failed. Details: {log_path}")
            try:
                info = health()
            except RuntimeError:
                info = None  # The child may have bound its port during warmup.
            if info is not None:
                validate_server(info, config)
                return
            time.sleep(1)
        # Keep ownership narrow: terminate only the child this invocation started.
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        raise RuntimeError(f"MTPLX did not become ready within {timeout}s. Details: {log_path}")


def pi_command(config, args):
    return [
        config["pi"], "--offline", "--provider", "mtplx", "--model", config["modelId"],
        "--thinking", "medium", "--extension", config["extension"], *args,
    ]


def main():
    with open(sys.argv[1], encoding="utf-8") as source:
        config = json.load(source)
    args = sys.argv[2:]
    if not os.access(config["pi"], os.X_OK):
        raise RuntimeError("Pi is missing; run just update-ai-clis in nixcfg.")
    if not any(arg in ("--help", "-h", "--version", "-v") for arg in args):
        if not os.access(config["mtplx"], os.X_OK):
            raise RuntimeError("MTPLX CLI is missing; install its CLI from the MTPLX app.")
        ensure_server(config, Path.home() / ".local/state/pi-local")
    os.environ["PI_CODING_AGENT_DIR"] = config["agentDir"]
    os.environ["PI_TELEMETRY"] = "0"
    # exec inherits cwd, terminal, signals and exit status. No new Terminal window.
    os.execv(config["pi"], pi_command(config, args))


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        print(f"pi-local: {error}", file=sys.stderr)
        sys.exit(1)
