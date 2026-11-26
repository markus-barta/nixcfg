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
      manifest_path = cfg.manifestPath;
      version_url = cfg.versionUrl;
      version_field = cfg.versionField;
      health_url = cfg.healthUrl;
      nixcfg_url = "https://github.com/markus-barta/nixcfg.git";
      hausnetz_url = "ssh://git@github.com/inspr-at/hausnetz";
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
      nix
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
    manifestPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "HNET-570 manifest repo path; unset forces manual handling.";
    };
    versionUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "HNET-570 version endpoint on 127.0.0.1:8377; no inferred URL.";
    };
    versionField = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Dot-separated exact Git revision field; no inferred field.";
    };
    healthUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "HNET-570 healthz endpoint on 127.0.0.1:8377.";
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
    systemd.tmpfiles.rules = [ "d /var/lib/hausnetz-cd 0700 root root - -" ];
  };
}
