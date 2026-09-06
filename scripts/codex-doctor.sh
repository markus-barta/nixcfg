#!/usr/bin/env bash
#
# codex-doctor.sh — Detect and repair Codex CLI ↔ app-server daemon version drift
#
# Usage:
#   ./scripts/codex-doctor.sh           # Report. On drift, ask "[y/N]" before the cleanup.
#   ./scripts/codex-doctor.sh --check   # Report only; never prompts; exit 1 on drift.
#   ./scripts/codex-doctor.sh --fix     # Cleanup without the question. Still refuses while
#                                       # an interactive Codex session is running.
#
# Why (NIX-435, 2026-09-06): `just update-ai-clis` bumps the npm CLI, but every
# Codex TUI attaches to a long-running app-server daemon launched from the
# standalone package under ~/.codex/packages/standalone/current. Per the
# upstream daemon docs that daemon keeps its old binary until an explicit
# restart — and it is the process that refreshes ~/.codex/models_cache.json,
# as ITS version. Seen on mbp2607: CLI 0.153.4, daemon 0.150.1, a catalog
# without gpt-6-astra, and the backend answering "requires a newer version of
# Codex" to the newest CLI. Upstream: openai/codex #31826, #42853.
#
# Drift = any of:
#   - the daemon runs a version other than the CLI
#   - the standalone package (what the next `daemon start` runs) ≠ CLI
#   - the models cache was written by a client version ≠ CLI
#   - the model configured in ~/.codex/config.toml is missing from the cache
#     although the account's refreshed catalog offers it
#
# Cleanup (only after a typed `y`, only with no interactive Codex session —
# background terminals and MCP servers are daemon children, stopping the
# daemon kills an in-flight turn):
#   1. `codex app-server daemon stop` (+ TERM for a leftover app-server or
#      code-mode-host)
#   2. trash the models cache (`trash` when present, else moved to $TMPDIR)
#   3. standalone installer pinned to the CLI version, downloaded to a temp
#      file first (never `curl | sh`) — only when a standalone package exists
#   4. `daemon start` ONLY if a daemon was running before; verify versions
#
# Never: kills a TUI, edits config.toml, touches auth.json.
#
# Exit codes:
#   0 — no drift, cleanup succeeded, or cleanup declined at the prompt
#   1 — drift with --check, cleanup refused (live sessions), or cleanup failed
#   2 — usage / environment error
#
set -euo pipefail

MODE=ask
case "${1:-}" in
"") ;;
--check) MODE=check ;;
--fix) MODE=fix ;;
-h | --help)
  sed -n '3,42p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
  ;;
*)
  echo "codex-doctor: unknown argument: $1" >&2
  exit 2
  ;;
esac

CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
CACHE="$CODEX_HOME_DIR/models_cache.json"
CONFIG="$CODEX_HOME_DIR/config.toml"
STANDALONE="$CODEX_HOME_DIR/packages/standalone/current"
INSTALLER_URL="https://chatgpt.com/codex/install.sh"

for tool in codex node ps; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "codex-doctor: '$tool' not on PATH" >&2
    exit 2
  }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-doctor.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

