# OPS-231 — Aeon (PAIMOS successor, AEON-43 cutover) workstation surface.
#
# Staged and inert by default: nothing here routes a consumer to Aeon. The
# default PPM URL flip is the late-switch change in OPS-231; the aeon-agentd
# launchd service is a separate phase once enrollment values exist.
#
#   cli.enable           installs `aeon` only. The upstream package also ships
#                        bin/paimos (argv0 compat mode); that alias stays off
#                        PATH until the compatibility transcript gate, so
#                        classic paimos-cli keeps owning `paimos`.
#   consumerKeys.enable  materialises declared Aeon consumer keys from
#                        secrets/aeon/<name>.age to ~/.inspr/secrets/aeon/<name>.key
#                        (0400, raw token). Unlike inspr.secrets.agents this does
#                        NOT own the directory: undeclared files (keys placed by
#                        hand before they are sealed) are reported, never removed.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.uzumaki.aeon;
  keys = cfg.consumerKeys;
  src = name: keys.encryptedDir + "/${name}.age";
  missing = builtins.filter (name: !builtins.pathExists (src name)) keys.names;
in
{
  options.uzumaki.aeon = {
    cli.enable = lib.mkEnableOption "the Aeon client as `aeon` (no `paimos` alias)";

    cli.paimosAlias = lib.mkEnableOption ''
      `paimos` = the Aeon client in paimos mode (runbook step 3). It takes
      precedence over classic paimos-cli on PATH; classic stays installed as
      `paimos-classic` for classic-only instances (pma on paimos.agm.ng) and
      rollback. The classic agentd service keeps its own store path'';

    cli.instanceKeys = lib.mkOption {
      type = lib.types.attrsOf (lib.types.strMatching "[a-z0-9][a-z0-9-]*");
      default = { };
      example = {
        ppm = "workstation-agents";
      };
      description = ''
        Aeon CLI instance → consumer key name. Links ~/.paimos/keys/<instance>
        (where the Aeon client reads a stored key) to the materialised
        consumer key. An existing file there that is not our link is left
        untouched and reported.
      '';
    };

    consumerKeys = {
      enable = lib.mkEnableOption "Aeon consumer key materialisation";

      names = lib.mkOption {
        type = lib.types.listOf (lib.types.strMatching "[a-z0-9][a-z0-9-]*");
        default = [ ];
        example = [
          "pharos-reporter"
          "janus"
        ];
        description = "Consumer key basenames; each needs secrets/aeon/<name>.age declared in secrets.nix.";
      };

      encryptedDir = lib.mkOption {
        type = lib.types.path;
        default = ../../secrets/aeon;
        description = "Directory holding the sealed <name>.age files.";
      };

      decryptedDir = lib.mkOption {
        type = lib.types.str;
        default = "${config.home.homeDirectory}/.inspr/secrets/aeon";
        description = "Where <name>.key files are written.";
      };

      identityFiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "$HOME/.ssh/id_ed25519"
          "$HOME/.ssh/id_rsa"
        ];
        description = "SSH identities tried in order for decryption (expanded at activation).";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.cli.instanceKeys != { }) {
      assertions = [
        {
          assertion = keys.enable && lib.all (k: lib.elem k keys.names) (lib.attrValues cfg.cli.instanceKeys);
          message = "uzumaki.aeon.cli.instanceKeys: every referenced key must be in consumerKeys.names (with consumerKeys.enable)";
        }
      ];
      home.activation.linkAeonInstanceKeys = lib.hm.dag.entryAfter [ "materializeAeonConsumerKeys" ] ''
        KEYS_DIR="$HOME/.paimos/keys"
        mkdir -p "$KEYS_DIR"
        chmod 0700 "$KEYS_DIR"
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (instance: key: ''
            target=${lib.escapeShellArg "${keys.decryptedDir}/${key}.key"}
            link="$KEYS_DIR/${instance}"
            if [[ -e "$link" && ! -L "$link" ]]; then
              echo "aeon-cli: note — $link exists and is not managed; left untouched" >&2
            else
              ln -sfn "$target" "$link"
            fi
          '') cfg.cli.instanceKeys
        )}
      '';
    })

    (lib.mkIf (cfg.cli.enable && !cfg.cli.paimosAlias) {
      home.packages = [ pkgs.aeon-cli ];
    })

    (lib.mkIf cfg.cli.paimosAlias {
      home.packages = [
        # hiPrio: wins the bin/paimos collision with classic paimos-cli.
        (lib.hiPrio pkgs.aeon-paimos)
        (pkgs.writeShellScriptBin "paimos-classic" ''
          exec ${pkgs.paimos-cli}/bin/paimos "$@"
        '')
      ];
    })

    (lib.mkIf (keys.enable && keys.names != [ ]) {
      assertions = [
        {
          assertion = missing == [ ];
          message = "uzumaki.aeon.consumerKeys: missing (or untracked in git) sealed key(s): ${lib.concatStringsSep ", " missing}";
        }
      ];

      home.activation.materializeAeonConsumerKeys = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        set -e
        DIR=${lib.escapeShellArg keys.decryptedDir}
        IDENTITY=""
        ${lib.concatMapStringsSep "\n" (path: ''
          if [[ -z "$IDENTITY" && -f "${path}" ]]; then IDENTITY="${path}"; fi
        '') keys.identityFiles}
        if [[ -z "$IDENTITY" ]]; then
          echo "aeon-consumer-keys: ERROR — no SSH identity found" >&2
          exit 1
        fi
        mkdir -p "$DIR"
        chmod 0700 "$DIR"
        ${lib.concatMapStringsSep "\n" (name: ''
          echo "aeon-consumer-keys: decrypting ${name}"
          next="$DIR/.${name}.key.next"
          # A failed decrypt must not strand a 0400 temp that blocks the next run.
          rm -f "$next"
          if ! ( umask 0277; ${pkgs.age}/bin/age --decrypt --identity "$IDENTITY" ${lib.escapeShellArg (src name)} > "$next" ); then
            rm -f "$next"
            echo "aeon-consumer-keys: ERROR — cannot decrypt ${name}" >&2
            exit 1
          fi
          chmod 0400 "$next"
          mv -f "$next" "$DIR/${name}.key"
        '') keys.names}
        for f in "$DIR"/*.key; do
          [ -e "$f" ] || continue
          case "$(basename "$f" .key)" in
            ${lib.concatStringsSep "|" keys.names}) ;;
            *) echo "aeon-consumer-keys: note — $(basename "$f") is not declared (hand-placed?); left untouched" >&2 ;;
          esac
        done
      '';
    })
  ];
}
