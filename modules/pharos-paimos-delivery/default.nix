# Pharos ← Paimos external-stage owner adapter wiring (NIX-381 / PHAROS-206).
#
# Generates the value-free `inspr.pharos.paimos-delivery-adapter.v2` local
# intent document that pharosd reads through PHAROS_PAIMOS_DELIVERY_CONFIG_FILE
# and publishes it as a private, container-uid-owned file. Local schema
# `inspr.pharos.paimos-delivery-adapter.v2` / version 2 stays this module's
# document; the external owner wire v2 is frozen elsewhere and is not repinned
# here. Artifact evidence is the eight-field Pharos owner-v2 tuple with an
# explicit `legacy` / `inspr-calendar-v1` discriminator — never inferred from
# version punctuation, and never filled in with invented channel, sequence or
# manifest identity. This module creates no credential material: the API key
# and every 32-byte raw handoff secret are agenix-managed files that this
# module only names.
#
# 🔴 What this module deliberately does NOT do: it grants pharosd no new
# authority. A deployment intent MAY name an existing `update_restart_job_id`;
# if it omits one, accepted pharosd proposes a deterministic operator-confirmed
# guarded UpdateRestart. In either case the adapter only *observes* that job
# and reports success solely when the operator has already confirmed it
# (`job.confirmed_at.is_none()` is a LocalBinding refusal in
# crates/pharosd/src/paimos_delivery.rs). The consequential UpdateRestart stays
# an attended operator decision in the Pharos UI. Nothing here can confirm,
# claim, start or execute a host action.
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
  # Pharos `valid_version`: 1-64 chars, first alphanumeric, rest [A-Za-z0-9._+-].
  # Calendar-looking punctuation is still a legacy string until the discriminator
  # says otherwise — this check must not infer the scheme.
  isLegacyVersion =
    value:
    let
      len = builtins.stringLength value;
    in
    len >= 1 && len <= 64 && builtins.match "[A-Za-z0-9][A-Za-z0-9._+-]*" value != null;
  twoDigit =
    value:
    let
      digits = {
        "0" = 0;
        "1" = 1;
        "2" = 2;
        "3" = 3;
        "4" = 4;
        "5" = 5;
        "6" = 6;
        "7" = 7;
        "8" = 8;
        "9" = 9;
      };
      tens = builtins.substring 0 1 value;
      ones = builtins.substring 1 1 value;
    in
    if
      builtins.stringLength value == 2 && builtins.hasAttr tens digits && builtins.hasAttr ones digits
    then
      10 * digits.${tens} + digits.${ones}
    else
      null;
  # True proleptic Gregorian validity — a YY.MM.DD regex that accepts 26.02.30
  # is not enough (matches accepted pharos-core `valid_inspr_calendar_version`).
  isCalendarVersion =
    value:
    let
      parts = lib.splitString "." value;
      nums = map twoDigit parts;
      len = builtins.length nums;
    in
    builtins.all (n: n != null) nums
    && (len == 3 || len == 6)
    && (
      let
        year = 2000 + builtins.elemAt nums 0;
        month = builtins.elemAt nums 1;
        day = builtins.elemAt nums 2;
        hour = if len == 6 then builtins.elemAt nums 3 else 0;
        minute = if len == 6 then builtins.elemAt nums 4 else 0;
        second = if len == 6 then builtins.elemAt nums 5 else 0;
        leap = (year / 4 * 4 == year) && (year / 100 * 100 != year || year / 400 * 400 == year);
        days =
          if
            lib.elem month [
              1
              3
              5
              7
              8
              10
              12
            ]
          then
            31
          else if
            lib.elem month [
              4
              6
              9
              11
            ]
          then
            30
          else if month == 2 then
            if leap then 29 else 28
          else
            0;
      in
      days > 0 && day >= 1 && day <= days && hour < 24 && minute < 60 && second < 60
    );
  isArtifactVersion =
    scheme: version:
    if scheme == "legacy" then
      isLegacyVersion version
    else if scheme == "inspr-calendar-v1" then
      isCalendarVersion version
    else
      false;
  isSha256Digest = value: builtins.match "sha256:[0-9a-f]{64}" value != null;
  isCommitDigest = value: builtins.match "[0-9a-f]{40}|[0-9a-f]{64}" value != null;
  isActionId = value: builtins.match "[A-Za-z0-9_-]{8,128}" value != null;
  isAbsolutePath = value: builtins.match "/[^[:space:]]*" value != null;
  # https only, no userinfo/query/fragment, empty or "/" path.
  isSafeOrigin = value: builtins.match "https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?" value != null;
  # Pharos `valid_release_manifest_coordinate`: `kind:coordinate`, kind is a
  # symbol, coordinate is 1-190 chars starting alphanumeric.
  isReleaseManifestCoordinate =
    value:
    let
      pieces = lib.splitString ":" value;
      kind = if pieces == [ ] then "" else builtins.head pieces;
      rest = builtins.tail pieces;
      coordinate = lib.concatStringsSep ":" rest;
      coordLen = builtins.stringLength coordinate;
    in
    rest != [ ]
    && isSymbol kind
    && coordLen >= 1
    && coordLen <= 190
    && builtins.match "[A-Za-z0-9][A-Za-z0-9._/@:+-]*" coordinate != null;

  artifactUnchecked = lib.types.submodule {
    options = {
      versionScheme = lib.mkOption {
        type = lib.types.enum [
          "legacy"
          "inspr-calendar-v1"
        ];
        example = "legacy";
        description = ''
          Required discriminator in the local Pharos adapter v2 contract.
          `legacy` and `inspr-calendar-v1` are distinct tagged types; the scheme
          is never inferred from version punctuation or segment count.
        '';
      };
      version = lib.mkOption {
        type = lib.types.addCheck lib.types.str isLegacyVersion;
        example = "0.1.83";
        description = ''
          Bounded artifact version. Legacy values keep the Pharos `valid_version`
          charset; `inspr-calendar-v1` values must additionally be a real
          `YY.MM.DD` or `YY.MM.DD.hh.mm.ss` calendar coordinate.
        '';
      };
      releaseChannel = lib.mkOption {
        type = lib.types.addCheck lib.types.str isSymbol;
        example = "stable";
        description = "Bounded release channel symbol. Required evidence; never defaulted.";
      };
      releaseSequence = lib.mkOption {
        type = lib.types.ints.unsigned;
        example = 123;
        description = "Non-negative channel ordinal. Required evidence; never invented.";
      };
      digest = lib.mkOption {
        type = lib.types.addCheck lib.types.str isSha256Digest;
        example = "sha256:2d880515627656322876eda1bb07462866d1ac57829fd3d72dc6418fb222a0fa";
        description = "Exact deployed artifact digest: `sha256:` plus 64 lowercase hex.";
      };
      commitDigest = lib.mkOption {
        type = lib.types.addCheck lib.types.str isCommitDigest;
        example = "c68719d7dbaea4a2c5c557c59e7fdb8cd786ace2";
        description = "Lowercase 40- or 64-hex commit digest of the deployed source.";
      };
      releaseManifestCoordinate = lib.mkOption {
        type = lib.types.addCheck lib.types.str isReleaseManifestCoordinate;
        example = "ghcr:inspr-at/pharos/releases/0.1.83";
        description = "Immutable release-set manifest coordinate (`kind:path`). Required evidence; never invented.";
      };
      releaseManifestDigest = lib.mkOption {
        type = lib.types.addCheck lib.types.str isSha256Digest;
        example = "sha256:9f7c57503d2a883d548e41714ba8c37c5049a6e6a3e3fb0add6f460cfc7199ef";
        description = "Digest of the release-set manifest: `sha256:` plus 64 lowercase hex. Required evidence; never invented.";
      };
    };
  };
  artifactType = lib.types.addCheck artifactUnchecked (
    art: isArtifactVersion art.versionScheme art.version
  );

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
        type = lib.types.nullOr (lib.types.addCheck lib.types.str isActionId);
        default = null;
        description = ''
          Deployment only, optional: an existing Pharos UpdateRestart job this
          intent observes. Omit it to let accepted pharosd propose a deterministic
          operator-confirmed guarded job. A supplied id must already be valid;
          this module never confirms or starts the job.
        '';
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
        version_scheme = intent.artifact.versionScheme;
        version = intent.artifact.version;
        release_channel = intent.artifact.releaseChannel;
        release_sequence = intent.artifact.releaseSequence;
        digest = intent.artifact.digest;
        commit_digest = intent.artifact.commitDigest;
        release_manifest_coordinate = intent.artifact.releaseManifestCoordinate;
        release_manifest_digest = intent.artifact.releaseManifestDigest;
      };
    }
    // lib.optionalAttrs (intent.updateRestartJobId != null) {
      update_restart_job_id = intent.updateRestartJobId;
    }
    // lib.optionalAttrs (intent.deploymentHandoffId != null) {
      deployment_handoff_id = intent.deploymentHandoffId;
    };

  document = {
    schema = "inspr.pharos.paimos-delivery-adapter.v2";
    schema_version = 2;
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
      example = "https://pm.barta.cm";
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
          && isArtifactVersion intent.artifact.versionScheme intent.artifact.version
          && isSymbol intent.artifact.releaseChannel
          && intent.artifact.releaseSequence >= 0
          && isSha256Digest intent.artifact.digest
          && isCommitDigest intent.artifact.commitDigest
          && isReleaseManifestCoordinate intent.artifact.releaseManifestCoordinate
          && isSha256Digest intent.artifact.releaseManifestDigest
        ) cfg.intents;
        message = "inspr.pharosPaimosDelivery intent environment/host/artifact values must match the owner-v2 evidence contract (explicit scheme, bounded channel/sequence/digests/manifest coordinate, real calendar dates).";
      }
      {
        assertion = lib.all (
          intent:
          intent.deploymentHandoffId == null
          && (intent.updateRestartJobId == null || isActionId intent.updateRestartJobId)
        ) deploymentIntents;
        message = "A deployment intent must not carry deploymentHandoffId; updateRestartJobId is optional and, if set, must be a valid existing job id.";
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
