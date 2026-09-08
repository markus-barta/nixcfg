# Nix owns Pi launchers and doctrine loading; provider credentials stay mutable.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  pi = "${config.home.homeDirectory}/.npm-global/bin/pi";
  agentDir = "${config.home.homeDirectory}/.local/share/pi-local/agent";
  launcherScript = pkgs.writeText "pi-local.py" (
    builtins.replaceStrings
      [ ''"@PI_LOCAL_CONFIG@"'' ]
      [
        (builtins.toJSON (
          builtins.toJSON {
            inherit agentDir;
            inherit pi;
            extension = "${./files/pi-local-context.js}";
            providerExtension = "${./files/pi-local-provider.js}";
            telemetryExtension = "${./files/pi-local-telemetry.js}";
          }
        ))
      ]
      (builtins.readFile ./files/pi-local.py)
  );
  # NIX-445: both launchers run under the agent browser guard when the host
  # enables it, so a Pi session cannot execute a native browser. The guard is a
  # prefix only — argv, environment and the Pi auth home are untouched.
  guard = config.uzumaki.agentBrowserGuard;
  guardPrefix = lib.optionalString guard.enable "${lib.escapeShellArg guard.guardCommand} ";
  launcher = pkgs.writeShellScriptBin "pi-local" ''
    exec ${guardPrefix}${pkgs.python3}/bin/python3 ${launcherScript} "$@"
  '';
  chatgptLauncher = pkgs.writeShellScriptBin "pi-chatgpt" ''
    export PI_CODING_AGENT_DIR=${lib.escapeShellArg agentDir}
    export PI_TELEMETRY=0
    unset PI_LOCAL_CONNECTION
    exec ${guardPrefix}${lib.escapeShellArg pi} --offline \
      --provider openai-codex --model gpt-5.6-terra --thinking low \
      --extension ${./files/pi-local-context.js} "$@"
  '';
in
{
  home.packages = [
    launcher
    chatgptLauncher
  ];
  programs.fish.functions.pi-local = {
    description = "Run Pi here using the MTPLX app engine and its settings";
    body = "${launcher}/bin/pi-local $argv";
  };
  programs.fish.functions.pi-chatgpt = {
    description = "Run Pi here with the ChatGPT subscription and shared Pi sessions";
    body = "${chatgptLauncher}/bin/pi-chatgpt $argv";
  };
  # Only Astra's client context budget is overridden. MTPLX metadata remains
  # app-discovered; OAuth credentials and Pi's compaction settings stay mutable.
  home.file.".local/share/pi-local/agent/models.json".text = builtins.toJSON {
    providers.openai-codex.modelOverrides.gpt-6-astra.contextWindow = 750000;
  };
}
