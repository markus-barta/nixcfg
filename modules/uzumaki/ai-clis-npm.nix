# Always-latest AI CLIs via npm (claude-code, codex, grok, pi)
# + exact-pinned npm tools (bird) — see ai-clis-npm-packages.json
# + the Cursor CLI (cursor-agent / agent) as a pinned Nix package (NIX-514).
#
# nixpkgs lags upstream npm by days/weeks for fast-moving AI CLIs.
# Node ships via uzumaki commonPackages; this module npm-installs the CLIs
# to private generations under ~/.npm-global, with atomic launch links.
# Every switch checks latest versions; unchanged working CLIs are not reinstalled.
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
  # Both entry points use the same package pins and install-script approvals.
  # Exact-pinned bird stays pinned; the four AI CLIs still resolve latest.
  updater = pkgs.writeShellApplication {
    name = "update-ai-clis-npm";
    runtimeInputs = [
      pkgs.nodejs
      pkgs.python3
    ];
    text = ''
      exec python3 ${../../scripts/update-ai-clis.py} \
        --packages ${./ai-clis-npm-packages.json} \
        --allow-scripts ${./ai-clis-npm-allow-scripts.json} "$@"
    '';
  };
  # Pi package (not a global npm CLI). Full-system extension → pin exact.
  # CURSOR_AGENT_PATH must be the real binary: PATH `agent` is the INSPR
  # shadow wrapper (inspr-agent-guard-shadow-bin), not Cursor. NIX-578 keeps
  # both Pi and Cursor native headless capable without guard env injection.
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
    && lib.any (name: guard.nativePrograms ? ${name}) [
      "cursor-agent"
      "agent"
    ];
in
{
  home.packages = lib.optional (!cursorGuarded) pkgs.cursor-agent;

  # NIX-521: Claude Code must not update itself. Its background updater and the
  # manual `claude update` both run a plain `npm install -g` WITHOUT the
  # allow-scripts list, which leaves ~/.npm-global/bin/claude a 500-byte stub.
  # Updates belong to the HM activation and `just update-ai-clis` only.
  #   DISABLE_AUTOUPDATER       background updater off
  #   DISABLE_UPDATES           `claude update` refuses ("disabled by your administrator")
  #   FORCE_AUTOUPDATE_PLUGINS  plugins (git/marketplace, not npm) keep updating
  home.sessionVariables.DISABLE_AUTOUPDATER = "1";
  home.sessionVariables.DISABLE_UPDATES = "1";
  home.sessionVariables.FORCE_AUTOUPDATE_PLUGINS = "1";
  home.sessionVariables.NPM_CONFIG_PREFIX = npmPrefix;
  home.sessionVariables.CURSOR_AGENT_PATH = cursorAgentPath;
  home.sessionPath = [ "${npmPrefix}/bin" ]; # bash/zsh

  # Fish needs explicit PATH wiring (HM sessionPath doesn't reach fish).
  # Prepend so npm-global wins over any older imperative installs in ~/.local/bin.
  programs.fish.shellInit = ''
    fish_add_path --prepend --move ${npmPrefix}/bin
    set -gx DISABLE_AUTOUPDATER 1
    set -gx DISABLE_UPDATES 1
    set -gx FORCE_AUTOUPDATE_PLUGINS 1
    set -gx CURSOR_AGENT_PATH ${cursorAgentPath}
  '';

  home.activation.updateAiClis = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    # Isolate umask/PATH changes from other activation entries. The updater
    # serializes installs and never gives npm the live prefix (NIX-524).
    (
      umask 022
      export PATH="${pkgs.nodejs}/bin:$PATH"
      # Repair caches left read-only by older activation generations.
      $DRY_RUN_CMD chmod -R u+w "$HOME/.npm" 2>/dev/null || true
      $DRY_RUN_CMD ${lib.getExe updater} --prefix "${npmPrefix}" \
        || echo "ai-clis-npm: update failed; prior package files retained (see updater output)."
    )
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
