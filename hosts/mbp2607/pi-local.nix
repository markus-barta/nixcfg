# Local inference stays in MTPLX's installed runtime; Nix owns the launcher and Pi profile.
{ config, pkgs, ... }:
let
  modelId = "mtplx-qwen38-27b-optimized-speed";
  contextWindow = 262144;
  agentDir = "${config.home.homeDirectory}/.local/share/pi-local/agent";
  launcherConfig = pkgs.writeText "pi-local.json" (
    builtins.toJSON {
      inherit modelId contextWindow agentDir;
      modelPath = "${config.home.homeDirectory}/.mtplx/models/Youssofal--Qwen3.8-27B-MTPLX-Optimized-Speed";
      mtplx = "${config.home.homeDirectory}/.mtplx/bin/mtplx";
      pi = "${config.home.homeDirectory}/.npm-global/bin/pi";
      extension = "${./files/pi-local-context.js}";
    }
  );
  launcher = pkgs.writeShellScriptBin "pi-local" ''
    exec ${pkgs.python3}/bin/python3 ${./files/pi-local.py} ${launcherConfig} "$@"
  '';
in
{
  home.packages = [ launcher ];
  programs.fish.functions.pi-local = {
    description = "Start/reuse MTPLX and run Pi in the current directory (Qwen 3.8, MTP, 262K)";
    body = "${launcher}/bin/pi-local $argv";
  };
  # Keep ordinary Pi credentials/settings separate. Pi may write its own settings
  # and sessions here; only the model definition is immutable.
  home.file.".local/share/pi-local/agent/models.json".text = builtins.toJSON {
    providers.mtplx = {
      api = "openai-completions";
      baseUrl = "http://127.0.0.1:8000/v1";
      apiKey = "mtplx-local"; # Non-secret placeholder for the localhost API.
      authHeader = true;
      headers.x-mtplx-client = "pi";
      compat = {
        maxTokensField = "max_tokens";
        supportsDeveloperRole = false;
        supportsReasoningEffort = true;
        thinkingFormat = "qwen";
      };
      models = [
        {
          id = modelId;
          name = "Local Qwen 3.8 27B · MTPLX MTP · 262K";
          inherit contextWindow;
          maxTokens = 32768;
          reasoning = true;
          thinkingLevelMap = {
            minimal = null;
            high = "xhigh";
            xhigh = "xhigh";
            max = "xhigh";
          };
          input = [
            "text"
            "image"
          ];
          samplingParams = {
            temperature = 1.0;
            top_p = 0.95;
            top_k = 20;
          };
          cost = {
            input = 0;
            output = 0;
            cacheRead = 0;
            cacheWrite = 0;
          };
        }
      ];
    };
  };
}
