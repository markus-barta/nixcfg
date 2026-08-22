# Pharos ← Paimos external-stage owner adapter wiring (NIX-381 / PHAROS-206).
#
# Generates the value-free `inspr.pharos.paimos-delivery-adapter.v1` intent
# document that pharosd v0.1.83 reads through PHAROS_PAIMOS_DELIVERY_CONFIG_FILE
# and publishes it as a private, container-uid-owned file. It creates no
# credential material: the API key and every 32-byte raw handoff secret are
# agenix-managed files that this module only names.
#
# 🔴 What this module deliberately does NOT do: it grants pharosd no new
# authority. The deployment intent carries `update_restart_job_id`, and the
# adapter only *observes* that already-existing Pharos host action — it reports
# success solely when the operator has already confirmed it
# (`job.confirmed_at.is_none()` is a LocalBinding refusal in
# crates/pharosd/src/paimos_delivery.rs). The consequential UpdateRestart stays
# an attended operator decision in the Pharos UI. Nothing here can create,
# confirm, claim or execute a host action.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.inspr.pharosPaimosDelivery;
  jsonFormat = pkgs.formats.json { };

  runtimeDirectory = builtins.dirOf cfg.configFile;

  # Crockford base32 (ULID) — Paimos mints these; they cannot be invented.
  isHandoffId = value: builtins.match "[0-9A-HJKMNP-TV-Z]{26}" value != null;
  isSymbol = value: builtins.match "[a-z][a-z0-9._-]{0,63}" value != null;
  isHostName = value: builtins.match "[a-z0-9][a-z0-9-]{0,62}" value != null;
  isVersion = value: builtins.match "[A-Za-z0-9][A-Za-z0-9._+-]{0,63}" value != null;
  isSha256Digest = value: builtins.match "sha256:[0-9a-f]{64}" value != null;
  isCommitDigest = value: builtins.match "[0-9a-f]{40}|[0-9a-f]{64}" value != null;
  isActionId = value: builtins.match "[A-Za-z0-9_-]{8,128}" value != null;
  isAbsolutePath = value: builtins.match "/[^[:space:]]*" value != null;
  # https only, no userinfo/query/fragment, empty or "/" path.
  isSafeOrigin = value: builtins.match "https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?" value != null;

  artifactType = lib.types.submodule {
    options = {
      version = lib.mkOption {
        type = lib.types.str;
        example = "0.1.83";
        description = "Bounded artifact version reported as evidence.";
      };
      digest = lib.mkOption {
        type = lib.types.str;
        example = "sha256:2d880515627656322876eda1bb07462866d1ac57829fd3d72dc6418fb222a0fa";
        description = "Exact deployed artifact digest: `sha256:` plus 64 lowercase hex.";
      };
      commitDigest = lib.mkOption {
        type = lib.types.str;
        example = "c68719d7dbaea4a2c5c557c59e7fdb8cd786ace2";
        description = "Lowercase 40- or 64-hex commit digest of the deployed source.";
      };
    };
  };

  intentType = lib.types.submodule {
    options = {
      handoffId = lib.mkOption {
        type = lib.types.str;
        description = "Paimos-minted 26-character Crockford base32 handoff id. Never invented locally.";
      };
      handoffSecretFile = lib.mkOption {
        type = lib.types.str;
        description = "In-container path of this handoff's own 32-byte raw secret. Never shared with another intent or with the API key.";
      };
      stage = lib.mkOption {
        type = lib.types.enum [
          "deployment"
          "verification"
        ];
        description = "Owner stage this intent reports.";
      };
      environment = lib.mkOption {
        type = lib.types.str;
        default = "production";
        description = "Symbolic environment name bound into the evidence.";
      };
      host = lib.mkOption {
        type = lib.types.str;
        description = "Host the guarded workflow targets.";
      };
      artifact = lib.mkOption {
        type = artifactType;
        description = "Exact artifact this stage deploys or verifies.";
      };
      updateRestartJobId = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Deployment only: the existing operator-confirmed Pharos UpdateRestart job this intent observes.";
      };
      deploymentHandoffId = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Verification only: the deployment handoff this verification must follow.";
      };
    };
  };

  # pharosd deserialises with `deny_unknown_fields`, so the rendered document
  # must contain exactly the contract keys — and the two optional keys must be
  # absent, not null, on the stage that forbids them.
  workflowFor = stage: if stage == "deployment" then "deploy-production" else "verify-production";
  renderIntent =
    intent:
    {
      handoff_id = intent.handoffId;
      handoff_secret_file = intent.handoffSecretFile;
      stage = intent.stage;
      workflow = workflowFor intent.stage;
      environment = intent.environment;
      host = intent.host;
      artifact = {
        version = intent.artifact.version;
        digest = intent.artifact.digest;
        commit_digest = intent.artifact.commitDigest;
      };
    }
    // lib.optionalAttrs (intent.updateRestartJobId != null) {
      update_restart_job_id = intent.updateRestartJobId;
    }
    // lib.optionalAttrs (intent.deploymentHandoffId != null) {
      deployment_handoff_id = intent.deploymentHandoffId;
    };

  document = {
    schema = "inspr.pharos.paimos-delivery-adapter.v1";
    schema_version = 1;
    paimos_origin = cfg.paimosOrigin;
    api_key_file = cfg.apiKeyFile;
    poll_interval_secs = cfg.pollIntervalSeconds;
    verification_freshness_secs = cfg.verificationFreshnessSeconds;
    intents = map renderIntent cfg.intents;
  };

  documentFile = jsonFormat.generate "pharos-paimos-delivery-config.json" document;

  owner = toString cfg.containerUid;

  # Atomic publish. The destination is created fresh (nlink == 1) with mode
  # 0400 owned by the pharosd container uid, because pharosd opens it O_NOFOLLOW
  # and refuses anything carrying group/other bits, a foreign owner, or extra
  # links — which a /nix/store path can never satisfy.
  publish = pkgs.writeShellScript "publish-pharos-paimos-delivery-config" ''
    set -eu
    destination=${lib.escapeShellArg cfg.configFile}
    temporary="${runtimeDirectory}/.config.$$"
    trap '${pkgs.coreutils}/bin/rm -f "$temporary"' EXIT HUP INT TERM
    ${pkgs.coreutils}/bin/install -d -m 0700 -o root -g root ${lib.escapeShellArg runtimeDirectory}
    ${pkgs.coreutils}/bin/install -m 0400 -o ${lib.escapeShellArg owner} -g ${lib.escapeShellArg owner} \
      ${documentFile} "$temporary"
    ${pkgs.coreutils}/bin/mv -f "$temporary" "$destination"
    trap - EXIT HUP INT TERM
  '';

  deploymentIntents = builtins.filter (intent: intent.stage == "deployment") cfg.intents;
  verificationIntents = builtins.filter (intent: intent.stage == "verification") cfg.intents;
  handoffIds = map (intent: intent.handoffId) cfg.intents;
  secretFiles = map (intent: intent.handoffSecretFile) cfg.intents;
  allCredentialFiles = [ cfg.apiKeyFile ] ++ secretFiles;
  unique = values: builtins.length values == builtins.length (lib.unique values);

  pairedDeployment =
    intent:
    let
      matches = builtins.filter (
        candidate: candidate.handoffId == intent.deploymentHandoffId
      ) deploymentIntents;
    in
    if builtins.length matches == 1 then builtins.head matches else null;
