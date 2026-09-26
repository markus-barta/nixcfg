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
    (lib.mkIf cfg.cli.enable {
      home.packages = [ pkgs.aeon-cli ];
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
          ( umask 0277; ${pkgs.age}/bin/age --decrypt --identity "$IDENTITY" ${lib.escapeShellArg (src name)} > "$next" )
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
