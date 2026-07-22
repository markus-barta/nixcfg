#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bridge="$repo_root/hosts/hsb1/files/ir-bridge.py"
service="$repo_root/hosts/hsb1/ir-bridge.nix"

python3 - "$bridge" "$service" <<'PY'
import importlib.util
import pathlib
import sys
import types

requests = types.ModuleType("requests")
requests.exceptions = types.SimpleNamespace(RequestException=Exception)
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
PY

printf 'ok: IR bridge allows only the reviewed TV endpoint and renders external log fields on one line\n'