DRIFT=0
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() {
  printf '  \033[31m✗\033[0m %s\n' "$*"
  DRIFT=1
}
warn() { printf '  \033[33m⚠\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }

# json_get FILE DOTTED.PATH → value or empty. Reads the file (catalogs are ~1 MB,
# too big for argv). Tolerates leading junk before the first "{".
json_get() {
  node -e '
    const [file, path] = process.argv.slice(1);
    const s = require("fs").readFileSync(file, "utf8");
    let v;
    try { v = JSON.parse(s.slice(s.indexOf("{"))); } catch { process.exit(0); }
    for (const k of path.split(".")) v = v == null ? undefined : v[k];
    if (v !== undefined && v !== null) process.stdout.write(String(v));
  ' "$1" "$2" 2>/dev/null || true
}

# catalog_has FILE SLUG → exit 0 when the "models" array contains SLUG.
catalog_has() {
  node -e '
    const [file, slug] = process.argv.slice(1);
    const s = require("fs").readFileSync(file, "utf8");
    let j;
    try { j = JSON.parse(s.slice(s.indexOf("{"))); } catch { process.exit(1); }
    process.exit((j.models || []).some((m) => m.slug === slug) ? 0 : 1);
  ' "$1" "$2" 2>/dev/null
}

version_of() { # version_of BINARY → "0.153.4" or empty
  "$1" --version 2>/dev/null | awk '{print $NF}' || true
}

standalone_bin() {
  if [ -x "$STANDALONE/bin/codex" ]; then
    echo "$STANDALONE/bin/codex"
  elif [ -x "$STANDALONE/codex" ]; then
    echo "$STANDALONE/codex" # legacy flat layout
  fi
}

# PATH for the installer: $TMP/bin first, every directory holding a `codex` removed.
installer_path() {
  local d out="" parts
  IFS=: read -ra parts <<<"$PATH"
  for d in "${parts[@]}"; do
    [ -n "$d" ] && [ ! -x "$d/codex" ] && out="${out:+$out:}$d"
  done
  echo "$TMP/bin:$out"
}

daemon_json() { # → JSON from `daemon version`, written to $TMP/daemon.json
  codex app-server daemon version >"$TMP/daemon.json" 2>/dev/null || echo '{}' >"$TMP/daemon.json"
}

# Interactive or in-flight Codex sessions (TUI, `codex exec`). The daemon and
# its code-mode-host are excluded: they are what we manage. Daemon *children*
# are not a signal — the daemon keeps threads alive after a TUI detaches.
live_sessions() {
  # shellcheck disable=SC2009 # pgrep cannot express the exclusions; we need the command lines
  ps -eo pid=,command= | grep -E '(^|[/ ])codex( |$)' |
    grep -vE 'app-server|code-mode-host|codex debug|codex-doctor|grep -E' || true
}

# ── Report ───────────────────────────────────────────────────────────────────
report() {
  DRIFT=0
  CLI_BIN="$(command -v codex)"
  CLI_VER="$(version_of "$CLI_BIN")"
  [ -n "$CLI_VER" ] || {
    echo "codex-doctor: cannot read 'codex --version'" >&2
    exit 2
  }
  printf '\n\033[1mCodex doctor\033[0m  CLI %s  (%s)\n' "$CLI_VER" "$CLI_BIN"

  # Every `codex` on PATH — a second install that shadows the npm one drifts silently.
  local other_paths other_ver
  other_paths="$(which -a codex 2>/dev/null | grep -vx "$CLI_BIN" | sort -u || true)"
  if [ -n "$other_paths" ]; then
    while IFS= read -r p; do
      other_ver="$(version_of "$p")"
      if [ "$other_ver" = "$CLI_VER" ]; then
        warn "another codex on PATH: $p ($other_ver) — same version today, will drift"
      else
        bad "another codex on PATH: $p (${other_ver:-unreadable}) ≠ CLI $CLI_VER"
      fi
    done <<<"$other_paths"
  else
    ok "single codex on PATH"
  fi

  # Standalone package = what `daemon start` will run.
  SA_BIN="$(standalone_bin)"
  SA_VER=""
  if [ -n "$SA_BIN" ]; then
    SA_VER="$(version_of "$SA_BIN")"
    if [ "$SA_VER" = "$CLI_VER" ]; then
      ok "standalone package $SA_VER matches CLI"
    else
      bad "standalone package ${SA_VER:-unreadable} ≠ CLI $CLI_VER ($STANDALONE)"
    fi
  else
    info "no standalone package (daemon cannot be started; TUI runs embedded)"
  fi

  # Running daemon.
  daemon_json
  DAEMON_STATUS="$(json_get "$TMP/daemon.json" status)"
  DAEMON_VER="$(json_get "$TMP/daemon.json" appServerVersion)"
  if [ "$DAEMON_STATUS" = "running" ]; then
    if [ "$DAEMON_VER" = "$CLI_VER" ]; then
      ok "app-server daemon running on $DAEMON_VER"
    else
      bad "app-server daemon running on ${DAEMON_VER:-?} ≠ CLI $CLI_VER (serves the model catalog to every TUI)"
    fi
  else
    info "app-server daemon not running (status: ${DAEMON_STATUS:-unknown})"
  fi

  # Models cache = the catalog the TUI trusts at startup.
  CACHE_VER=""
  if [ -f "$CACHE" ]; then
    CACHE_VER="$(json_get "$CACHE" client_version)"
    if [ "$CACHE_VER" = "$CLI_VER" ]; then
      ok "models cache written by client $CACHE_VER"
    else
      bad "models cache written by client ${CACHE_VER:-?} ≠ CLI $CLI_VER ($CACHE)"
    fi
  else
    info "no models cache yet (first run writes it)"
  fi

  # Configured model must be in the cache when the account's live catalog offers it.
  # NOTE: `codex debug models` rewrites the cache as the CLI's version, so this
  # check must stay AFTER the cache check above or it would mask cache drift.
  CFG_MODEL="$(sed -n 's/^model[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG" 2>/dev/null | head -1 || true)"
  if [ -n "$CFG_MODEL" ]; then
    if codex debug models >"$TMP/catalog.json" 2>/dev/null && catalog_has "$TMP/catalog.json" "$CFG_MODEL"; then
      if [ -f "$CACHE" ] && catalog_has "$CACHE" "$CFG_MODEL"; then
        ok "configured model '$CFG_MODEL' in live catalog and cache"
      elif [ -f "$CACHE" ]; then
        bad "configured model '$CFG_MODEL' offered by the live catalog but MISSING from the cache"
      else
        ok "configured model '$CFG_MODEL' in live catalog"
      fi
    else
      warn "configured model '$CFG_MODEL' not in this account's live catalog (entitlement/rollout, not drift)"
    fi
  else
    info "no top-level model in $CONFIG (bundled default applies)"
  fi
  echo
}

