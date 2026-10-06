#!/usr/bin/env bash
# OPS-266 — headscale 0.29 ACL stages on csb0.
#
# Stage 1 (policy.hujson, referenced by policy.path) is allow-all: one accept
# * -> *:*, the same reach as an empty path on this fleet.
# Stage 2 (policy-stage2.hujson, not referenced) keeps markus@ and gerhard@
# on *:* and lets amy@ open only tcp 100.64.0.6:8470.
#
# Run under bash 5. macOS /bin/bash is 3.2, and set -e does not abort on a
# failing bare [[ ]] there (see T33). This script uses no bare [[ ]].
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 5 ]; then
  printf 'T92: bash %s is too old. Run under bash 5: nix shell nixpkgs#bash --run "bash %s"\n' \
    "$BASH_VERSION" "$0" >&2
  exit 2
fi

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cfgdir="${repo}/hosts/csb0/docker/headscale/config"
config="${cfgdir}/config.yaml"
stage1="${cfgdir}/policy.hujson"
stage2="${cfgdir}/policy-stage2.hujson"
compose="${repo}/hosts/csb0/docker/compose-spec.nix"

fail() {
  printf 'T92 failed: %s\n' "$*" >&2
  exit 1
}

[ -f "$stage1" ] || fail "missing $stage1"
[ -f "$stage2" ] || fail "missing $stage2"
[ -f "$config" ] || fail "missing $config"
[ -f "$compose" ] || fail "missing $compose"

image_tag="$(sed -nE 's/^ *image = "headscale\/headscale:([0-9]+\.[0-9]+)[^"]*";.*/\1/p' "$compose" | head -1)"
[ -n "$image_tag" ] || fail "headscale image tag not found in compose-spec.nix"
major="${image_tag%%.*}"
minor="${image_tag#*.}"
[ "$major" -eq 0 ] && [ "$minor" -ge 29 ] || fail "headscale ${image_tag} is not 0.29 policy syntax"

grep -Fq './headscale/config:/etc/headscale:ro' "$compose" ||
  fail "compose must mount ./headscale/config onto /etc/headscale (the policy mount)"

PYTHONDONTWRITEBYTECODE=1 python3 - "$config" "$stage1" "$stage2" <<'PY'
import json
import re
import sys

config_path, stage1_path, stage2_path = sys.argv[1:]

def fail(msg):
    print(f"T92 failed: {msg}", file=sys.stderr)
    sys.exit(1)

def strip_hujson(text):
    out = []
    i = 0
    n = len(text)
    in_str = False
    esc = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            i += 2
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            if i + 1 >= n:
                fail("unterminated block comment")
            i += 2
            continue
        out.append(c)
        i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))

def load_policy(path):
    with open(path) as fh:
        raw = fh.read()
    try:
        doc = json.loads(strip_hujson(raw))
    except json.JSONDecodeError as exc:
        fail(f"{path} is not HuJSON: {exc}")
    if not isinstance(doc, dict):
        fail(f"{path} must be an object")
    return doc

def policy_block(text):
    mode = None
    path = None
    in_policy = False
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if not in_policy:
            if line.startswith("policy:"):
                in_policy = True
            continue
        if indent == 0:
            break
        key, sep, val = stripped.partition(":")
        if not sep:
            continue
        val = val.strip().strip('"').strip("'")
        if key == "mode":
            mode = val
        elif key == "path":
            path = val
    return mode, path

def groups_of(doc):
    raw = doc.get("groups") or {}
    if not isinstance(raw, dict):
        fail("groups must be an object")
    groups = {}
    for name, members in raw.items():
        if not isinstance(members, list) or not all(isinstance(m, str) for m in members):
            fail(f"group {name} must be a list of strings")
        groups[name] = members
    return groups

def hosts_of(doc):
    raw = doc.get("hosts") or {}
    if not isinstance(raw, dict):
        fail("hosts must be an object")
    hosts = {}
    for name, cidr in raw.items():
        if not isinstance(cidr, str):
            fail(f"host {name} must be a string")
        hosts[name] = cidr
    return hosts

def src_hits(src, groups, user):
    if not isinstance(src, list):
        fail("src must be a list")
    for item in src:
        if not isinstance(item, str):
            fail("src entries must be strings")
        if item in ("*", "autogroup:member"):
            return True
        if item == user:
            return True
        if item.startswith("group:") and user in groups.get(item, []):
            return True
    return False

def split_dst(spec):
    if not isinstance(spec, str) or ":" not in spec:
        fail(f"dst entry {spec!r} must be destination:ports")
    host, ports = spec.rsplit(":", 1)
    return host, ports

def resolve_host(token, hosts):
    if token == "*":
        return "*"
    cidr = hosts.get(token, token)
    ip, sep, prefix = cidr.partition("/")
    if sep and prefix != "32":
        return cidr
    return ip

def proto_of(rule):
    proto = rule.get("proto")
    if proto is None:
        return None
    if not isinstance(proto, str):
        fail("proto must be a string")
    return proto

def acls_of(doc):
    acls = doc.get("acls") or []
    if not isinstance(acls, list):
        fail("acls must be a list")
    return acls

def grants_of(doc):
    grants = doc.get("grants") or []
    if not isinstance(grants, list):
        fail("grants must be a list")
    return grants

