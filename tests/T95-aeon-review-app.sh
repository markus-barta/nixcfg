#!/usr/bin/env bash
# OPS-269: pure evaluation and synthetic files only; no NixOS build or real secret reads.
set -euo pipefail
if [ "${BASH_VERSINFO[0]}" -lt 5 ]; then
  printf '%s: bash 5 is required\n' "${0##*/}" >&2
  exit 2
fi

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 - "$repo" "$BASH" <<'PY'
import json
from pathlib import Path
import shlex
import stat
import subprocess
import sys
import tempfile

repo, bash = Path(sys.argv[1]), sys.argv[2]

def evaluate(expression):
    result = subprocess.run(
        ["nix-instantiate", "--eval", "--strict", "--json", "--expr", expression],
        cwd=repo, text=True, capture_output=True, check=True,
    )
    return json.loads(result.stdout)

compose = evaluate('(import ./hosts/csb1/docker/compose-spec.nix).services.aeon')
expected_env = {
    "AEON_REVIEW_APP_ID": "5223951",
    "AEON_REVIEW_INSTALLATION_ID": "168865053",
    "AEON_REVIEW_APP_TENANT_ID": "5d32191b-252c-4ef4-a406-788316a5ccb7",
    "AEON_REVIEW_APP_REPOSITORY": "inspr-at/paimos",
    "AEON_REVIEW_APP_KEY_FILE": "/run/secrets/aeon-review-app-key.pem",
    "AEON_REVIEW_WEBHOOK_SECRET_FILE": "/run/secrets/aeon-review-webhook-secret",
}
for key, value in expected_env.items():
    entries = [entry for entry in compose["environment"] if entry.startswith(key + "=")]
    assert entries == [key + "=" + value], f"wrong or duplicate {key}"

pairs = [
    ("csb1-aeon-review-app-key", "review-app-key.pem", "aeon-review-app-key.pem"),
    ("csb1-aeon-review-webhook-secret", "review-webhook-secret", "aeon-review-webhook-secret"),
]
for name, filename, target in pairs:
    expected = {
        "type": "bind", "source": "/var/lib/aeon-secrets/" + filename,
        "target": "/run/secrets/" + target, "read_only": True,
        "bind": {"create_host_path": False},
    }
    matches = [mount for mount in compose["volumes"]
               if isinstance(mount, dict) and mount.get("target") == expected["target"]]
    assert matches == [expected], f"unsafe or duplicate mount: {target}"

# Lazily evaluate only these attributes with inert package stubs. toString keeps
# ciphertext paths as metadata: JSON conversion must never import their bytes.
host = evaluate('''let
  host = import ./hosts/csb1/configuration.nix {
    lib = {}; inputs = {};
    pkgs = { coreutils = "/fixture/coreutils"; openssl = "/fixture/openssl"; bash = "/fixture/bash"; };
    config.age.secrets = host.age.secrets;
  };
  service = host.systemd.services.aeon-secrets;
  metadata = secret: secret // { file = builtins.toString secret.file; };
in {
  service = service // { restartTriggers = map builtins.toString service.restartTriggers; };
  app = metadata host.age.secrets.csb1-aeon-review-app-key;
  webhook = metadata host.age.secrets.csb1-aeon-review-webhook-secret;
}''')
service = host["service"]
assert "agenix.service" in service["after"], "installer must follow agenix"
assert service["serviceConfig"] == {"Type": "oneshot", "RemainAfterExit": True}
for consumer in ("compose-csb1.service", "compose-csb1-update.service"):
    assert consumer in service["requiredBy"] and consumer in service["before"]
for field, (name, filename, target) in zip(("app", "webhook"), pairs):
    metadata = host[field]
    assert metadata == {
        "file": str(repo / "secrets" / (name + ".age")),
        "path": "/run/agenix/" + name, "owner": "root", "group": "root", "mode": "0400",
    }, f"wrong agenix metadata: {name}"
    assert metadata["file"] in service["restartTriggers"], "missing ciphertext restart trigger"

source = (repo / "secrets/secrets.nix").read_text()
for name, _, _ in pairs:
    assert f'"{name}.age".publicKeys = markus ++ csb1;' in source
configuration = (repo / "hosts/csb1/configuration.nix").read_text()
triggers = configuration.split("extraRestartTriggers = [", 1)[1].split("];", 1)[0]
for name, _, _ in pairs:
    assert f"config.age.secrets.{name}.file" in triggers, "Compose must restart on rotation"
recreate = configuration.split("postRecreate = [", 1)[1].split("];", 1)[0]
assert '"aeon"' in recreate, "Compose must remount the new credential inodes"

script = service["script"]
assert 'install -d -m 0700 -o root -g root "$d"' in script
assert "for f in db-superuser-password db-password session-key messaging-key doctrine-guard-key; do" in script
assert 'if [ ! -s "$v" ]; then' in script and "aeon-phone-push-vapid.sh" in script
copies = script.split("# OPS-269: physical owner-only files", 1)[1]
assert "if " not in copies, "review credentials must refresh on every start"
for name, filename, _ in pairs:
    assert f'install -m 0400 -o 65532 -g 65532 "/run/agenix/{name}" "$d/{filename}.tmp"' in copies
    assert f'mv -fT "$d/{filename}.tmp" "$d/{filename}"' in copies
subprocess.run([bash, "-n"], input=script, text=True, check=True)

# Run the evaluated copy commands with synthetic symlink sources. Ownership is
# asserted above and intercepted here: unprivileged macOS cannot chown to 65532.
# Actual install/mv still exercise mode, physical files, replacement and rotation.
with tempfile.TemporaryDirectory(prefix="aeon-review-contract-") as temporary:
    root = Path(temporary)
    destination = root / "runtime"
    destination.mkdir(mode=0o700)
    for name, filename, _ in pairs:
        fixture = root / (name + ".fixture")
        fixture.write_text("synthetic generation one")
        link = root / name
        link.symlink_to(fixture)
        (destination / filename).symlink_to(fixture)
        copies = copies.replace("/run/agenix/" + name, str(link))
    prefix = '''install() {
  [[ "$1 $2 $3 $4 $5 $6" == "-m 0400 -o 65532 -g 65532" ]] || return 91
  shift 6
  command install -m 0400 "$@"
}
'''
    execution = "set -euo pipefail\n" + prefix + "d=" + shlex.quote(str(destination)) + "\n#" + copies
    for generation in ("one", "two"):
        for name, _, _ in pairs:
            (root / (name + ".fixture")).write_text("synthetic generation " + generation)
        subprocess.run([bash, "-c", execution], check=True)
        for name, filename, _ in pairs:
            installed = destination / filename
            assert stat.S_ISREG(installed.lstat().st_mode), "bind source must be physical"
            assert stat.S_IMODE(installed.stat().st_mode) == 0o400
            assert installed.read_text() == "synthetic generation " + generation
            assert not (destination / (filename + ".tmp")).exists()
    # A missing source fails without replacing the last healthy credential.
    (root / pairs[0][0]).unlink()
    failed = subprocess.run([bash, "-c", execution], capture_output=True, text=True)
    assert failed.returncode != 0, "missing agenix credential must fail closed"
    assert (destination / pairs[0][1]).read_text() == "synthetic generation two"

print("T95 ok: AEON review env, private binds, agenix metadata, rotation and fail-closed install")
PY
