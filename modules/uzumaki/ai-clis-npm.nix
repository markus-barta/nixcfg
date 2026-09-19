# Always-latest AI CLIs via npm (claude-code, codex, grok, pi)
# + exact-pinned npm tools (bird) — see npmPkgsPinned below
# + the Cursor CLI (cursor-agent / agent) as a pinned Nix package (NIX-514).
#
# nixpkgs lags upstream npm by days/weeks for fast-moving AI CLIs.
# Node ships via uzumaki commonPackages; this module npm-installs the CLIs
# to ~/.npm-global on every home-manager switch.
#
# Cursor is a native vendor tarball, not an npm package: pkgs/cursor-agent pins
# it by hash (the nixpkgs cursor-cli lags by months). It replaces the imperative
# `curl https://cursor.com/install | bash` copy in ~/.local/share/cursor-agent.
#
# Bump on demand: `just update-ai-clis` (also runs scripts/codex-doctor.sh: the Codex
# app-server daemon must be restarted on the new binary, NIX-435). For Cursor it
# rewrites pkgs/cursor-agent/sources.json (scripts/update-cursor-agent.sh); that
# is a repo change, active after commit + `just switch`.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  npmPrefix = "${config.home.homeDirectory}/.npm-global";
  npmPkgs = [
    "@anthropic-ai/claude-code"
    "@openai/codex"
    "@xai-official/grok" # xAI Grok Build CLI; armv6 unsupported (npm EBADPLATFORM, soft-fails)
    "@earendil-works/pi-coding-agent" # pi.dev coding agent (bin: pi); pure-JS, no install scripts — vendor suggests --ignore-scripts but it's a no-op here
  ];
  # Exact-pinned npm tools — NEVER @latest. For frozen/withdrawn upstreams or
  # credential-holding tools where a hijacked release would be catastrophic.
  # `just update-ai-clis` does not touch these; bump the pin here deliberately.
  npmPkgsPinned = [
    "@steipete/bird@0.8.0" # X cookie-transport CLI (birdclaw live sync, 2026-08-06). Upstream frozen, repo withdrawn; holds full X session cookies → pin exact version
  ];
  npmPkgsLatest = lib.concatMapStringsSep " " (p: "${p}@latest") npmPkgs;
  # NIX-517: the same allow-list `just update-ai-clis` passes. Without it npm
  # skips these install scripts, so a switch that crosses a release leaves the
  # claude placeholder stub and a stale ~/.grok/bin. The pinned bird tool gets
  # no install scripts.
  npmAllowScriptsList = (lib.importJSON ./ai-clis-npm-allow-scripts.json).allowScripts;
  npmAllowScripts = lib.concatStringsSep "," npmAllowScriptsList;
  npmPkgsPinnedStr = lib.concatStringsSep " " npmPkgsPinned;
  # Pi package (not a global npm CLI). Full-system extension → pin exact.
  # CURSOR_AGENT_PATH must be the real binary: PATH `agent` is the INSPR
  # shadow wrapper (inspr-agent-guard-shadow-bin), not Cursor. Pi itself runs
  # under its own guard shim, so the Cursor child inherits the guard env anyway.
  # The store path keeps Pi on the same release as the guard shims and agentd.
  piCursorProvider = "@netandreus/pi-cursor-provider@0.1.4";
  cursorAgentPath = lib.getExe pkgs.cursor-agent;
  # Where the NIX-445 guard owns `cursor-agent`/`agent` (its shadow-bin
  # launchers exec this same package), the package must stay out of the
  # profile: in a fish login shell ~/.nix-profile/bin lands ahead of the guard
  # directory and would win PATH unguarded (measured on mbp2607, 2026-09-19).
  guard = config.uzumaki.agentBrowserGuard;
  cursorGuarded =
    guard.enable
    && lib.any (name: guard.envOnlyPrograms ? ${name}) [
      "cursor-agent"
      "agent"
    ];
in
{
  home.packages = lib.optional (!cursorGuarded) pkgs.cursor-agent;

  home.sessionVariables.NPM_CONFIG_PREFIX = npmPrefix;
  home.sessionVariables.CURSOR_AGENT_PATH = cursorAgentPath;
  home.sessionPath = [ "${npmPrefix}/bin" ]; # bash/zsh

  # Fish needs explicit PATH wiring (HM sessionPath doesn't reach fish).
  # Prepend so npm-global wins over any older imperative installs in ~/.local/bin.
  programs.fish.shellInit = ''
    fish_add_path --prepend --move ${npmPrefix}/bin
    set -gx CURSOR_AGENT_PATH ${cursorAgentPath}
  '';

  home.activation.updateAiClis = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    # Reset umask. `inspr.secrets.agents` activation runs before us and sets
    # `umask 0277` (so decrypted env files default to mode 0400 — see
    # inspr-modules/modules/home-manager/agent-secrets.nix). That umask
    # leaks into subsequent activation steps; without this reset, every
    # file npm writes to ~/.npm/_cacache lands as mode 0400, which then
    # blocks the NEXT `npm install` from updating the same cache index
    # path with EACCES. Confirmed root cause 2026-05-13 (Day-11 wrap)
    # after an evening of misdiagnosis as "root-owned cache files" per
    # the misleading npm error message.
    umask 022
    export PATH="${pkgs.nodejs}/bin:$PATH"
    export NPM_CONFIG_PREFIX="${npmPrefix}"
    mkdir -p "${npmPrefix}"
    # Belt-and-suspenders: pre-flip any existing read-only cache files
    # to writable (covers state already corrupted by prior runs under
    # the bad umask). Cheap + idempotent.
    chmod -R u+w "$HOME/.npm" 2>/dev/null || true
    echo "📦 ai-clis-npm: bumping to latest…"
    $DRY_RUN_CMD ${pkgs.nodejs}/bin/npm i -g ${lib.escapeShellArg "--allow-scripts=${npmAllowScripts}"} \
      ${npmPkgsLatest} ${npmPkgsPinnedStr} \
      || echo "⚠️  ai-clis-npm: npm update failed (offline?). Existing versions kept."
  '';

  home.activation.installPiCursorProvider = lib.hm.dag.entryAfter [ "updateAiClis" ] ''
    umask 022
    export PATH="${npmPrefix}/bin:${pkgs.nodejs}/bin:$PATH"
    export NPM_CONFIG_PREFIX="${npmPrefix}"
    if [ -x "${npmPrefix}/bin/pi" ]; then
      echo "📦 ai-clis-npm: ensuring ${piCursorProvider}…"
      $DRY_RUN_CMD ${npmPrefix}/bin/pi install npm:${piCursorProvider} \
        || echo "⚠️  ai-clis-npm: pi-cursor-provider install failed (offline?). Existing install kept."
    fi
  '';
}