# ── Cleanup ──────────────────────────────────────────────────────────────────
wait_gone() { # wait_gone SECONDS PATTERN → 0 when no process matches
  local i
  for ((i = 0; i < $1; i++)); do
    pgrep -f "$2" >/dev/null 2>&1 || return 0
    sleep 1
  done
  ! pgrep -f "$2" >/dev/null 2>&1
}

cleanup() {
  local was_running="$1" pat='codex app-server|codex-code-mode-host' ts
  echo "Cleanup:"

  if [ "$was_running" = running ]; then
    info "stopping app-server daemon"
    codex app-server daemon stop >/dev/null 2>&1 || true
  fi
  if ! wait_gone 10 "$pat"; then
    info "sending TERM to leftover app-server/code-mode-host"
    pkill -TERM -f "$pat" 2>/dev/null || true
    wait_gone 10 "$pat" || {
      bad "app-server/code-mode-host still alive; not continuing"
      pgrep -fl "$pat" || true
      return 1
    }
  fi
  ok "no app-server / code-mode-host running"

  if [ -f "$CACHE" ]; then
    if command -v trash >/dev/null 2>&1; then
      trash "$CACHE" && ok "models cache trashed"
    else
      ts="$(date +%Y%m%dT%H%M%S)"
      mv "$CACHE" "${TMPDIR:-/tmp}/codex-models_cache.$ts.json" && ok "models cache moved to ${TMPDIR:-/tmp}/codex-models_cache.$ts.json"
    fi
  fi

  if [ -n "$(standalone_bin)" ]; then
    info "installing standalone package pinned to $CLI_VER (installer downloaded to $TMP)"
    if ! curl -fsSL "$INSTALLER_URL" -o "$TMP/install.sh"; then
      bad "could not download $INSTALLER_URL"
      return 1
    fi
    # The installer also wants to be the user-facing CLI: it symlinks
    # $CODEX_INSTALL_DIR/codex (default ~/.local/bin) and, whenever it sees
    # another `codex` via `command -v`, appends a PATH block to ~/.zprofile.
    # We only want the managed package refreshed for the daemon, so: symlink
    # into a temp dir that is already on PATH, and hide every other codex.
    mkdir -p "$TMP/bin"
    if ! CODEX_INSTALL_DIR="$TMP/bin" CODEX_NON_INTERACTIVE=1 PATH="$(installer_path)" \
      sh "$TMP/install.sh" --release "$CLI_VER" >"$TMP/install.log" 2>&1; then
      cp "$TMP/install.log" "${TMPDIR:-/tmp}/codex-doctor-install.log"
      bad "installer failed — log: ${TMPDIR:-/tmp}/codex-doctor-install.log"
      tail -20 "$TMP/install.log"
      return 1
    fi
    ok "standalone package now $(version_of "$(standalone_bin)")"
  fi

  if [ "$was_running" = running ]; then
    info "starting app-server daemon"
    if ! codex app-server daemon start >/dev/null 2>&1; then
      bad "daemon start failed"
      return 1
    fi
    daemon_json
    if [ "$(json_get "$TMP/daemon.json" appServerVersion)" = "$CLI_VER" ]; then
      ok "app-server daemon restarted on $CLI_VER"
    else
      bad "daemon restarted but reports $(json_get "$TMP/daemon.json" appServerVersion) ≠ $CLI_VER"
      return 1
    fi
  else
    info "daemon was not running before — leaving it stopped (TUI runs embedded)"
  fi
  return 0
}

