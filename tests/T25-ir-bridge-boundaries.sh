#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bridge="$repo_root/hosts/hsb1/files/ir-bridge.py"
service="$repo_root/hosts/hsb1/ir-bridge.nix"

PYTHONDONTWRITEBYTECODE=1 python3 - "$bridge" "$service" <<'PY'
import contextlib
import importlib.util
import io
import logging
import pathlib
import sys
import types


class FakeResponse:
    status_code = 307


class FakeSession:
    def __init__(self):
        self.trust_env = True
        self.calls = []

    def post(self, url, **kwargs):
        self.calls.append((url, kwargs))
        return FakeResponse()


requests = types.ModuleType("requests")
requests.exceptions = types.SimpleNamespace(RequestException=Exception)
requests.Session = FakeSession
sys.modules["requests"] = requests

path = pathlib.Path(sys.argv[1])
service = pathlib.Path(sys.argv[2]).read_text()
spec = importlib.util.spec_from_file_location("ir_bridge", path)
if spec is None or spec.loader is None:
    raise SystemExit("could not load ir-bridge module")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

expected = "http://192.168.1.137/sony/IRCC"
if module._sony_ircc_url("192.168.1.137") != expected:
    raise SystemExit("reviewed Sony endpoint did not resolve to its constant URL")
if 'SONY_TV_IP = "192.168.1.137";' not in service:
    raise SystemExit("NixOS Sony endpoint drifted from the bridge allowlist")

for candidate in (
    "127.0.0.1",
    "192.168.1.1",
    "192.168.1.137.example.invalid",
    "192.168.1.137/other",
    "192.168.1.137\nforged",
    "::1",
):
    try:
        module._sony_ircc_url(candidate)
    except ValueError:
        continue
    raise SystemExit(f"unreviewed Sony endpoint passed: {candidate!r}")

rendered = module._single_line("first\r\nsecond")
if "\r" in rendered or "\n" in rendered or rendered != r"first\r\nsecond":
    raise SystemExit("external log value was not rendered on one line")

# Exercise the production constructor and request sink, not only helpers.
module.CONFIG.update(
    {
        "sony_tv_psk": "non-secret-fixture",
        "retry_count": 1,
        "mqtt_user": "",
        "log_level": "DEBUG",
    }
)
module.CONFIG["sony_tv_ip"] = "127.0.0.1"
logging.getLogger("ir-bridge").handlers.clear()
try:
    with contextlib.redirect_stdout(io.StringIO()):
        module.IRBridge()
except SystemExit:
    pass
else:
    raise SystemExit("IRBridge accepted an unreviewed production destination")


class FakeMqttClient:
    def username_pw_set(self, *_args):
        pass

    def will_set(self, *_args, **_kwargs):
        pass

    def reconnect_delay_set(self, **_kwargs):
        pass

    def connect_async(self, *_args, **_kwargs):
        pass

    def loop_start(self):
        pass

    def publish(self, *_args, **_kwargs):
        pass


module.mqtt = types.SimpleNamespace(
    CallbackAPIVersion=types.SimpleNamespace(VERSION2=object()),
    Client=lambda *_args, **_kwargs: FakeMqttClient(),
)
module.MQTT_AVAILABLE = True
module.CONFIG.update(
    {
        "sony_tv_ip": "192.168.1.137",
        "mqtt_broker": "127.0.0.1\nforged-broker-record",
        "flirc_device": "/dev/input/reviewed\nforged-device-record",
    }
)
module.InputDevice = lambda _path: types.SimpleNamespace(
    name="FLIRC\nforged-device-name",
    close=lambda: None,
)
module.EVDEV_AVAILABLE = True

logs = io.StringIO()
logging.getLogger("ir-bridge").handlers.clear()
with contextlib.redirect_stdout(logs):
    bridge_instance = module.IRBridge()
    if bridge_instance.http.trust_env:
        raise SystemExit("IRBridge inherited ambient proxy configuration")
    if bridge_instance._send_ircc("fixture-code", "fixture-command"):
        raise SystemExit("IRBridge followed or accepted a redirect response")
    bridge_instance._setup_mqtt()
    bridge_instance._open_input()

if len(bridge_instance.http.calls) != 1:
    raise SystemExit("IRBridge request retry fixture did not make exactly one call")
url, kwargs = bridge_instance.http.calls[0]
if url != expected or kwargs.get("allow_redirects") is not False:
    raise SystemExit("IRBridge request sink did not preserve its exact destination boundary")

output = logs.getvalue()
for escaped in (
    r"127.0.0.1\nforged-broker-record",
    r"/dev/input/reviewed\nforged-device-record",
    r"FLIRC\nforged-device-name",
):
    if escaped not in output:
        raise SystemExit(f"production log sink did not render one line: {escaped}")
for injected in ("\nforged-broker-record", "\nforged-device-record", "\nforged-device-name"):
    if injected in output:
        raise SystemExit("production log sink emitted a forged record")
PY

printf 'ok: IR bridge fixes destination, disables proxies/redirects, and renders external log fields on one line\n'