PAPER = "100.64.0.6"
PAPER_PORT = "8470"
AMY = "amy@"
FULL_USERS = ("markus@", "gerhard@")

def amy_destinations(doc):
    """Every destination a rule grants amy@, as (host, ports, proto)."""
    groups = groups_of(doc)
    hosts = hosts_of(doc)
    found = []
    for rule in acls_of(doc):
        if not isinstance(rule, dict):
            fail("acl rule must be an object")
        if rule.get("action") != "accept":
            fail(f"acl action must be accept, got {rule.get('action')!r}")
        if not src_hits(rule.get("src"), groups, AMY):
            continue
        proto = proto_of(rule)
        for spec in rule.get("dst") or []:
            host, ports = split_dst(spec)
            found.append((resolve_host(host, hosts), ports, proto))
    for rule in grants_of(doc):
        if not isinstance(rule, dict):
            fail("grant must be an object")
        if not src_hits(rule.get("src"), groups, AMY):
            continue
        ip = rule.get("ip")
        if ip is None:
            ports, proto = "*", None
        elif isinstance(ip, list):
            # A grant ip list is one capability. Join so anything other than
            # a single tcp:8470 fails the exact-port check below.
            parts = []
            protos = set()
            for item in ip:
                if not isinstance(item, str):
                    fail("grant ip entries must be strings")
                if ":" in item and item.split(":", 1)[0] in ("tcp", "udp", "icmp"):
                    p, rest = item.split(":", 1)
                    protos.add(p)
                    parts.append(rest)
                else:
                    parts.append(item)
            ports = ",".join(parts)
            proto = protos.pop() if len(protos) == 1 else None
        else:
            fail("grant ip must be a list")
        dsts = rule.get("dst") or []
        for token in dsts:
            if not isinstance(token, str):
                fail("grant dst entries must be strings")
            # Grants put ports in ip, not in dst. A dst that already has :ports
            # is still a destination and must not widen amy.
            if ":" in token and not token.startswith("autogroup:") and token not in hosts:
                host, dst_ports = split_dst(token)
                found.append((resolve_host(host, hosts), dst_ports, proto))
            else:
                found.append((resolve_host(token, hosts), ports, proto))
    return found

def is_paper_tcp(host, ports, proto):
    return host == PAPER and ports == PAPER_PORT and proto == "tcp"

def assert_stage1(doc):
    groups = groups_of(doc)
    hits = []
    for rule in acls_of(doc):
        if not isinstance(rule, dict) or rule.get("action") != "accept":
            continue
        src = rule.get("src") or []
        dst = rule.get("dst") or []
        if "*" in src and "*:*" in dst and proto_of(rule) is None:
            hits.append(rule)
    if not hits:
        fail("stage 1 must accept src * dst *:* with no proto restriction")
    # The wildcard source covers amy@ as well as markus@ and gerhard@.
    if not src_hits(["*"], groups, AMY):
        fail("stage 1 wildcard did not cover amy@")
    for user in FULL_USERS:
        if not src_hits(["*"], groups, user):
            fail(f"stage 1 wildcard did not cover {user}")

def user_keeps_star(doc, user):
    groups = groups_of(doc)
    for rule in acls_of(doc):
        if not isinstance(rule, dict) or rule.get("action") != "accept":
            continue
        src = rule.get("src") or []
        # Literal user@, not a wildcard that would also open amy@.
        if user not in src:
            continue
        if "*:*" in (rule.get("dst") or []) and proto_of(rule) is None:
            return True
    # A group that contains the user and nobody else we have to exclude is
    # still a keep, as long as the rule's src lists that group and not amy.
    for rule in acls_of(doc):
        if not isinstance(rule, dict) or rule.get("action") != "accept":
            continue
        if "*:*" not in (rule.get("dst") or []) or proto_of(rule) is not None:
            continue
        for item in rule.get("src") or []:
            if item.startswith("group:") and user in groups.get(item, []):
                if AMY in groups.get(item, []):
                    continue
                return True
    return False

def assert_stage2(doc):
    for user in FULL_USERS:
        if not user_keeps_star(doc, user):
            fail(f"stage 2 must keep {user} on *:*")
    found = amy_destinations(doc)
    if not found:
        fail("stage 2 has no accept rule for amy@")
    for host, ports, proto in found:
        if not is_paper_tcp(host, ports, proto):
            fail(
                "stage 2 lets amy@ reach "
                f"{host}:{ports} proto={proto!r}; only tcp {PAPER}:{PAPER_PORT} is allowed"
            )
    if not any(is_paper_tcp(h, p, proto) for h, p, proto in found):
        fail(f"stage 2 does not grant amy@ tcp {PAPER}:{PAPER_PORT}")

with open(config_path) as fh:
    mode, path = policy_block(fh.read())
if mode != "file":
    fail(f"policy.mode must be file, got {mode!r}")
if path != "/etc/headscale/policy.hujson":
    fail(f"policy.path must be the stage-1 container path, got {path!r}")
if "policy-stage2" in path:
    fail("policy.path must not reference stage 2")

stage1 = load_policy(stage1_path)
stage2 = load_policy(stage2_path)
assert_stage1(stage1)
assert_stage2(stage2)
print("T92: stage 1 allow-all; stage 2 amy@ tcp 100.64.0.6:8470 only; markus@ and gerhard@ *:*")
PY

printf 'T92 ok\n'
