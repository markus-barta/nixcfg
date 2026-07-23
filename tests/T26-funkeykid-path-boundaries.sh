#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/hosts/hsb1/files/funkeykid.py"
env_file="$repo_root/hosts/hsb1/files/funkeykid.env"
module_file="$repo_root/modules/funkeykid.nix"
host_file="$repo_root/hosts/hsb1/configuration.nix"

PYTHONDONTWRITEBYTECODE=1 python3 - "$script" "$env_file" "$module_file" "$host_file" <<'PY'
import importlib.util
import pathlib
import sys
import tempfile
import types

evdev = types.ModuleType("evdev")
sys.modules["evdev"] = evdev
paho = types.ModuleType("paho")
paho.__path__ = []
mqtt_package = types.ModuleType("paho.mqtt")
mqtt_package.__path__ = []
mqtt_client = types.ModuleType("paho.mqtt.client")
paho.mqtt = mqtt_package
mqtt_package.client = mqtt_client
sys.modules["paho"] = paho
sys.modules["paho.mqtt"] = mqtt_package
sys.modules["paho.mqtt.client"] = mqtt_client

path = pathlib.Path(sys.argv[1])
env_text = pathlib.Path(sys.argv[2]).read_text()
module_text = pathlib.Path(sys.argv[3]).read_text()
host_text = pathlib.Path(sys.argv[4]).read_text()
spec = importlib.util.spec_from_file_location("funkeykid", path)
if spec is None or spec.loader is None:
    raise SystemExit("could not load funkeykid module")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

expected_config = pathlib.Path("/etc/funkeykid.env")
if module.reviewed_config_path(str(expected_config)) != expected_config:
    raise SystemExit("reviewed config path did not resolve to its constant")

for candidate in (
    "/tmp/funkeykid.env",
    "/etc/../tmp/funkeykid.env",
    "/etc/%2e%2e/tmp/funkeykid.env",
    "funkeykid.env",
    "/etc/funkeykid.env/extra",
):
    try:
        module.load_env(candidate)
    except ValueError:
        continue
    raise SystemExit(f"production config loader accepted: {candidate!r}")

with tempfile.TemporaryDirectory() as directory:
    base = pathlib.Path(directory)
    config_fixture = base / "funkeykid.env"
    config_fixture.write_text("KEYBOARD_DEVICE=ACME BK03\nSOUND_DIR=/var/lib/funkeykid-sounds\n")
    original_config_path = module.CONFIG_PATH
    module.CONFIG_PATH = config_fixture
    try:
        parsed = module.load_env(str(config_fixture))
    finally:
        module.CONFIG_PATH = original_config_path
    if parsed.get("KEYBOARD_DEVICE") != "ACME BK03":
        raise SystemExit("reviewed production config loader changed behavior")

    root = base / "sounds"
    root.mkdir()
    outside = base / "outside.mp3"
    outside.write_bytes(b"outside")
    (root / "safe-name_1.mp3").write_bytes(b"safe")
    (root / "safe.wav").write_bytes(b"safe")
    (root / "escape.mp3").symlink_to(outside)

    original_sound_root = module.SOUND_ROOT
    module.SOUND_ROOT = root
    discovered = module.get_sound_files(str(root))
    module.SOUND_ROOT = original_sound_root
    if discovered != sorted(
        [(root / "safe-name_1.mp3").resolve(), (root / "safe.wav").resolve()]
    ):
        raise SystemExit("production sound discovery included an unsafe path")

    expected = (root / "safe-name_1.mp3").resolve()
    if module.resolve_audio_file(root, "safe-name_1.mp3") != expected:
        raise SystemExit("reviewed audio filename did not resolve inside its root")

    for candidate in (
        "../outside.mp3",
        "nested/outside.mp3",
        "/tmp/outside.mp3",
        r"..\outside.mp3",
        "%2e%2e%2foutside.mp3",
        "..%2foutside.mp3",
        ".hidden.mp3",
        "escape.mp3",
        "safe.mp3\x00outside",
        "safe.txt",
    ):
        try:
            module.resolve_audio_file(root, candidate)
        except (FileNotFoundError, ValueError):
            continue
        raise SystemExit(f"unreviewed audio path passed: {candidate!r}")

    linked_root = base / "linked-sounds"
    linked_root.symlink_to(root, target_is_directory=True)
    module.SOUND_ROOT = linked_root
    try:
        module.reviewed_sound_root(str(linked_root))
    except ValueError:
        pass
    else:
        raise SystemExit("symlinked sound root passed")
    finally:
        module.SOUND_ROOT = original_sound_root

if "SOUND_DIR=/var/lib/funkeykid-sounds" not in env_text:
    raise SystemExit("declarative sound root drifted from the allowlist")
if '"FUNKEYKID_CONFIG=/etc/funkeykid.env"' not in module_text:
    raise SystemExit("NixOS config path drifted from the allowlist")
if "enable = false; # systemd service off — Docker container runs instead" not in host_text:
    raise SystemExit("legacy service unexpectedly became the deployed funkeykid flow")
PY

printf 'ok: funkeykid accepts only its fixed config and flat in-root audio files; Docker deployment remains selected\n'
