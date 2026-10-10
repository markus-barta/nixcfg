#!/usr/bin/env bash
#
# codex-doctor.sh — Detect and repair Codex CLI ↔ app-server daemon version drift
#
# Usage:
#   ./scripts/codex-doctor.sh           # Report. On drift, ask "[y/N]" before the repair.
#   ./scripts/codex-doctor.sh --check   # Report only; never prompts; exit 1 on drift.
#   ./scripts/codex-doctor.sh --fix     # Repair without the question. Still refuses while
#                                       # a daemon-attached Codex session is running.
#   ./scripts/codex-doctor.sh --after-update # Repair without asking when no daemon-attached
#                                            # session runs; defer successfully otherwise.
#                                            # Repair failures still fail.
#
# Why (NIX-435, 2026-09-06): `just update-ai-clis` bumps the npm CLI, but every
# Codex TUI attaches to a long-running app-server daemon. Per the upstream
# daemon docs that daemon keeps its old binary until it is replaced and
# restarted — and it is the process that refreshes ~/.codex/models_cache.json,
# as ITS version. Seen on mbp2607: CLI 0.153.4, daemon 0.150.1, a catalog
# without gpt-6-astra, and the backend answering "requires a newer version of
# Codex" to the newest CLI. Upstream: openai/codex #31826, #42853.
#
# NIX-609 (2026-10-10): the daemon still ran 0.158.0 from the legacy standalone
# package twelve days after the CLI moved on, and the backend refused
# gpt-6.1-sol to it as "not supported when using Codex with a ChatGPT account".
# The repair never ran: every `codex exec` worker counted as a live session,
# and agents' non-interactive updates always deferred.
#
# Daemon package: `codex app-server daemon version` names it (managedCodexPath,
# managedCodexVersion). Since 0.162, `daemon update` moves it into a dedicated
# package (~/.codex/packages/app-server-daemon) that keeps itself current with
# its own update loop, so the daemon may run NEWER than the CLI; only older is
# drift. The legacy standalone package (~/.codex/packages/standalone) has no
# working update loop: a daemon still managed from there is drift even at the
# CLI version. After the move the standalone package stays behind, unused.
#
# Drift = any of:
#   - the daemon runs a version older than the CLI
#   - the daemon package (what the next `daemon start` runs) is older than the
#     CLI, or is the legacy standalone package
#   - the models cache was written by a client version older than the CLI
# Missing configured models are warnings: availability may depend on the account
# or provider, so a missing model alone must never trigger a repair.
# Reports never refresh the cache; only a repair does.
#
# Repair (only with no daemon-attached Codex session — `daemon update` restarts
# the daemon, which ends their in-flight turns; `codex exec` runs its own
# app-server in-process and is never touched):
#   1. `codex app-server daemon update --yes` — upstream installs the current
#      release into the dedicated package and restarts the daemon
#   2. `codex debug models` refreshes the models cache; then report again
#
# Never: kills a process, edits config.toml, touches auth.json.
#
# Exit codes:
#   0 — no drift, repair succeeded/declined, or --after-update repair deferred
#   1 — drift with --check, repair refused (live sessions), or repair failed
#   2 — usage / environment error
#
set -euo pipefail

MODE=ask
[ "$#" -le 1 ] || {
  echo "codex-doctor: expected at most one option" >&2
  exit 2
}
case "${1:-}" in
"") ;;
--check) MODE=check ;;
--fix) MODE=fix ;;
--after-update) MODE=after-update ;;
-h | --help)
  sed -n '/^# codex-doctor.sh/,/^set -euo pipefail/{ /^#/s/^# \{0,1\}//p; }' "$0"
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
DEDICATED="$CODEX_HOME_DIR/packages/app-server-daemon/current"
STANDALONE="$CODEX_HOME_DIR/packages/standalone/current"

for tool in codex node ps; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "codex-doctor: '$tool' not on PATH" >&2
    exit 2
  }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-doctor.XXXXXX")"
# Leave diagnostics in the per-user system temp directory for OS cleanup.
# Do not retain process command lines here or move diagnostics into the Trash.

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

