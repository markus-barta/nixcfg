# Always-latest AI CLIs via npm (claude-code, codex, grok, pi)
# + exact-pinned npm tools (bird) — see npmPkgsPinned below.
#
# nixpkgs lags upstream npm by days/weeks for fast-moving AI CLIs.
# Node ships via uzumaki commonPackages; this module npm-installs the CLIs
# to ~/.npm-global on every home-manager switch.
#
# Bump on demand: `just update-ai-clis`
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
  npmPkgsPinnedStr = lib.concatStringsSep " " npmPkgsPinned;
in
{
  home.sessionVariables.NPM_CONFIG_PREFIX = npmPrefix;
  home.sessionPath = [ "${npmPrefix}/bin" ]; # bash/zsh

  # Fish needs explicit PATH wiring (HM sessionPath doesn't reach fish).
  # Prepend so npm-global wins over any older imperative installs in ~/.local/bin.
  programs.fish.shellInit = ''
    fish_add_path --prepend --move ${npmPrefix}/bin
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
    $DRY_RUN_CMD ${pkgs.nodejs}/bin/npm i -g ${npmPkgsLatest} ${npmPkgsPinnedStr} \
      || echo "⚠️  ai-clis-npm: npm update failed (offline?). Existing versions kept."
  '';
}
