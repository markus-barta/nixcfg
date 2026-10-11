# OPS-300 — admission for mba's remote-test pushes on the shared Mac.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.aeonRemoteGuard;
  home = config.home.homeDirectory;
  guard = pkgs.writeShellApplication {
    name = "aeon-remote-guard";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
    ];
    text = ''
      unset AEON_REMOTE_GUARD_LOAD
      readonly guard_hold_file=${lib.escapeShellArg cfg.holdFile}
      readonly guard_policy_file=${lib.escapeShellArg cfg.policyFile}
      readonly guard_default_max_load=${lib.escapeShellArg (toString cfg.defaultMaxLoad)}
      readonly guard_stale_seconds=${toString cfg.staleSeconds}
      ${builtins.readFile ./guard.sh}
    '';
  };
  hook = pkgs.writeShellScript "aeon-remote-pre-receive" (
    lib.replaceStrings [ "@guard@" ] [ "${guard}/bin/aeon-remote-guard" ] (
      builtins.readFile ./pre-receive.sh
    )
  );
in
{
  options.services.aeonRemoteGuard = {
    enable = lib.mkEnableOption "host-side admission for remote-test pushes on macOS";
    repo = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "${home}/aeon-remote.git";
      description = "Existing bare repository under the managed home; only its pre-receive hook is managed.";
    };
    holdFile = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "${home}/.hold-mbp2606";
      description = "Refuse remote runs while this path exists.";
    };
    policyFile = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "${home}/.aeon-remote-policy";
      description = "OPS watch policy: block=<0|1> maxload=<number> level=<GREEN|YELLOW|RED> epoch=<unix>.";
    };
    defaultMaxLoad = lib.mkOption {
      type = lib.types.number;
      default = 12;
      description = "Maximum 1-minute load when no valid fresh policy is available.";
    };
    staleSeconds = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 900;
      description = "Maximum age in seconds of a policy from the OPS watch.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = "services.aeonRemoteGuard requires macOS (sysctl vm.loadavg).";
      }
      {
        assertion = cfg.defaultMaxLoad >= 0;
        message = "services.aeonRemoteGuard.defaultMaxLoad must be nonnegative.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.repo;
        message = "services.aeonRemoteGuard.repo must be an absolute path.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.holdFile;
        message = "services.aeonRemoteGuard.holdFile must be an absolute path.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.policyFile;
        message = "services.aeonRemoteGuard.policyFile must be an absolute path.";
      }
      {
        assertion = lib.hasPrefix "${home}/" cfg.repo;
        message = "services.aeonRemoteGuard.repo must be under home.homeDirectory for home.file.";
      }
    ];
    home.packages = [ guard ];
    # Link one executable file into the real hooks directory, not the directory
    # itself. Git follows this symlink; HM preserves the other bare-repo files.
    home.file."${cfg.repo}/hooks/pre-receive" = {
      source = hook;
      executable = true;
    };
  };
}