# older_than_cli VERSION → exit 0 when VERSION is older than $CLI_VER. Numeric
# dotted parts; a pre-release suffix sorts before its release. An empty or
# unparseable version counts as older, so it can never hide drift.
older_than_cli() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.]+)?$ ]] || return 0
  node -e '
    const parse = (v) => { const i = v.indexOf("-");
      return [(i < 0 ? v : v.slice(0, i)).split(".").map(Number), i >= 0]; };
    const [[a, aPre], [b, bPre]] = process.argv.slice(1).map(parse);
    for (let i = 0; i < Math.max(a.length, b.length); i++) {
      const x = a[i] || 0, y = b[i] || 0;
      if (x !== y) process.exit(x < y ? 0 : 1);
    }
    process.exit(aPre && !bPre ? 0 : 1);
  ' "$1" "$CLI_VER"
}

standalone_bin() {
  if [ -x "$STANDALONE/bin/codex" ]; then
    echo "$STANDALONE/bin/codex"
  elif [ -x "$STANDALONE/codex" ]; then
    echo "$STANDALONE/codex" # legacy flat layout
  fi
}

daemon_json() { # → JSON from `daemon version`, written to $TMP/daemon.json
  codex app-server daemon version >"$TMP/daemon.json" 2>/dev/null || echo '{}' >"$TMP/daemon.json"
}

