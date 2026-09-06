"""Run Pi against the MTPLX app's engine, in the caller's terminal."""

import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.request

# Home Manager substitutes this literal. Executable paths never come from argv.
CONFIG_JSON = "@PI_LOCAL_CONFIG@"


def app_endpoint():
    """Read only connection metadata; never copy app credentials into Pi."""
    settings_file = Path.home() / "Library/Application Support/MTPLX/settings.json"
    try:
        settings = json.loads(settings_file.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise RuntimeError("Open MTPLX and finish its setup first.") from error
    port = settings.get("port", 8000)
    if type(port) is not int or not 1 <= port <= 65535:
        raise RuntimeError("MTPLX has an invalid server port.")
    if settings.get("host", "127.0.0.1") not in ("127.0.0.1", "localhost", "0.0.0.0"):
        raise RuntimeError("pi-local requires MTPLX on this Mac's IPv4 loopback.")
    return f"http://127.0.0.1:{port}"


def health(endpoint):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(endpoint + "/health", timeout=2) as response:
            result = json.load(response)
        return result if isinstance(result, dict) and result.get("ok") is True else None
    except (urllib.error.URLError, OSError, ValueError):
        return None


def connection(info, endpoint):
    startup = info.get("startup") or {}
    if not startup.get("launch_id") or not startup.get("app_parent_pid"):
        raise RuntimeError(
            "This MTPLX server was started outside the app. Stop that server, "
            "then start the engine in MTPLX. pi-local never starts a separate engine."
        )
    if info.get("api_key_required") or startup.get("api_key_required"):
        raise RuntimeError("The app engine requires authentication; pi-local is configured for local no-auth access.")
    model = info.get("model")
    context = info.get("context_window")
    if not isinstance(model, str) or not model or type(context) is not int or context < 4096:
        raise RuntimeError("MTPLX did not report valid model/context metadata.")
    return {"baseUrl": endpoint + "/v1", "model": model, "contextWindow": context}


def ensure_server(state_dir, timeout=120):
    state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (state_dir / "startup.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        endpoint = app_endpoint()
        info = health(endpoint)
        if info is not None:
            return connection(info, endpoint)
        print(
            "pi-local: opening MTPLX and waiting for its engine. "
            "If the app is already open with the engine stopped, press Start there.",
            file=sys.stderr,
        )
        # The app owns startup, saved settings and telemetry. No `mtplx serve`,
        # fan override, process termination, or independent model download here.
        subprocess.run(["/usr/bin/open", "-g", "-a", "/Applications/MTPLX.app"], check=True)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            endpoint = app_endpoint()  # The app may choose a different free port.
            info = health(endpoint)
            if info is not None:
                return connection(info, endpoint)
            time.sleep(1)
        raise RuntimeError(
            "The app engine is not ready. Enable 'Start MTPLX when opening the app' "
            "in MTPLX, or press its Start button, then retry pi-local."
        )


def pi_command(config, args, model=None):
    command = [config["pi"], "--offline", "--provider", "mtplx"]
    if model is not None:
        command += ["--model", model]
    return command + [
        "--extension", config["extension"],
        "--extension", config["providerExtension"],
        "--extension", config["telemetryExtension"], *args,
    ]


def main():
    config = json.loads(CONFIG_JSON)
    args = sys.argv[1:]
    if not os.access(config["pi"], os.X_OK):
        raise RuntimeError("Pi is missing; run just update-ai-clis in nixcfg.")
    model = None
    if not any(arg in ("--help", "-h", "--version", "-v") for arg in args):
        server = ensure_server(Path.home() / ".local/state/pi-local")
        os.environ["PI_LOCAL_CONNECTION"] = json.dumps(server)
        model = server["model"]
        print(f"pi-local: MTPLX app at {server['baseUrl']} · {model} · app settings", file=sys.stderr)
    os.environ["PI_CODING_AGENT_DIR"] = config["agentDir"]
    os.environ["PI_TELEMETRY"] = "0"
    # Inherit cwd, terminal, signals and exit status. No new Terminal window.
    os.execv(config["pi"], pi_command(config, args, model))


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"pi-local: {error}", file=sys.stderr)
        sys.exit(1)