in
{
  options.inspr.pharosPaimosDelivery = {
    enable = lib.mkEnableOption "declarative Pharos/Paimos external-stage owner adapter wiring";

    activate = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Publish the adapter config. 🔴 Flip this only together with the matching
        `active` switch in hosts/csb1/paimos-delivery-stage.nix, and only after the
        RUNBOOK preflight confirms every credential file exists — pharosd panics at
        startup on an incomplete adapter configuration.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/pharos/paimos-delivery/config.json";
      description = "Private published path of the generated adapter config; identical inside pharosd.";
    };

    containerUid = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 10001;
      description = "Effective uid pharosd runs as. Every file the adapter reads must be owned by it.";
    };

    paimosOrigin = lib.mkOption {
      type = lib.types.str;
      example = "https://paimos.barta.cm";
      description = "Credential-free https Paimos origin with no path, query or fragment.";
    };

    apiKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "In-container path of the owner API key. Its own inode, never shared with a handoff secret.";
    };

    pollIntervalSeconds = lib.mkOption {
      type = lib.types.ints.between 5 3600;
      default = 30;
      description = "Adapter poll cadence, inside the contract's 5-3600 s window.";
    };

    verificationFreshnessSeconds = lib.mkOption {
      type = lib.types.ints.between 30 900;
      default = 300;
      description = "Maximum beacon age accepted as fresh verification evidence, inside the contract's 30-900 s window.";
    };

    intents = lib.mkOption {
      type = lib.types.listOf intentType;
      default = [ ];
      description = "Owner intents. Empty until Paimos has minted the handoffs; `activate` then requires at least one.";
    };

    generated = lib.mkOption {
      type = jsonFormat.type;
      readOnly = true;
      description = "The rendered adapter document, for tests and review.";
    };

    source = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      description = "Store path of the rendered adapter document.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = isSafeOrigin cfg.paimosOrigin;
        message = "inspr.pharosPaimosDelivery.paimosOrigin must be a credential-free https origin with no path, query or fragment.";
      }
      {
        assertion = isAbsolutePath cfg.apiKeyFile && isAbsolutePath cfg.configFile;
        message = "inspr.pharosPaimosDelivery apiKeyFile and configFile must be absolute paths.";
      }
      {
        assertion = !cfg.activate || (cfg.intents != [ ] && builtins.length cfg.intents <= 128);
        message = "inspr.pharosPaimosDelivery.activate requires 1-128 intents; pharosd panics on an empty intent list.";
      }
      {
        assertion = unique handoffIds;
        message = "inspr.pharosPaimosDelivery intents must use distinct handoff ids.";
      }
      {
        assertion = unique allCredentialFiles && lib.all isAbsolutePath allCredentialFiles;
        message = "inspr.pharosPaimosDelivery: the API key and every handoff secret must be distinct absolute files - pharosd refuses a shared credential inode.";
      }
      {
        assertion = lib.all (intent: isHandoffId intent.handoffId) cfg.intents;
        message = "inspr.pharosPaimosDelivery handoffId values must be Paimos-minted 26-character Crockford base32 ids.";
      }
      {
        assertion = lib.all (
          intent:
          isSymbol intent.environment
          && isHostName intent.host
          && isVersion intent.artifact.version
          && isSha256Digest intent.artifact.digest
          && isCommitDigest intent.artifact.commitDigest
        ) cfg.intents;
        message = "inspr.pharosPaimosDelivery intent environment/host/artifact values must match the pinned v1 contract shapes.";
      }
      {
        assertion = lib.all (
          intent:
          intent.deploymentHandoffId == null
          && intent.updateRestartJobId != null
          && isActionId intent.updateRestartJobId
        ) deploymentIntents;
        message = "A deployment intent must name exactly one existing UpdateRestart job id and must not carry deploymentHandoffId.";
      }
      {
        assertion = lib.all (
          intent:
          intent.updateRestartJobId == null
          && intent.deploymentHandoffId != null
          && isHandoffId intent.deploymentHandoffId
        ) verificationIntents;
        message = "A verification intent must reference a deployment handoff id and must not carry updateRestartJobId.";
      }
      {
        assertion = lib.all (
          intent:
          let
            deployment = pairedDeployment intent;
          in
          deployment != null
          && deployment.handoffId != intent.handoffId
          && deployment.host == intent.host
          && deployment.environment == intent.environment
          && deployment.artifact == intent.artifact
        ) verificationIntents;
        message = "Each verification intent must pair with exactly one distinct deployment intent for the same host, environment and artifact.";
      }
    ];

    inspr.pharosPaimosDelivery = {
      generated = document;
      source = documentFile;
    };

    systemd.services.pharos-paimos-delivery-config = lib.mkIf cfg.activate {
      description = "Publish the private Pharos/Paimos external-stage adapter config";
      after = [ "systemd-tmpfiles-setup.service" ];
      before = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ documentFile ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
        ExecStart = publish;
      };
    };
  };
}
