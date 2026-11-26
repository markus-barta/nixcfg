{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.inspr.hausnetzCd;
  settings = pkgs.writeText "hausnetz-cd-executor.json" (
    builtins.toJSON {
      allow_live = cfg.allowLive;
      require_readyz = cfg.requireReadyz;
      nixcfg_url = "https://github.com/markus-barta/nixcfg.git";
      state_dir = "/var/lib/hausnetz-cd";
      lock_file = "/run/hsb0-deploy.lock";
      evidence_file = "/etc/pharos-deployment/evidence.json";
      current_system = "/run/current-system";
      system_profile = "/nix/var/nix/profiles/system";
      store_pattern = "/nix/store/[0-9a-z]{32}-nixos-system-hsb0-[^/\\s]+";
      telegram_file = "/run/agenix/hsb0-hausnetz-telegram";
    }
  );
  runner = pkgs.writeShellApplication {
    name = "hausnetz-cd-execute";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      git
      config.nix.package
      openssh
      python3
      systemd
      util-linux
    ];
    text =
      builtins.replaceStrings
        [ "@SOURCE@" "@CONFIG@" ]
        [ (lib.escapeShellArg "${./.}") (lib.escapeShellArg (toString settings)) ]
        (builtins.readFile ./execute.sh);
  };
in
{
  options.inspr.hausnetzCd = {
    enable = lib.mkEnableOption "the hsb0-only guarded hausnetz CD executor";
    allowLive = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Separate release gate; false refuses every live request.";
    };
    requireReadyz = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Require HTTP 200, expected version and healthy engine/site/ui checks from /readyz; false refuses live mode.";
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.networking.hostName == "hsb0";
        message = "The hausnetz CD executor may only be installed on hsb0.";
      }
    ];
    environment.systemPackages = [ runner ];
    systemd.tmpfiles.rules = [
      "d /var/lib/hausnetz-cd 0700 root root - -"
      "f /run/hsb0-deploy.lock 0644 root root -"
    ];
  };
}
