# Always-latest AI CLIs via npm (claude-code, codex)
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
  ];
  npmPkgsLatest = lib.concatMapStringsSep " " (p: "${p}@latest") npmPkgs;
in
{
  home.sessionVariables.NPM_CONFIG_PREFIX = npmPrefix;
  home.sessionPath = [ "${npmPrefix}/bin" ];

  home.activation.updateAiClis = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    export PATH="${pkgs.nodejs}/bin:$PATH"
    export NPM_CONFIG_PREFIX="${npmPrefix}"
    mkdir -p "${npmPrefix}"
    echo "📦 ai-clis-npm: bumping to latest…"
    $DRY_RUN_CMD ${pkgs.nodejs}/bin/npm i -g --silent ${npmPkgsLatest} \
      || echo "⚠️  ai-clis-npm: npm update failed (offline?). Existing versions kept."
  '';
}
