{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.inspr.hausnetzCdOrchestrator;
  home = config.home.homeDirectory;
  stateDir = "${home}/.local/share/ops-qa/state";
  source = ../../modules/hausnetz-cd;
  settings = pkgs.writeText "hausnetz-cd-orchestrator.json" (
    builtins.toJSON {
      enabled = cfg.enable;
      mode = cfg.mode;
      release_ticket = cfg.releaseTicket;
      alarm_command = cfg.alarmCommand;
      secondary_telegram_command = cfg.secondaryTelegramCommand;
      target = "mba@hsb0.lan";
      nixcfg_url = "https://github.com/markus-barta/nixcfg.git";
      hausnetz_url = "ssh://git@github.com/inspr-at/hausnetz";
      cache_dir = "${home}/.local/share/hausnetz-cd";
      state_file = "${stateDir}/hsb0-hausnetz-cd.json";
      export_dir = "${home}/.local/share/ops-qa/hsb0-hausnetz-exports";
      alarm_file = "${stateDir}/hsb0-hausnetz-cd-alarm.json";
      paimos = "${config.home.profileDirectory}/bin/paimos";
    }
  );
  entrypoint = pkgs.writeText "hausnetz-cd-orchestrate.py" (
    builtins.replaceStrings [ "@CONFIG@" ] [ (toString settings) ] (
      builtins.readFile (source + "/orchestrate.py")
    )
  );
  runner = pkgs.writeShellApplication {
    derivationArgs.passthru = { inherit settings entrypoint; };
    name = "hausnetz-cd";
    runtimeInputs = with pkgs; [
      coreutils
      git
      config.nix.package
      openssh
      python3
    ];
    text =
      builtins.replaceStrings
        [ "@SOURCE@" "@ENTRYPOINT@" ]
        [ (lib.escapeShellArg "${source}") (lib.escapeShellArg (toString entrypoint)) ]
        (builtins.readFile ./hausnetz-cd.sh);
  };
in
{
  options.inspr.hausnetzCdOrchestrator = {
    enable = lib.mkEnableOption "the two-minute hausnetz CD timer (separate activation gate)";
    mode = lib.mkOption {
      type = lib.types.enum [
        "dry-run"
        "live"
      ];
      default = "dry-run";
    };
    releaseTicket = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "HNET release ticket for one result line per revision.";
    };
    alarmCommand = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Optional alarm argv; the value-free alarm text is appended as one argument.";
    };
    secondaryTelegramCommand = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Coordinator-supplied argv invoking csb1's existing sender over SSH; required for live.";
    };
  };
  config = {
    home.packages = [ runner ];
    home.activation.hausnetzCdStateDirectory = lib.mkIf cfg.enable (
      lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ] ''
        run mkdir -p ${lib.escapeShellArg stateDir}
      ''
    );
    launchd.agents.hausnetz-cd = {
      enable = cfg.enable;
      config = {
        ProgramArguments = [ "${runner}/bin/hausnetz-cd" ];
        EnvironmentVariables = {
          HOME = home;
          PATH = "${config.home.profileDirectory}/bin:/usr/bin:/bin:/usr/sbin:/sbin";
          GIT_TERMINAL_PROMPT = "0";
        };
        StartInterval = 120;
        RunAtLoad = false;
        StandardOutPath = "${stateDir}/hsb0-hausnetz-cd.log";
        StandardErrorPath = "${stateDir}/hsb0-hausnetz-cd.log";
      };
    };
  };
}
