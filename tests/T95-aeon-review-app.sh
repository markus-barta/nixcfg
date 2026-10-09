#!/usr/bin/env bash
# OPS-269: pure evaluation and synthetic files only; no NixOS build or real secret reads.
set -euo pipefail
if [ "${BASH_VERSINFO[0]}" -lt 5 ]; then
  printf '%s: bash 5 is required\n' "${0##*/}" >&2
  exit 2
fi

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 - "$repo" "$BASH" <<'PY'
import hashlib
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

pairs = [
    ("csb1-aeon-review-app-key", "review-app-key.pem", "aeon-review-app-key.pem"),
    ("csb1-aeon-review-webhook-secret", "review-webhook-secret", "aeon-review-webhook-secret"),
]

# Evaluate the real spec with only its two ciphertext paths replaced by synthetic
# files. Never read, hash or copy the repository's encrypted credential files.
compose_source = (repo / "hosts/csb1/docker/compose-spec.nix").read_text()
with tempfile.TemporaryDirectory(prefix="aeon-review-label-") as temporary:
    root = Path(temporary)
    fixture_spec = root / "hosts/csb1/docker/compose-spec.nix"
    fixture_spec.parent.mkdir(parents=True)
    (root / "secrets").mkdir()
    fixtures = []
    for name, _, _ in pairs:
        original = "../../../secrets/" + name + ".age"
        assert compose_source.count(original) == 1, "missing or duplicate ciphertext hash input"
        assert 'builtins.hashFile "sha256" ' + original in compose_source
        compose_source = compose_source.replace(original, "../../../secrets/" + name + ".fixture")
        fixture = root / "secrets" / (name + ".fixture")
        fixture.write_text("synthetic ciphertext generation one: " + name)
        fixtures.append(fixture)
    fixture_spec.write_text(compose_source)
    expression = '(import (builtins.toPath ' + json.dumps(str(fixture_spec)) + ')).services.aeon'
    compose = evaluate(expression)

    def credential_label(spec):
        entries = [label for label in spec["labels"] if label.startswith("ops269.review-credentials=")]
        digest = hashlib.sha256("".join(
            hashlib.sha256(fixture.read_bytes()).hexdigest() for fixture in fixtures
        ).encode()).hexdigest()
        assert entries == ["ops269.review-credentials=" + digest], "incorrect combined credential hash"
        return entries[0]

    previous = credential_label(compose)
    assert credential_label(evaluate(expression)) == previous, "unchanged credentials must retain the label"
    for fixture in fixtures:
        fixture.write_text("synthetic ciphertext generation two: " + fixture.name)
        current = credential_label(evaluate(expression))
        assert current != previous, "either credential rotation must change the label"
        previous = current

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
assert '"aeon"' not in recreate, "unrelated reconciles must not force-recreate AEON"
assert shlex.split(recreate) == ["hostdash-auth", "hostdash", "traefik"]

script = service["script"]
assert 'install -d -m 0700 -o root -g root "$d"' in script
assert "for f in db-superuser-password db-password session-key messaging-key doctrine-guard-key; do" in script
assert 'if [ ! -s "$v" ]; then' in script and "aeon-phone-push-vapid.sh" in script
copies = script.split("# OPS-269: physical owner-only files", 1)[1]
assert 'if [ "$(LC_ALL=C tr -d \'[:space:]\' < "$d/review-webhook-secret.tmp" | wc -c)" -lt 32 ]; then' in copies
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
        fixture.write_text("synthetic credential generation one")
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
            (root / (name + ".fixture")).write_text("synthetic credential generation " + generation)
        subprocess.run([bash, "-c", execution], check=True)
        for name, filename, _ in pairs:
            installed = destination / filename
            assert stat.S_ISREG(installed.lstat().st_mode), "bind source must be physical"
            assert stat.S_IMODE(installed.stat().st_mode) == 0o400
            assert installed.read_text() == "synthetic credential generation " + generation
            assert not (destination / (filename + ".tmp")).exists()
    # The floor counts non-whitespace bytes: padded short and empty values fail
    # without replacing either healthy bind source or leaking the attempted value.
    for rejected in ("", " \t\r\n" * 16, "q" * 31, " \t\n" + "q" * 31 + "\r\n "):
        (root / (pairs[0][0] + ".fixture")).write_text("synthetic pending app key generation")
        (root / (pairs[1][0] + ".fixture")).write_text(rejected)
        before = [(destination / filename).stat().st_ino for _, filename, _ in pairs]
        failed = subprocess.run([bash, "-c", execution], capture_output=True, text=True)
        assert failed.returncode != 0, "short webhook secret must fail closed"
        assert "at least 32 non-whitespace bytes" in failed.stderr
        assert failed.stdout == ""
        if rejected.strip():
            assert rejected.strip() not in failed.stderr, "refusal must not print credential content"
        for index, (_, filename, _) in enumerate(pairs):
            installed = destination / filename
            assert installed.stat().st_ino == before[index], "refusal must preserve the existing inode"
            assert installed.read_text() == "synthetic credential generation two"
    # Exactly 32 non-whitespace bytes are accepted, including surrounding whitespace.
    accepted = " \t\n" + "z" * 32 + "\r\n "
    (root / (pairs[1][0] + ".fixture")).write_text(accepted)
    subprocess.run([bash, "-c", execution], check=True)
    assert (destination / pairs[1][1]).read_bytes() == accepted.encode()
    assert (destination / pairs[0][1]).read_text() == "synthetic pending app key generation"
    # A missing source fails without replacing the last healthy credential.
    (root / pairs[0][0]).unlink()
    failed = subprocess.run([bash, "-c", execution], capture_output=True, text=True)
    assert failed.returncode != 0, "missing agenix credential must fail closed"
    assert (destination / pairs[0][1]).read_text() == "synthetic pending app key generation"
    assert (destination / pairs[1][1]).read_bytes() == accepted.encode()

print("T95 ok: AEON review env, private binds, agenix metadata, credential-hash rotation and 32-byte fail-closed install")
PY
