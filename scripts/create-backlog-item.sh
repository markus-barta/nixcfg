#!/bin/bash

# Generic script to create backlog items in any directory
#
# USAGE: ./scripts/create-backlog-item.sh [priority] [description] [--dir target-dir] [--host hostname]
# RUN FROM: Repository root
#
# EXAMPLES:
#   # Infrastructure backlog (default: +pm/backlog/infra/)
#   ./scripts/create-backlog-item.sh P50 fix-nix-flake
#
#   # Host-specific backlog with explicit directory
#   ./scripts/create-backlog-item.sh P30 audit-docker --host hsb0 --dir hosts/hsb0/docs/backlog
#
#   # Host-specific backlog (short form, infers directory from host)
#   ./scripts/create-backlog-item.sh P30 audit-docker --host hsb0
#
# ARGUMENTS:
#   priority: LNN format (A00-Z99, default: P50)
#   description: kebab-case slug (default: timestamp)
#   --dir: Target directory (default: +pm/backlog/infra)
#   --host: Hostname (auto-sets dir to hosts/<host>/docs/backlog if --dir not specified)
#
# OUTPUT: {dir}/{priority}--{hash}--{description}.md

set -euo pipefail

# Get script directory for sourcing lib
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source hash generation library
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/generate-hash.sh"

# Defaults
priority=""
desc=""
dir=""
host=""

# Parse arguments
positional_args=()
while [[ $# -gt 0 ]]; do
  case $1 in
  --dir)
    dir="$2"
    shift 2
    ;;
  --host)
    host="$2"
    shift 2
    ;;
  -*)
    echo "Unknown option: $1"
    exit 1
    ;;
  *)
    positional_args+=("$1")
    shift
    ;;
  esac
done

# Restore positional parameters
set -- "${positional_args[@]}"

# Parse positional arguments
if [[ $# -ge 1 ]]; then
  priority="$1"
fi

if [[ $# -ge 2 ]]; then
  desc="$2"
fi

# Validate and default priority
if [[ -z "$priority" ]] || ! [[ "$priority" =~ ^[A-Z][0-9]{2}$ ]]; then
  if [[ -n "$priority" ]]; then
    echo "Warning: Invalid priority format '$priority' (expected LNN like P50), using P50"
  fi
  priority="P50"
fi

# Generate default description if empty
if [[ -z "$desc" ]]; then
  desc=$(date +"%Y-%m-%d-%H-%M-%S")
fi

# Determine target directory
if [[ -z "$dir" ]]; then
  if [[ -n "$host" ]]; then
    # Infer directory from host
    dir="hosts/$host/docs/backlog"
  else
    # Default to infrastructure backlog
    dir="+pm/backlog/infra"
  fi
fi

# Ensure target directory exists
mkdir -p "$dir"

# Generate unique hash (search entire repo to avoid collisions across all backlogs)
hash=$(generate_unique_hash ".")

# Build filename
filename="$dir/${priority}--${hash}--${desc}.md"

# Create template
cat >"$filename" <<EOF
# ${desc}

$(if [[ -n "$host" ]]; then echo "**Host**: $host"; fi)
**Priority**: ${priority}
**Status**: Backlog
**Created**: $(date +%Y-%m-%d)

---

## Problem

[Description]

## Solution

[Approach]

## Implementation

- [ ] Task 1
- [ ] Documentation update
- [ ] Test

## Acceptance Criteria

- [ ] Criterion 1
- [ ] Tests pass

## Notes

[Optional]
EOF

echo "Created: $filename"
