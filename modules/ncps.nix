{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.ncps;
in
{
  options.services.ncps = {
    enable = mkEnableOption "NCPS - Nix binary cache proxy service";

    package = mkOption {
      type = types.package;
      default = pkgs.ncps; # This will be provided by the flake package overlay
      description = "The ncps package to use.";
    };

    settings = mkOption {
      type = types.submodule {
        options = {
          cache = {
            hostname = mkOption {
              type = types.str;
              description = "The hostname of the cache server.";
            };
            dataPath = mkOption {
              type = types.path;
              default = "/var/lib/ncps/data";
              description = "The local data path used for configuration and cache storage.";
            };
            databaseURL = mkOption {
              type = types.str;
              default = "sqlite:/var/lib/ncps/db/db.sqlite";
              description = "The URL of the database.";
            };
            maxSize = mkOption {
              type = types.str;
              default = "50G";
              description = "The maximum size of the store.";
            };
            lru = {
              schedule = mkOption {
                type = types.str;
                default = "0 3 * * *";
                description = "The cron spec for cleaning the store.";
              };
            };
            allowPutVerb = mkOption {
              type = types.bool;
              default = false;
              description = "Whether to allow the PUT verb to push narInfo and nar files directly.";
            };
            signingKeyPath = mkOption {
              type = types.nullOr types.path;
              default = null;
              description = "The path to the secret key used for signing cached paths.";
            };
          };

          server = {
            addr = mkOption {
              type = types.str;
              default = "0.0.0.0:8501";
              description = "The address of the server.";
            };
          };

          upstream = {
            caches = mkOption {
              type = types.listOf types.str;
              default = [ "https://cache.nixos.org" ];
              description = "Set to URL (with scheme) for each upstream cache.";
            };
            publicKeys = mkOption {
              type = types.listOf types.str;
              default = [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" ];
              description = "Set to host:public-key for each upstream cache.";
            };
          };
        };
      };
      description = "Configuration for ncps.";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.ncps = {
      description = "NCPS - Nix binary cache proxy service";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart =
          let
            upstreamCaches = concatMapStringsSep " " (c: "--upstream-cache ${c}") cfg.settings.upstream.caches;
            upstreamPubKeys = concatMapStringsSep " " (
              k: "--upstream-public-key ${k}"
            ) cfg.settings.upstream.publicKeys;
            signingKey =
              if cfg.settings.cache.signingKeyPath != null then
                "--cache-secret-key-path ${cfg.settings.cache.signingKeyPath}"
              else
                "";
            putVerb = if cfg.settings.cache.allowPutVerb then "--cache-allow-put-verb" else "";
          in
          "${cfg.package}/bin/ncps serve "
          + "--cache-hostname ${cfg.settings.cache.hostname} "
          + "--cache-data-path ${cfg.settings.cache.dataPath} "
          + "--cache-database-url ${cfg.settings.cache.databaseURL} "
          + "--cache-max-size ${cfg.settings.cache.maxSize} "
          + "--cache-lru-schedule \"${cfg.settings.cache.lru.schedule}\" "
          + "--server-addr ${cfg.settings.server.addr} "
          + "${signingKey} ${putVerb} ${upstreamCaches} ${upstreamPubKeys}";

        StateDirectory = "ncps";
        # Ensure directories exist
        ExecStartPre = [
          "${pkgs.coreutils}/bin/mkdir -p /var/lib/ncps/data /var/lib/ncps/db"
        ];

        Restart = "always";
        User = "root"; # Needs access to ZFS dataset and potentially signing keys
      };
    };
  };
}