# Daemon-attached Codex clients: the TUI (with or without a prompt), resume,
# fork, agents, queue, remote-control, … — every codex command except the
# daemon itself and `codex exec`. exec runs its own in-process app-server and
# never attaches (NIX-609: no daemon-socket descriptor on live exec workers;
# a daemon update left them running). `exec --remote` does attach. Unknown
# subcommands count as attached: a new client type blocks the repair rather
# than losing a turn.
live_sessions() {
  # Match the executable and subcommand, not words in a user's prompt.
  # pipefail preserves a ps failure without storing its output on disk.
  if ! ps -eo pid=,command= | awk '
    function basename(path) { sub(/^.*\//, "", path); return path }
    {
      executable = 2
      if (basename($executable) == "node") executable++
      if (basename($executable) != "codex") next
      subcommand = $(executable + 1)
      if (subcommand == "app-server" || subcommand == "debug" ||
          subcommand == "--version" || subcommand == "--help") next
      if (subcommand == "exec" || subcommand == "e") {
        attached = 0
        for (i = executable + 2; i <= NF; i++)
          if ($i == "--remote" || $i ~ /^--remote=/) attached = 1
        if (!attached) next
      }
      print $1, "codex session"
    }
  '; then
    echo "codex-doctor: cannot inspect live sessions; refusing repair" >&2
    return 2
  fi
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

  # Daemon package = what `daemon start` will run. The daemon names it; older
  # CLIs do not, so fall back to the dedicated, then the legacy location.
  daemon_json
  local pkg_path pkg_ver legacy_bin
  pkg_path="$(json_get "$TMP/daemon.json" managedCodexPath)"
  pkg_ver="$(json_get "$TMP/daemon.json" managedCodexVersion)"
  legacy_bin="$(standalone_bin)"
  if [ -z "$pkg_path" ]; then
    if [ -x "$DEDICATED/bin/codex" ]; then
      pkg_path="$DEDICATED/bin/codex"
    else
      pkg_path="$legacy_bin"
    fi
    [ -z "$pkg_path" ] || pkg_ver="$(version_of "$pkg_path")"
  fi
  if [ -z "$pkg_path" ]; then
    info "no daemon package (daemon cannot be started; TUI runs embedded)"
  else
    case "$pkg_path" in
    */packages/standalone/*)
      bad "daemon package is the legacy standalone package ${pkg_ver:-unreadable} (no update loop; the repair moves it to the dedicated package)"
      ;;
    *)
      if older_than_cli "$pkg_ver"; then
        bad "daemon package ${pkg_ver:-unreadable} older than CLI $CLI_VER ($pkg_path)"
      elif [ "$pkg_ver" = "$CLI_VER" ]; then
        ok "daemon package $pkg_ver matches CLI"
      else
        ok "daemon package $pkg_ver newer than CLI (upstream update loop)"
      fi
      if [ -n "$legacy_bin" ]; then
        info "legacy standalone package $(version_of "$legacy_bin") left behind by the move; unused"
      fi
      ;;
    esac
  fi

  # Running daemon.
  DAEMON_STATUS="$(json_get "$TMP/daemon.json" status)"
  DAEMON_VER="$(json_get "$TMP/daemon.json" appServerVersion)"
  if [ "$DAEMON_STATUS" = "running" ]; then
    if older_than_cli "$DAEMON_VER"; then
      bad "app-server daemon running on ${DAEMON_VER:-?}, older than CLI $CLI_VER (serves the model catalog to every TUI)"
    else
      ok "app-server daemon running on $DAEMON_VER"
    fi
  else
    info "app-server daemon not running (status: ${DAEMON_STATUS:-unknown})"
  fi

  # Models cache = the catalog the TUI trusts at startup.
  CACHE_VER=""
  if [ -f "$CACHE" ]; then
    CACHE_VER="$(json_get "$CACHE" client_version)"
    if older_than_cli "$CACHE_VER"; then
      bad "models cache written by client ${CACHE_VER:-?}, older than CLI $CLI_VER ($CACHE)"
    else
      ok "models cache written by client $CACHE_VER"
    fi
  else
    info "no models cache yet (first run writes it)"
  fi

  # Check the existing cache only. `codex debug models` rewrites it, which
  # would mask drift and mutate state even in --check or a deferred update.
  CFG_MODEL="$(sed -n 's/^model[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG" 2>/dev/null | head -1 || true)"
  if [ -n "$CFG_MODEL" ]; then
    if [ ! -f "$CACHE" ]; then
      info "configured model '$CFG_MODEL' (no cache to check yet)"
    elif catalog_has "$CACHE" "$CFG_MODEL"; then
      ok "configured model '$CFG_MODEL' in cache"
    else
      warn "configured model '$CFG_MODEL' missing from cache (account/provider availability not verified; no repair for this alone)"
    fi
  else
    info "no top-level model in $CONFIG (bundled default applies)"
  fi
  echo
}

# ── Repair ───────────────────────────────────────────────────────────────────
repair() {
  echo "Repair:"
  info "codex app-server daemon update --yes"
  if ! codex app-server daemon update --yes >"$TMP/update.log" 2>&1; then
    cp "$TMP/update.log" "${TMPDIR:-/tmp}/codex-doctor-update.log"
    bad "daemon update failed — log: ${TMPDIR:-/tmp}/codex-doctor-update.log"
    tail -5 "$TMP/update.log"
    return 1
  fi
  ok "daemon package updated"
}

manual_steps() {
  cat <<STEPS
After closing Codex TUI sessions (exec workers may keep running), run from a regular terminal in nixcfg:
  just codex-doctor --fix
  just codex-doctor --check
STEPS
}

defer_repair() {
  warn "AI CLI update completed; Codex repair deferred: $1."
  echo "The running Codex runtime has not been upgraded."
  manual_steps
  exit 0
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
  if [ "$MODE" = after-update ]; then
    defer_repair "Codex sessions are attached to the daemon"
  fi
  printf '\033[31mRefusing the repair: daemon-attached Codex sessions are running.\033[0m\n'
  echo "Updating the daemon would end their in-flight turns. Finish or quit them, then rerun."
  echo "$LIVE" | sed 's/^/  /' | cut -c1-140
  exit 1
fi

if [ "$MODE" = ask ]; then
  if [ ! -t 0 ]; then
    echo "stdin is not a terminal — not asking. Rerun with --fix to apply."
    manual_steps
    exit 1
  fi
  printf 'Run the repair now? codex app-server daemon update → refresh models cache [y/N] '
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

# A session may have started while the user was reading the prompt.
LIVE="$(live_sessions)"
if [ -n "$LIVE" ]; then
  if [ "$MODE" = after-update ]; then
    defer_repair "a Codex session attached before the repair"
  fi
  echo "Refusing the repair: a Codex session attached before the repair." >&2
  exit 1
fi

if repair; then
  if ! codex debug models >"$TMP/catalog.json" 2>/dev/null; then
    warn "could not refresh model catalog; the next Codex session will retry"
  fi
  echo
  report
  if [ "$DRIFT" -eq 0 ]; then
    echo "Fixed."
    exit 0
  fi
  echo "Repair ran but drift remains — see ✗ lines above."
  exit 1
fi
echo "Repair failed — see ✗ lines above."
exit 1
