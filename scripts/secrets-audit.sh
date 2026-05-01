#!/usr/bin/env bash
#
# secrets-audit.sh — Detect drift between secrets/*.age and secrets/secrets.nix
#
# Usage:
#   ./scripts/secrets-audit.sh           # Print report; exit 1 on any drift
#   ./scripts/secrets-audit.sh --quiet   # Print only on drift; exit 1 on any drift
#   ./scripts/secrets-audit.sh --json    # Machine-readable output (requires jq)
#
# Drift categories:
#   declared-but-missing — declaration in secrets.nix has no file on disk
#                          (probably planned secret not yet `agenix -e`'d, OR
#                          stale declaration after a delete)
#   on-disk-but-undeclared — file in secrets/ has no entry in secrets.nix
#                            (orphan; unreachable by agenix --rekey, won't
#                            decrypt to any host)
#
# Exit codes:
#   0 — no drift
#   1 — drift detected
#   2 — usage / environment error
#
# Closes NIX-1330.
#
set -euo pipefail

# Colors (mirror runbook-secrets.sh palette)
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
RESET=$'\033[0m'

# Args
MODE="report" # report | quiet | json
case "${1:-}" in
"") ;;
--quiet) MODE="quiet" ;;
--json) MODE="json" ;;
-h | --help)
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
*)
    echo "${RED}error:${RESET} unknown arg '$1' (try --help)" >&2
    exit 2
    ;;
esac

# Resolve nixcfg root (works from any cwd)
REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO" || ! -f "$REPO/secrets/secrets.nix" ]]; then
    echo "${RED}error:${RESET} not in nixcfg repo (no secrets/secrets.nix)" >&2
    exit 2
fi

SECRETS_DIR="$REPO/secrets"
SECRETS_NIX="$SECRETS_DIR/secrets.nix"

# Build the two sets
disk_list="$(find "$SECRETS_DIR" -name '*.age' -type f -print0 |
    xargs -0 -n1 basename | sort -u)"
# Some declarations include path prefix (e.g. "agents/shared/FOO.age"),
# so also extract the full declared path.
disk_paths="$(find "$SECRETS_DIR" -name '*.age' -type f -printf '%P\n' 2>/dev/null ||
    find "$SECRETS_DIR" -name '*.age' -type f | sed "s|^$SECRETS_DIR/||")"
disk_paths="$(echo "$disk_paths" | sort -u)"

# Declared: anything in quoted form `"...age"` in secrets.nix.
# Strip nix line-comments first (`# …` to end of line) so commented-out
# declarations (TODO/staged-but-disabled) don't show up as false drift.
# Block comments (/* … */) aren't used in this file — bail loudly if they
# appear so we know to extend this stripper.
if grep -q '/\*' "$SECRETS_NIX"; then
    echo "${RED}error:${RESET} secrets.nix uses block comments — audit script only handles line comments. Extend before trusting output." >&2
    exit 2
fi
declared="$(sed 's|#.*||' "$SECRETS_NIX" | grep -oE '"[^"]+\.age"' | tr -d '"' | sort -u)"

# Compute deltas
declared_missing="$(comm -23 \
    <(echo "$declared") \
    <(echo "$disk_paths"))"
disk_undeclared="$(comm -13 \
    <(echo "$declared") \
    <(echo "$disk_paths"))"

n_disk=$(echo "$disk_paths" | grep -c . || true)
n_decl=$(echo "$declared" | grep -c . || true)
n_dm=$(echo "$declared_missing" | grep -c . || true)
n_du=$(echo "$disk_undeclared" | grep -c . || true)
total_drift=$((n_dm + n_du))

# Output
if [[ "$MODE" == "json" ]]; then
    if ! command -v jq >/dev/null; then
        echo "${RED}error:${RESET} --json mode requires jq" >&2
        exit 2
    fi
    jq -n \
        --argjson n_disk "$n_disk" \
        --argjson n_decl "$n_decl" \
        --arg dm "$declared_missing" \
        --arg du "$disk_undeclared" \
        '{
          counts: { disk: $n_disk, declared: $n_decl, drift: (($dm|split("\n")|map(select(length>0))|length) + ($du|split("\n")|map(select(length>0))|length)) },
          declared_but_missing: ($dm|split("\n")|map(select(length>0))),
          on_disk_but_undeclared: ($du|split("\n")|map(select(length>0)))
        }'
    [[ $total_drift -eq 0 ]] && exit 0 || exit 1
fi

if [[ $total_drift -eq 0 ]]; then
    if [[ "$MODE" != "quiet" ]]; then
        echo "${GREEN}✓ secrets-audit: no drift${RESET} (${n_disk} on disk, ${n_decl} declared)"
    fi
    exit 0
fi

echo "${YELLOW}⚠ secrets-audit: drift detected${RESET} (${n_disk} on disk, ${n_decl} declared, ${total_drift} mismatches)"
echo ""

if [[ $n_dm -gt 0 ]]; then
    echo "${CYAN}Declared but missing on disk${RESET} ($n_dm):"
    echo "  ${YELLOW}probably:${RESET} planned secret not yet \`agenix -e\`'d, OR stale declaration after delete"
    echo "$declared_missing" | sed 's/^/  - /'
    echo ""
fi

if [[ $n_du -gt 0 ]]; then
    echo "${CYAN}On disk but undeclared in secrets.nix${RESET} ($n_du):"
    echo "  ${YELLOW}implication:${RESET} orphan — unreachable by \`agenix --rekey\`, won't decrypt to any host"
    echo "$disk_undeclared" | sed 's/^/  - /'
    echo ""
fi

exit 1
