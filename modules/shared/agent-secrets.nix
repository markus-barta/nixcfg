# ─────────────────────────────────────────────────────────────────────────
# modules/shared/agent-secrets.nix
#
# Materialize agenix-encrypted "agent-exception" secrets to a read-only
# decrypted folder consumable by interactive agents (and the user's own
# tooling) via the env-file pattern: filename = variable name; contents =
# variable value.
#
# Architecture (see ~/Code/inspr/playbook.md → "Architecture — secrets /
# agent-exception design"):
#
#   Encrypted side (in repo, agenix-managed):
#     nixcfg/secrets/agents/shared/<NAME>.age          → all hosts
#     nixcfg/secrets/agents/host/<hostname>/<NAME>.age → only that host
#
#   Decrypted side (per host, activation-managed):
#     /Users/mba/Secrets/age/decrypted/agents/<NAME>.env
#     mode 0400 (owner-read), dir mode 0500 (no manual writes)
#     READ-ONLY, ONE-WAY, activation-owned lifecycle:
#       rebuild = directory rebuilt against current declaration; orphans removed
#
# Daily interface (unchanged from today's manual env-file pattern):
#   ( set -a; source /Users/mba/Secrets/age/decrypted/agents/<NAME>.env;
#     <command-that-uses-$NAME>; set +a )
#
# Phase: Phase 1 (agenix canonical for agent-subset, manual `agenix -e`).
# Phase 2 will add a 1Password-tag-driven export script that generates
# the .age files; this module's interface stays the same.
#
# Implementation note: this is a Home Manager STANDALONE module. It does
# NOT use agenix's home-manager submodule because that submodule expects
# nix-darwin / NixOS context. Instead it uses the `age` CLI directly at
# activation time to decrypt the user-readable .age files (the user
# `markus` must be in the recipient list of any secret materialized here).
# ─────────────────────────────────────────────────────────────────────────
{ config, pkgs, lib, hostname ? null, ... }:

let
  cfg = config.inspr.secrets.agents;

  # Helpers ----------------------------------------------------------------

  # Determine the hostname (passed via flake's extraSpecialArgs, or fall
  # back to runtime detection at activation time).
  hostnameValue =
    if hostname != null then hostname
    else "$(hostname -s)";

  # Helper: list .age files in a directory (Nix-time, evaluated at flake
  # eval). Returns [] if the directory doesn't exist.
  ageFilesIn = dir:
    if builtins.pathExists dir
    then builtins.filter (n: lib.hasSuffix ".age" n)
                         (builtins.attrNames (builtins.readDir dir))
    else [];

  # Strip .age extension to get the variable name
  varNameOf = file: lib.removeSuffix ".age" file;

  # Discover the secrets at flake-eval time
  sharedDir = cfg.encryptedRoot + "/shared";
  hostDir   = cfg.encryptedRoot + "/host/${hostnameValue}";

  sharedFiles = ageFilesIn sharedDir;
  hostFiles   = ageFilesIn hostDir;

  # Pairs of (source-age-path, decrypted-target-name)
  allSecrets =
    (map (f: { src = "${sharedDir}/${f}"; name = varNameOf f; }) sharedFiles) ++
    (map (f: { src = "${hostDir}/${f}";   name = varNameOf f; }) hostFiles);

  # Newline-separated list of expected target basenames (for orphan cleanup)
  expectedBasenames = lib.concatStringsSep " " (map (s: "${s.name}.env") allSecrets);

in
{
  # Module options ---------------------------------------------------------
  # Namespace: `inspr.secrets.agents.*` — chosen for Pattern β. When this
  # module is eventually extracted into the public `inspr-modules` flake,
  # downstream consumers (Markus's personal nixcfg, BYTEPOETS flake, family
  # flake, paid-product flakes) keep the same option path. Sibling
  # categories like `inspr.secrets.projects.*` and `inspr.secrets.hosts.*`
  # will follow for the Phase 3 Paimos / FleetCom integration.
  options.inspr.secrets.agents = {
    enable = lib.mkEnableOption "materialize agent-exception secrets to /Users/mba/Secrets/age/decrypted/agents/";

    encryptedRoot = lib.mkOption {
      type        = lib.types.path;
      default     = ../../secrets/agents;
      description = "Source root for encrypted .age files. Contains shared/ and host/<hostname>/ subdirs.";
    };

    decryptedDir = lib.mkOption {
      type        = lib.types.str;
      default     = "/Users/mba/Secrets/age/decrypted/agents";
      description = "Where decrypted .env files are materialized. Activation owns this dir entirely.";
    };

    identityFile = lib.mkOption {
      type        = lib.types.str;
      default     = "$HOME/.ssh/id_rsa";
      description = "User SSH private key used by `age` for decryption. Must correspond to a public key in the recipient list of every materialized secret.";
    };
  };

  # Module config ----------------------------------------------------------
  config = lib.mkIf cfg.enable {
    # Activation script — runs after Home Manager's writeBoundary so the
    # `age` CLI (installed via home.packages from agenix) is on PATH.
    home.activation.materializeAgentSecrets = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      set -e

      DECRYPTED_DIR="${cfg.decryptedDir}"
      IDENTITY="${cfg.identityFile}"
      AGE_BIN="${pkgs.age}/bin/age"

      mkdir -p "$DECRYPTED_DIR"
      # Open the dir for writes during this activation. Lock it back to
      # 0500 (no manual writes possible) at the end of the script.
      chmod 0700 "$DECRYPTED_DIR"

      # Build the expected file set (computed at Nix eval time; baked into script)
      expected="${expectedBasenames}"

      # Decrypt every declared secret
      ${lib.concatMapStringsSep "\n" (s: ''
        echo "agent-secrets: decrypting ${s.name}"
        target="$DECRYPTED_DIR/${s.name}.env"
        # umask narrows default file perms so the plaintext is never even
        # momentarily readable by other accounts.
        umask 0277
        "$AGE_BIN" --decrypt --identity "$IDENTITY" "${s.src}" > "$target"
        chmod 0400 "$target"
      '') allSecrets}

      # Cleanup orphans: remove .env files not in current declaration
      for f in "$DECRYPTED_DIR"/*.env; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        case " $expected " in
          *" $base "*) ;;  # expected, keep
          *)
            echo "agent-secrets: removing orphan $base"
            chflags nouchg "$f" 2>/dev/null || true
            rm -f "$f"
            ;;
        esac
      done

      # Lock the directory: no further writes possible without explicit chmod.
      # This is the "one-way street" guarantee from the architecture.
      chmod 0500 "$DECRYPTED_DIR"
    '';
  };
}
