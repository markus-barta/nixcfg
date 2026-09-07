{
  root,
  accountsFile ? null,
  lifecycleFile ? null,
  reporting ? false,
}:
let
  flake = builtins.getFlake (toString root);
  system = "aarch64-darwin";
  pkgs = import flake.inputs.nixpkgs {
    inherit system;
    config.allowUnfree = true;
    overlays = [
      (_final: prev: {
        paimos-cli = prev.runCommand "paimos-cli" { } ''
          mkdir -p $out/bin
          touch $out/bin/paimos $out/bin/paimos-agentd
          chmod +x $out/bin/paimos $out/bin/paimos-agentd
        '';
        claude-agent-sdk =
          prev.runCommand "claude-agent-sdk"
            {
              passthru.sdkRelativePath = "lib/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs";
            }
            ''
              mkdir -p $out/lib/node_modules/@anthropic-ai/claude-agent-sdk
              touch $out/lib/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs
            '';
      })
    ];
  };
  evaluated = flake.inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      (root + "/modules/uzumaki/paimos-agentd.nix")
      {
        home.username = "fixture-user";
        home.homeDirectory = "/Users/fixture-user";
        home.stateVersion = "25.05";
        news.display = "silent";
        uzumaki.paimosAgentd = {
          enable = true;
          codexAccountsFile = accountsFile;
          lifecycleConfigFile = lifecycleFile;
          reporting = {
            enable = reporting;
            host = if reporting then "fixture-host" else "";
            url = if reporting then "https://fixture.example.test" else "";
            apiKeyEnvFile =
              if reporting then "/Users/fixture-user/Library/Caches/paimos/agentd/fixture-api-key.env" else "";
          };
        };
      }
    ];
  };
  lib = pkgs.lib;
  cfg = evaluated.config;
  args = cfg.launchd.agents.paimos-agentd.config.ProgramArguments;
  flagAfter =
    flag:
    let
      indexed = lib.imap0 (i: v: { inherit i v; }) args;
      matches = builtins.filter (item: item.v == flag) indexed;
    in
    if matches == [ ] then null else builtins.elemAt args ((builtins.head matches).i + 1);
in
{
  failedAssertionMessages = map (item: item.message) (
    builtins.filter (item: !item.assertion) cfg.assertions
  );
  programArguments = args;
  environmentVariables = cfg.launchd.agents.paimos-agentd.config.EnvironmentVariables or null;
  codexAccountsValue = flagAfter "--codex-accounts";
  lifecycleConfigValue = flagAfter "--lifecycle-config";
  codexLauncher = flagAfter "--codex-path";
  activation = cfg.home.activation.paimosAgentdCodexAccounts.data;
}
