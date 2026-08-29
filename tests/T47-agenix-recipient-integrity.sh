#!/usr/bin/env bash
# OPS-188: the agenix declaration and the ciphertext must agree.
#
# `secrets/secrets.nix` says who MAY decrypt each secret; the `.age` file records
# who actually CAN. Nothing kept them in sync: adding a host to a recipient list
# without `just rekey`, or producing a file for the wrong recipients, is invisible
# until that host fails to activate — on a remote host, after a switch. (2026-08-21,
# OPS-185: a secret was resealed by hand for markus + hsb1; the only proof it was
# right was hsb1 surviving its switch.)
#
# An age file names its recipients without revealing them: each `-> ssh-ed25519 <tag>`
# stanza carries base64(SHA256(ssh-wire-pubkey)[0:4]). That is computable from the
# PUBLIC key alone, so this test verifies the real recipient set of every secret
# without decrypting anything and without touching a private key.
#
# Checks:
#   1. every .age file is declared, and every declaration has a file;
#   2. declared recipients == the file's actual recipient stanzas (rekey drift);
#   3. every secret a host declares lists that host as a recipient (comment-aware).
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
declarations="$(nix eval --json --file "${repo}/secrets/secrets.nix")"

PYTHONDONTWRITEBYTECODE=1 python3 - "${repo}" "${declarations}" <<'PY'
import base64, glob, hashlib, json, os, re, sys

repo, declarations = sys.argv[1], json.loads(sys.argv[2])
failures = []


def recipient_tag(public_key: str) -> str | None:
    """age's stanza tag for an SSH recipient: base64(sha256(wire key)[:4])."""
    parts = public_key.split()
    if len(parts) < 2:
        return None
    try:
        blob = base64.b64decode(parts[1])
    except Exception:  # noqa: BLE001 -- a malformed key is reported below, not raised
        return None
    return base64.b64encode(hashlib.sha256(blob).digest()[:4]).decode().rstrip("=")


secrets_dir = os.path.join(repo, "secrets")
files = sorted(
    os.path.relpath(p, secrets_dir)
    for p in glob.glob(os.path.join(secrets_dir, "**", "*.age"), recursive=True)
)

# 1. declaration <-> file
for name in files:
    if name not in declarations:
        failures.append(f"{name}: encrypted file has no entry in secrets.nix (it can never be rekeyed)")
for name in declarations:
    if not os.path.exists(os.path.join(secrets_dir, name)):
        failures.append(f"{name}: declared in secrets.nix but the file does not exist")

# 2. declared recipients vs the ciphertext's own stanzas
STANZA = re.compile(r"^-> (ssh-ed25519|ssh-rsa|X25519|scrypt) (\S+)", re.M)
for name in files:
    entry = declarations.get(name)
    if not entry:
        continue
    keys = entry.get("publicKeys") or []
    if not keys:
        failures.append(f"{name}: declares an empty recipient list")
        continue
    declared = set()
    for key in keys:
        tag = recipient_tag(key)
        if tag is None:
            failures.append(f"{name}: unparseable recipient key {key.split()[0] if key.split() else key!r}")
            continue
        declared.add(tag)
    with open(os.path.join(secrets_dir, name), "rb") as handle:
        header = handle.read(16384).decode("utf-8", "replace")
    actual = {tag for _, tag in STANZA.findall(header)}
    if not actual:
        failures.append(f"{name}: no age recipient stanzas found (not an age file?)")
    elif declared != actual:
        missing = len(declared - actual)
        extra = len(actual - declared)
        failures.append(
            f"{name}: recipients drifted — {missing} declared key(s) cannot decrypt it, "
            f"{extra} key(s) can that are not declared. Run `just rekey`."
        )

# 3. a host must be able to read what it declares
DECL = re.compile(r"\.\./\.\./secrets/([A-Za-z0-9._/-]+\.age)")
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
expressions = dict(
    re.findall(r'"([^"]+\.age)"\.publicKeys\s*=\s*([^;]+);', open(os.path.join(secrets_dir, "secrets.nix")).read())
)
for host_dir in sorted(glob.glob(os.path.join(repo, "hosts", "*", ""))):
    host = os.path.basename(host_dir.rstrip("/"))
    referenced: set[str] = set()
    for path in glob.glob(os.path.join(host_dir, "**", "*.nix"), recursive=True):
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                if line.lstrip().startswith("#"):
                    continue  # a commented-out declaration deploys nothing
                referenced |= set(DECL.findall(line))
    for name in sorted(referenced):
        if name not in expressions:
            failures.append(f"{host}: declares {name}, which secrets.nix does not list")
            continue
        if host not in set(IDENT.findall(expressions[name])):
            failures.append(
                f"{host}: declares {name} but is not among its recipients "
                f"({expressions[name].strip()}) — activation on {host} would fail to decrypt it"
            )

if failures:
    print(f"T47: {len(failures)} agenix integrity failure(s):", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    raise SystemExit(1)
print(f"T47: {len(files)} secrets — declarations, ciphertext recipients and host wiring agree")
PY
echo "T47 ok"
