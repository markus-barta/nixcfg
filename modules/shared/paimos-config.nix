# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║              INSPR — Auto-bootstrap paimos-cli config                        ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Materialize ~/.paimos/config.yaml from agent-secrets env files at HM
# activation time, so a fresh INSPR-onboarded host gets `paimos` CLI ready
# to use without the manual `paimos auth login --url ... --api-key ...` step.
#
# Pairs with:
#   - modules/shared/agent-secrets.nix  (provides the materialized .env files)
#   - paimos-cli in home.packages       (the binary that reads this config)
#
# Architecture (Pattern β-aligned with inspr.secrets.agents.*, inspr.git-identity.*):
#   - Each named instance declares: URL + path to KEY=value env file + var name
#   - Activation sources each env file in a subshell (scoped exposure),
#     extracts the variable, writes ~/.paimos/config.yaml atomically
#   - File mode 0600, dir mode 0700 — never world-readable
#   - Idempotent: re-runs each activation; declarative wins over manual edits
#   - Safe-degrade: missing env file → instance skipped with a stderr WARN
#     (so `inspr.paimos-cli.enable = true` doesn't break activation if
#      agent-secrets isn't yet populated, e.g. first-boot ordering edge cases)
#
# Closes NIX-96 gap #2.
#
# Usage:
#   imports = [ ../../modules/shared/paimos-config.nix ];
#   inspr.paimos-cli = {
#     enable = true;
#     # `instances` has a sensible default (ppm only) — extend if you also
#     # want pmo configured (set apiKeyEnvFile to the materialized PMOAPIKEY).
#   };
#
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.inspr.paimos-cli;

  # Build one YAML fragment per declared instance. Wraps each in a subshell
  # so the sourced env vars don't bleed into the next iteration.
  mkInstanceFragment = name: inst: ''
    if [[ -f "${inst.apiKeyEnvFile}" ]]; then
      (
        set -a
        # shellcheck disable=SC1090
        source "${inst.apiKeyEnvFile}"
        set +a
        key_value="$(printenv ${lib.escapeShellArg inst.apiKeyVar})"
        if [[ -n "$key_value" ]]; then
          echo "    ${name}:"
          echo "        url: ${inst.url}"
          echo "        api_key: $key_value"
        else
          echo "paimos-config: WARN ${name}: ${inst.apiKeyVar} empty in ${inst.apiKeyEnvFile}; skipping" >&2
        fi
      )
    else
      echo "paimos-config: WARN ${name}: ${inst.apiKeyEnvFile} not found; skipping" >&2
    fi
  '';

  instanceFragments = lib.concatStringsSep "\n" (
    lib.mapAttrsToList mkInstanceFragment cfg.instances
  );

  # Default instances: just ppm (the personal instance). Hosts that also
  # consume the BYTEPOETS PMO instance can extend `instances.pmo` themselves.
  defaultInstances = {
    ppm = {
      url = "https://pm.barta.cm";
      apiKeyEnvFile = "${config.home.homeDirectory}/Secrets/age/decrypted/agents/PPMAPIKEY.env";
      apiKeyVar = "PPMAPIKEY";
    };
  };
in
{
  options.inspr.paimos-cli = {
    enable = lib.mkEnableOption "auto-bootstrap ~/.paimos/config.yaml from agent-secrets env files";

    defaultInstance = lib.mkOption {
      type = lib.types.str;
      default = "ppm";
      description = ''
        Which configured instance becomes the default for `paimos` CLI
        invocations that don't pass `--instance`.
      '';
    };

    instances = lib.mkOption {
      description = ''
        Named PAIMOS instances to materialize into ~/.paimos/config.yaml.
        Each instance provides:
          - url           the instance's HTTPS endpoint
          - apiKeyEnvFile absolute path to a KEY=value env file (typically
                          materialized by inspr.secrets.agents)
          - apiKeyVar     variable name inside that env file holding the API key
        Activation sources each env file in a subshell, extracts the variable,
        and writes config.yaml atomically. Missing files → skipped with a WARN.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            url = lib.mkOption {
              type = lib.types.str;
              description = "Instance URL (e.g. https://pm.barta.cm)";
            };
            apiKeyEnvFile = lib.mkOption {
              type = lib.types.str;
              description = "Absolute path to env file containing the API key";
            };
            apiKeyVar = lib.mkOption {
              type = lib.types.str;
              description = "Variable name inside the env file holding the API key";
            };
          };
        }
      );
      default = defaultInstances;
      defaultText = lib.literalExpression ''
        {
          ppm = {
            url           = "https://pm.barta.cm";
            apiKeyEnvFile = "''${config.home.homeDirectory}/Secrets/age/decrypted/agents/PPMAPIKEY.env";
            apiKeyVar     = "PPMAPIKEY";
          };
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.activation.bootstrapPaimosConfig = lib.hm.dag.entryAfter (
      [ "writeBoundary" ]
      # If agent-secrets is also enabled, sequence after it so the env files
      # are guaranteed to exist when our script reads them.
      ++ lib.optional config.inspr.secrets.agents.enable "materializeAgentSecrets"
    ) ''
      set -e

      CONFIG_DIR="${config.home.homeDirectory}/.paimos"
      CONFIG_FILE="$CONFIG_DIR/config.yaml"

      umask 0077
      mkdir -p "$CONFIG_DIR"
      chmod 0700 "$CONFIG_DIR"

      # Build YAML in a tmpfile then mv atomically (so a partial write
      # never leaves the consumer reading a half-written file).
      tmp="$(mktemp "$CONFIG_DIR/.config.yaml.XXXXXX")"
      chmod 0600 "$tmp"

      {
        echo "default_instance: ${cfg.defaultInstance}"
        echo "instances:"
        ${instanceFragments}
      } > "$tmp"

      mv -f "$tmp" "$CONFIG_FILE"

      echo "paimos-config: wrote $CONFIG_FILE (${
        toString (lib.length (lib.attrNames cfg.instances))
      } instance(s) declared)"
    '';
  };
}
