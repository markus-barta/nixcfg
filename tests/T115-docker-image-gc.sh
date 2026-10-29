#!/usr/bin/env bash
# OPS-327 r34: portable unit/mutant suite, static module contract and guard 7.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo}"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_docker_image_gc.py' -v
for file in hosts/csb1/docker-image-gc.nix tests/docker-image-gc-names.nix tests/docker-image-gc-vm.nix; do
  nix-instantiate --parse "${file}" >/dev/null
done
python3 - <<'CHECK'
from pathlib import Path
import ast
module = Path('hosts/csb1/docker-image-gc.nix').read_text()
source = Path('hosts/csb1/docker-image-gc.py').read_text()
assert './docker-image-gc.nix' in Path('hosts/csb1/configuration.nix').read_text()
for marker in (
    'composeStack.renderedSpec.services', 'DECLARED_REFS = builtins.toJSON declaredRefs',
    'assertion = namesHold;', 'cfg.system.systemBuilderArgs', 'nixos-system-${cfg.system.name}-${cfg.system.nixos.label}',
    'CapabilityBoundingSet = "";', 'StateDirectory = "docker-image-gc";',
    'ReadWritePaths = [ "/run/lock" ];', 'RestrictAddressFamilies = [ "AF_UNIX" ];',
    'TimeoutStartSec = "1h";', 'TimeoutStopSec = "180";',
    'OnCalendar = "*-*-* 04:30:00";', 'RandomizedDelaySec = "10m";',
    '"d /var/lib/docker-image-gc/keep.d 0755 root root -"',
    'PrivateTmp = true;', 'PrivateDevices = true;', 'ProtectSystem = "strict";',
    'ProtectHome = true;', 'NoNewPrivileges = true;', 'ProtectKernelTunables = true;',
    'ProtectKernelModules = true;', 'LockPersonality = true;', 'RestrictRealtime = true;',
    'RestrictSUIDSGID = true;', 'SystemCallArchitectures = "native";',
): assert marker in module, marker
for forbidden in ('activation.lock', 'activationScripts', 'dockerImageGcGuards', 'chainHolds',
                  'user@0.service', 'RuntimeDirectory', 'Persistent = true'):
    assert forbidden not in module, forbidden
for forbidden in ('CHAIN_COMMS', 'WRAPPER_MARKS', 'chain_running', 'scan_pass',
                  'activation.lock', 'os.path.exists(', 'os.path.lexists(', 'janus-pharos-production.lock'):
    assert forbidden not in source, forbidden
constants = {}
for node in ast.parse(source).body:
    if isinstance(node, ast.Assign):
        for target in node.targets:
            if isinstance(target, ast.Name):
                try: constants[target.id] = ast.literal_eval(node.value)
                except (ValueError, TypeError): pass
assert constants['BATCH_S'] == 10
assert constants['CALL_DEADLINE_S'] == 30
assert constants['COOLDOWN_S'] == 45
assert 'RUN_BUDGET_S = 50 * 60' in source
assert constants['LOCK_WAIT_S'] == 300
assert constants['INSTANCE_LOCK'] == '/run/lock/docker-image-gc.lock'
assert constants['SWITCH_LOCK'] == '/run/nixos/switch-to-configuration.lock'
assert constants['KEEP_DIR'] == '/var/lib/docker-image-gc/keep.d'
assert constants['LOCK_PATHS'] == ('/run/lock/compose-csb1.lock', '/run/lock/compose-hausv.lock', '/run/lock/compose-hausv-next.lock')
assert 'st = os.stat(SWITCH_LOCK)' in source
assert 'class DeadlineSocket(socket.socket):' in source
assert 'O_RDONLY | os.O_NONBLOCK | os.O_NOCTTY | os.O_CLOEXEC' in source
assert 'if not os.environ.get("INVOCATION_ID"):' in source
assert 'signal.setitimer(signal.ITIMER_REAL, max(seconds, 0.001))' in source
assert '?noprune=1' in source and 'force=' not in source
# Exactly two destructive-call sites, both through the shared deadline path.
tree = ast.parse(source)
calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call)
         and isinstance(node.func, ast.Name) and node.func.id == 'destructive_call']
assert len(calls) == 2
assert {ast.literal_eval(node.args[1]) for node in calls} == {'DELETE', 'POST'}
assert 'PRUNE_PATH = "/build/prune?"' in source
assert '"all": "1"' in source and '"until": [f"{KEEP_DAYS * 24}h"]' in source
print('T115 static r34 contract ok')
CHECK
if [ "$(uname -s)" = Linux ]; then
  nix eval --impure --no-update-lock-file --json .#nixosConfigurations.csb1.config \
    --apply 'config: import ./tests/docker-image-gc-names.nix { inherit config; }' |
    python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["namesHold"], r; print("T115 guard 7 actual names ok:",len(r["systems"]))'
else
  echo "SKIP T115 actual toplevel.name comparison: coordinator runs full Linux evaluation"
fi
echo "T115 ok"