manual_steps() {
  cat <<STEPS
Manual steps (when no Codex session is running):
  codex app-server daemon stop
  pgrep -fl 'codex app-server|codex-code-mode-host'   # must be empty; kill -TERM survivors
  trash ~/.codex/models_cache.json
  curl -fsSL $INSTALLER_URL -o /tmp/codex-install.sh && CODEX_NON_INTERACTIVE=1 sh /tmp/codex-install.sh --release $CLI_VER
  codex app-server daemon start && codex app-server daemon version   # appServerVersion must equal cliVersion
STEPS
}

# ── Main ─────────────────────────────────────────────────────────────────────
report
if [ "$DRIFT" -eq 0 ]; then
  echo "No drift."
  exit 0
fi

if [ "$MODE" = check ]; then
  echo "Drift detected (--check: not fixing)."
  manual_steps
  exit 1
fi

LIVE="$(live_sessions)"
if [ -n "$LIVE" ]; then
  printf '\033[31mRefusing the cleanup: interactive Codex sessions are running.\033[0m\n'
  echo "Stopping the daemon would kill their in-flight turns. Finish or quit them, then rerun."
  echo "$LIVE" | sed 's/^/  /' | cut -c1-140
  exit 1
fi

if [ "$MODE" = ask ]; then
  if [ ! -t 0 ]; then
    echo "stdin is not a terminal — not asking. Rerun with --fix to apply."
    manual_steps
    exit 1
  fi
  printf 'Run the cleanup now? stop daemon → trash cache → reinstall standalone %s → restart daemon only if it was running [y/N] ' "$CLI_VER"
  IFS= read -r -n 1 ANSWER || ANSWER=""
  echo
  case "$ANSWER" in
  y | Y) ;;
  *)
    echo "Declined (nothing changed)."
    manual_steps
    exit 0
    ;;
  esac
fi

if cleanup "$DAEMON_STATUS"; then
  echo
  report
  if [ "$DRIFT" -eq 0 ]; then
    echo "Fixed."
    exit 0
  fi
  echo "Cleanup ran but drift remains — see ✗ lines above."
  exit 1
fi
echo "Cleanup failed — see ✗ lines above."
exit 1
