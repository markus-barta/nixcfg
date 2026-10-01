#!/usr/bin/env bash
# Compatibility command for stasysmod. Never used by the prompt compositor.
# Formatting/validation remains in the fish-native reader, including hostile
# snapshot handling. Bash supplies a builtin epoch (no date child).
set -euo pipefail
printf -v STASYSMO_NOW '%(%s)T' -1
export STASYSMO_NOW
exec "${STASYSMO_FISH:-fish}" --no-config "$STASYSMO_READER_CONFIG"
