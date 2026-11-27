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
      attended_ack_minutes = cfg.attendedAckMinutes;
      acceptance_command = cfg.acceptanceCommand;
      acceptance_url = cfg.acceptanceUrl;
      acceptance_timeout = cfg.acceptanceTimeout;
      vm_test_wait_timeout = cfg.vmTestWaitTimeout;
      mailbox_remote_file = cfg.mailboxRemoteFile;
      local_mailbox_command = cfg.localMailboxCommand;
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
      gh
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
    attendedAckMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Minutes for the operator's run-token acknowledgement during the first three live releases.";
    };
    acceptanceCommand = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Required live CI-VM adapter argv: materialize {trusted_rev}, run just acceptance {url} {version} {caps_sha256}, return one JSON object with ok=true. Empty refuses live.";
    };
    acceptanceUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Operator-selected URL passed to the trusted hausnetz acceptance checker in the Mac CI VM.";
    };
    acceptanceTimeout = lib.mkOption {
      type = lib.types.ints.between 1 600;
      default = 600;
      description = "CI-VM acceptance timeout in seconds (bounded by executor recovery budget).";
    };
    vmTestWaitTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1800;
      description = "Alarm once after this many seconds of retryable vm-test unavailability.";
    };
    alarmCommand = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Optional additional alarm argv; receives value-free text on stdin.";
    };
    mailboxRemoteFile = lib.mkOption {
      type = lib.types.str;
      default = "${home}/.config/inspr/mbx-remote";
      description = "Local non-repo file containing exactly host, port and user key=value lines for remote mailbox delivery.";
    };
    localMailboxCommand = lib.mkOption {
      type = lib.types.str;
      default = "${home}/.local/bin/mbx";
      description = "Local mailbox executable used for both recipients if remote delivery is unavailable.";
    };
    secondaryTelegramCommand = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "${pkgs.openssh}/bin/ssh"
        "-T"
        "-o"
        "BatchMode=yes"
        "-o"
        "ConnectTimeout=10"
        "-o"
        "StrictHostKeyChecking=yes"
        "-p"
        "2222"
        "mba@csb1"
        "sudo -n /run/current-system/sw/bin/hausnetz-cd-alert"
      ];
      description = "Independent csb1 one-shot sender argv; message on stdin, credential stays on csb1.";
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
