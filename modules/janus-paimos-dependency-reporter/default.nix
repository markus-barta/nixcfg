# Janus -> Paimos external-stage dependency reporter (NIX-381 / JANUS-441).
#
# Closed root-owned one-shot modes around the Janus Rust engine reporters. Both
# binaries have no listener, daemon loop, command surface or argument surface,
# and both read only their compiled-in paths. The legacy static reporter reads:
#
#   /run/janus-paimos-dependency-reporter/config.json   (SYSTEM_CONFIG_PATH)
#
# Managed completion additionally reads one root-owned binding and one
# uid100:993 immutable ready record. Its binding contains no evidence timestamp;
# Rust derives that only from the validated retained activation observations.
# Janus can satisfy or block only its declared prerequisite and can never
# complete an owner stage.
#
# 🔴 Fail-closed by construction. `run()` is fully idempotent: once the durable
# journal records a completed report it returns Ok without a network call. The
# static mode retains its existing timer; managed completion watches one fixed
# ready path and has a bounded restart burst. Until `activate` is set no config
# is published and no managed unit is armed.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.inspr.janusPaimosDependencyReporter;
  jsonFormat = pkgs.formats.json { };

  # 🔴 Fixed by janus-host/src/paimos.rs. Not an option: the binary accepts no
  # override, and pretending otherwise would let a config land somewhere the
  # reporter never reads.
  configFile = "/run/janus-paimos-dependency-reporter/config.json";
  runtimeDirectory = builtins.dirOf configFile;
  managedBindingFile = "/run/janus-paimos-dependency-reporter/managed-completion-binding.json";
  completionDirectory = "/var/lib/janus-managed-central/completion-dispatch";
  completionReadyFile = "${completionDirectory}/ready.json";
  staticMode = cfg.mode == "static";
  managedMode = cfg.mode == "managedCompletion";
  staticReady = staticMode && cfg.expected != null && cfg.evidence != null;
  managedReady = managedMode && cfg.expected != null && cfg.managedCompletion != null;

  isHandoffId = value: builtins.match "[0-9A-HJKMNP-TV-Z]{26}" value != null;
  isSymbol = value: builtins.match "[a-z][a-z0-9._-]{0,63}" value != null;
  isWireDigest = value: builtins.match "sha256:[0-9a-f]{64}" value != null;
  isHexDigest = value: builtins.match "[0-9a-f]{64}" value != null;
  isAbsolutePath = value: builtins.match "/[^[:space:]]*" value != null;
  isAgenixPath = value: builtins.match "/run/agenix/[A-Za-z0-9._-]+" value != null;
  isSafeOrigin = value: builtins.match "https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?" value != null;
  # RFC 3339 UTC, as `valid_timestamp` in the reporter accepts it.
  isTimestamp =
    value:
    builtins.match "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z" value != null;
  isRef =
    prefix: value:
    builtins.stringLength value >= builtins.stringLength prefix + 8
    && builtins.stringLength value <= 96
    && builtins.match "${prefix}[a-z0-9_]*" value != null;

  expectedType = lib.types.submodule {
    options = {
      dependencyKey = lib.mkOption {
        type = lib.types.str;
        example = "privileged-handoff";
        description = "Declared prerequisite this reporter may satisfy or block. Nothing else.";
      };
      stageKey = lib.mkOption {
        type = lib.types.enum [
          "specification"
          "implementation"
          "qa"
          "deployment"
          "verification"
        ];
        description = "Owner stage the prerequisite belongs to. Janus never completes it.";
      };
      executionNumber = lib.mkOption {
        type = lib.types.ints.positive;
        description = "Exact stage execution this handoff is bound to.";
      };
      planDigest = lib.mkOption {
        type = lib.types.str;
        description = "Immutable attempt-plan digest, `sha256:` plus 64 lowercase hex.";
      };
      predecessorDigest = lib.mkOption {
        type = lib.types.str;
        description = "Predecessor lineage digest, `sha256:` plus 64 lowercase hex.";
      };
      contextDigest = lib.mkOption {
        type = lib.types.str;
        description = "Safe context digest, `sha256:` plus 64 lowercase hex.";
      };
      authorityEpoch = lib.mkOption {
        type = lib.types.ints.positive;
        description = "Authority epoch; a rotation or move invalidates it and the report fails closed.";
      };
      credentialEpoch = lib.mkOption {
        type = lib.types.ints.positive;
        description = "Credential epoch of the minted handoff secret; a rotation fails closed.";
      };
      expiresAt = lib.mkOption {
        type = lib.types.str;
        example = "2026-09-01T00:00:00Z";
        description = "Exact RFC 3339 UTC handoff expiry as Paimos issued it.";
      };
    };
  };

  evidenceType = lib.types.submodule {
    options = {
      kind = lib.mkOption {
        type = lib.types.enum [
          "authorization"
          "credential_handoff"
        ];
        description = "Server-allowlisted value-free evidence kind. No free text, no identifiers, no values.";
      };
      observedAt = lib.mkOption {
        type = lib.types.str;
        example = "2026-08-22T09:00:00Z";
        description = "RFC 3339 UTC instant the privileged fact was observed at the Janus boundary.";
      };
    };
  };

  managedCompletionType = lib.types.submodule {
    options = {
      operationRef = lib.mkOption {
        type = lib.types.str;
        description = "Exact generated-create operation capability reference, `op_` plus 8-93 lowercase identifier characters.";
      };
      hostRef = lib.mkOption {
        type = lib.types.str;
        description = "Reviewed host catalog reference for this one operation.";
      };
      serviceRef = lib.mkOption {
        type = lib.types.str;
        description = "Reviewed service catalog reference for this one operation.";
      };
      slotRef = lib.mkOption {
        type = lib.types.str;
        description = "Reviewed slot catalog reference for this one operation.";
      };
      declarationFingerprint = lib.mkOption {
        type = lib.types.str;
        description = "Reviewed declaration fingerprint for this one operation.";
      };
      secretRef = lib.mkOption {
        type = lib.types.str;
        description = "Reviewed secret reference; never a secret value.";
      };
      scopeRef = lib.mkOption {
        type = lib.types.str;
        description = "Reviewed scope reference for the generated secret.";
      };
      generation = lib.mkOption {
        type = lib.types.ints.positive;
        description = "Exact target generation accepted by the binding.";
      };
      revocationEpoch = lib.mkOption {
        type = lib.types.ints.positive;
        description = "Exact revocation epoch accepted by the binding.";
      };
      planFingerprint = lib.mkOption {
        type = lib.types.str;
        description = "Exact lowercase 64-hex lifecycle plan fingerprint.";
      };
      targetFingerprint = lib.mkOption {
        type = lib.types.str;
        description = "Exact lowercase 64-hex lifecycle target fingerprint.";
      };
      producerKeyId = lib.mkOption {
        type = lib.types.str;
        description = "Reviewed producer signing-key identifier; never key material.";
      };
    };
  };

  expectedDocument = {
    dependency_key = cfg.expected.dependencyKey;
    stage_key = cfg.expected.stageKey;
    execution_number = cfg.expected.executionNumber;
    plan_digest = cfg.expected.planDigest;
    predecessor_digest = cfg.expected.predecessorDigest;
    authority_epoch = cfg.expected.authorityEpoch;
    context_digest = cfg.expected.contextDigest;
    credential_epoch = cfg.expected.credentialEpoch;
    expires_at = cfg.expected.expiresAt;
  };

  # `deny_unknown_fields` on both the document and the tagged evidence enum, so
  # the rendered shape must be exact.
  document = {
    schema = "inspr.janus.paimos-dependency-reporter-config.v1";
    schema_version = 1;
    paimos_origin = cfg.paimosOrigin;
    handoff_id = cfg.handoffId;
    api_key_file = cfg.apiKeyFile;
    handoff_secret_file = cfg.handoffSecretFile;
    journal_directory = cfg.journalDirectory;
    expected = expectedDocument;
    evidence = {
      kind = cfg.evidence.kind;
      observed_at = cfg.evidence.observedAt;
    };
  };

  documentFile = jsonFormat.generate "janus-paimos-dependency-reporter-config.json" document;

  managedConfigDocument = {
    schema = "inspr.janus.paimos-managed-completion-reporter-config.v1";
    schema_version = 1;
    paimos_origin = cfg.paimosOrigin;
    handoff_id = cfg.handoffId;
    api_key_file = cfg.apiKeyFile;
    handoff_secret_file = cfg.handoffSecretFile;
    journal_directory = cfg.journalDirectory;
    expected = expectedDocument;
    evidence = {
      kind = "credential_handoff";
      source = "managed_completion_record";
    };
  };
  managedConfigDigest = "sha256:${builtins.hashString "sha256" (builtins.toJSON managedConfigDocument)}";
  managedReporterBinding = {
    schema = "inspr.janus.paimos-managed-completion-reporter-binding.v1";
    schema_version = 1;
    config_digest = managedConfigDigest;
    handoff_id = cfg.handoffId;
    dependency_key = cfg.expected.dependencyKey;
    stage_key = cfg.expected.stageKey;
    execution_number = cfg.expected.executionNumber;
    plan_digest = cfg.expected.planDigest;
    predecessor_digest = cfg.expected.predecessorDigest;
    authority_epoch = cfg.expected.authorityEpoch;
    context_digest = cfg.expected.contextDigest;
    credential_epoch = cfg.expected.credentialEpoch;
    expires_at = cfg.expected.expiresAt;
    evidence_kind = "credential_handoff";
    evidence_source = "managed_completion_record";
  };
  managedBindingDocument = {
    schema = "inspr.janus.managed-completion-paimos-binding.v2";
    schema_version = 1;
    operation_ref = cfg.managedCompletion.operationRef;
    operation_kind = "create";
    source = "generated";
    host_ref = cfg.managedCompletion.hostRef;
    service_ref = cfg.managedCompletion.serviceRef;
    slot_ref = cfg.managedCompletion.slotRef;
    declaration_fingerprint = cfg.managedCompletion.declarationFingerprint;
    secret_ref = cfg.managedCompletion.secretRef;
    scope_ref = cfg.managedCompletion.scopeRef;
    generation = cfg.managedCompletion.generation;
    revocation_epoch = cfg.managedCompletion.revocationEpoch;
    plan_fingerprint = cfg.managedCompletion.planFingerprint;
    target_fingerprint = cfg.managedCompletion.targetFingerprint;
    producer_key_id = cfg.managedCompletion.producerKeyId;
    reporter = managedReporterBinding;
  };
  managedBindingDigest = "sha256:${builtins.hashString "sha256" (builtins.toJSON managedBindingDocument)}";
  managedCapabilityDocument = {
    schema = "inspr.janus.managed-completion-capability.v1";
    schema_version = 1;
    operation_ref = cfg.managedCompletion.operationRef;
    binding_digest = managedBindingDigest;
  };
  managedOutput = {
    config = managedConfigDocument;
    config_digest = managedConfigDigest;
    binding = managedBindingDocument;
    binding_digest = managedBindingDigest;
    capability = managedCapabilityDocument;
    paths = {
      config = configFile;
      binding = managedBindingFile;
      evidence_directory = completionDirectory;
      ready_evidence = completionReadyFile;
    };
  };

  managedConfigDocumentFile = jsonFormat.generate "janus-paimos-managed-completion-reporter-config.json" managedConfigDocument;
  managedBindingDocumentFile = jsonFormat.generate "janus-paimos-managed-completion-binding.json" managedBindingDocument;

  # 0600 root, fresh inode. The reporter calls symlink_metadata and rejects
  # anything that is not a root-owned regular file with nlink == 1 and no
  # group/other permission bits — a store path fails all three.
  publish = pkgs.writeShellScript "publish-janus-paimos-dependency-reporter-config" ''
    set -eu
    destination=${lib.escapeShellArg configFile}
    temporary="${runtimeDirectory}/.config.$$"
    trap '${pkgs.coreutils}/bin/rm -f "$temporary"' EXIT HUP INT TERM
    ${pkgs.coreutils}/bin/install -d -m 0700 -o root -g root ${lib.escapeShellArg runtimeDirectory}
    ${pkgs.coreutils}/bin/install -m 0600 -o root -g root ${documentFile} "$temporary"
    ${pkgs.coreutils}/bin/mv -f "$temporary" "$destination"
    trap - EXIT HUP INT TERM
  '';

  # Both documents are copied to fresh root-owned inodes. The producer never
  # sees this directory; it receives only the digest capability in its catalog.
  publishManaged = pkgs.writeShellScript "publish-janus-paimos-managed-completion-config" ''
    set -eu
    config_destination=${lib.escapeShellArg configFile}
    binding_destination=${lib.escapeShellArg managedBindingFile}
    config_temporary="${runtimeDirectory}/.managed-config.$$"
    binding_temporary="${runtimeDirectory}/.managed-binding.$$"
    trap '${pkgs.coreutils}/bin/rm -f "$config_temporary" "$binding_temporary"' EXIT HUP INT TERM
    ${pkgs.coreutils}/bin/install -d -m 0700 -o root -g root ${lib.escapeShellArg runtimeDirectory}
    ${pkgs.coreutils}/bin/install -m 0600 -o root -g root ${managedConfigDocumentFile} "$config_temporary"
    ${pkgs.coreutils}/bin/install -m 0600 -o root -g root ${managedBindingDocumentFile} "$binding_temporary"
    ${pkgs.coreutils}/bin/mv -f "$config_temporary" "$config_destination"
    ${pkgs.coreutils}/bin/mv -f "$binding_temporary" "$binding_destination"
    trap - EXIT HUP INT TERM
  '';
in
{
  options.inspr.janusPaimosDependencyReporter = {
    enable = lib.mkEnableOption "declarative Janus/Paimos external-stage dependency reporter";

    mode = lib.mkOption {
      type = lib.types.enum [
        "static"
        "managedCompletion"
      ];
      default = "static";
      description = ''
        Closed reporter mode. `static` preserves the original operator-observed
        evidence document; `managedCompletion` accepts only the fixed
        generated-create completion record produced by the networkless daemon.
      '';
    };

    activate = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Publish the selected reporter mode. Static mode also arms its existing
        timer; managed-completion mode arms only its fixed ready-file path unit
        and bounded one-shot retries. 🔴 Flip only once Paimos has minted the
        handoff and both credential files exist.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      description = "Janus engine build providing the fixed no-argument binary for the selected mode.";
    };

    paimosOrigin = lib.mkOption {
      type = lib.types.str;
      example = "https://pm.barta.cm";
      description = "Credential-free https Paimos origin with no path, query or fragment.";
    };

    handoffId = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Paimos-minted 26-character Crockford base32 dependency handoff id. Empty until minted.";
    };

    apiKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "Root-only 0400 file holding the registered machine API key. Its own inode.";
    };

    handoffSecretFile = lib.mkOption {
      type = lib.types.str;
      description = "Root-only 0400 file holding this handoff's 32 raw bytes. A separate inode from the API key.";
    };

    journalDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/janus-paimos-dependency-reporter/journal";
      description = "Durable exact-replay journal directory; the reporter demands root ownership and exactly mode 0700.";
    };

    expected = lib.mkOption {
      type = lib.types.nullOr expectedType;
      default = null;
      description = "Exact handoff binding Paimos returned at creation. Null until it exists.";
    };

    evidence = lib.mkOption {
      type = lib.types.nullOr evidenceType;
      default = null;
      description = "Static-mode value-free dependency fact. Must remain null in managed-completion mode.";
    };

    managedCompletion = lib.mkOption {
      type = lib.types.nullOr managedCompletionType;
      default = null;
      description = ''
        Exact generated-create transaction association. It contains no path,
        command, credential or dependency selector; the derived capability is
        only `operation_ref` plus the canonical root-binding digest.
      '';
    };

    pollSeconds = lib.mkOption {
      type = lib.types.ints.between 30 3600;
      default = 300;
      description = "Retry cadence. The reporter is idempotent and stops making requests once the journal is complete.";
    };

    configFile = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = configFile;
      description = "Fixed path the reporter binary reads. Not configurable.";
    };

    generated = lib.mkOption {
      type = jsonFormat.type;
      readOnly = true;
      description = "The rendered reporter document, for tests and review.";
    };

    managedCompletionOutput = lib.mkOption {
      type = lib.types.nullOr jsonFormat.type;
      readOnly = true;
      description = "Derived managed config, root binding, canonical digests, capability and fixed paths.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = isSafeOrigin cfg.paimosOrigin;
        message = "inspr.janusPaimosDependencyReporter.paimosOrigin must be a credential-free https origin with no path, query or fragment.";
      }
      {
        assertion =
          isAbsolutePath cfg.apiKeyFile
          && isAbsolutePath cfg.handoffSecretFile
          && isAbsolutePath cfg.journalDirectory;
        message = "inspr.janusPaimosDependencyReporter file and journal options must be absolute paths.";
      }
      {
        assertion = cfg.apiKeyFile != cfg.handoffSecretFile;
        message = "The Janus API key and the raw handoff secret must be distinct files - the reporter refuses a shared inode.";
      }
      {
        assertion = !cfg.activate || staticReady || managedReady;
        message = "inspr.janusPaimosDependencyReporter.activate requires the complete selected-mode binding.";
      }
      {
        assertion = !cfg.activate || isHandoffId cfg.handoffId;
        message = "inspr.janusPaimosDependencyReporter.handoffId must be a Paimos-minted 26-character Crockford base32 id before activation.";
      }
      {
        assertion =
          cfg.expected == null
          || (
            isSymbol cfg.expected.dependencyKey
            && isWireDigest cfg.expected.planDigest
            && isWireDigest cfg.expected.predecessorDigest
            && isWireDigest cfg.expected.contextDigest
            && isTimestamp cfg.expected.expiresAt
          );
        message = "inspr.janusPaimosDependencyReporter.expected values must match the pinned v1 contract shapes.";
      }
      {
        assertion = cfg.evidence == null || isTimestamp cfg.evidence.observedAt;
        message = "inspr.janusPaimosDependencyReporter.evidence.observedAt must be an RFC 3339 UTC timestamp.";
      }
      {
        assertion = (staticMode && cfg.managedCompletion == null) || (managedMode && cfg.evidence == null);
        message = "Static evidence and managed-completion transaction binding are mutually exclusive.";
      }
      {
        assertion = !managedMode || cfg.expected == null || cfg.expected.stageKey == "deployment";
        message = "Managed completion can satisfy only an existing deployment-stage credential_handoff dependency.";
      }
      {
        assertion =
          !managedMode
          || (
            isAgenixPath cfg.apiKeyFile
            && isAgenixPath cfg.handoffSecretFile
            && cfg.journalDirectory == "/var/lib/janus-paimos-dependency-reporter/journal"
          );
        message = "Managed completion requires distinct protected agenix credentials and the fixed durable reporter journal.";
      }
      {
        assertion =
          cfg.managedCompletion == null
          || (
            isRef "op_" cfg.managedCompletion.operationRef
            && isRef "host_" cfg.managedCompletion.hostRef
            && isRef "svc_" cfg.managedCompletion.serviceRef
            && isRef "slot_" cfg.managedCompletion.slotRef
            && isRef "decl_" cfg.managedCompletion.declarationFingerprint
            && isRef "sec_" cfg.managedCompletion.secretRef
            && isRef "scp_" cfg.managedCompletion.scopeRef
            && isHexDigest cfg.managedCompletion.planFingerprint
            && isHexDigest cfg.managedCompletion.targetFingerprint
            && isRef "key_" cfg.managedCompletion.producerKeyId
          );
        message = "Managed-completion transaction references and fingerprints must match the closed Rust binding contract.";
      }
    ];

    inspr.janusPaimosDependencyReporter.generated = lib.mkIf (staticReady || managedReady) (
      if staticMode then document else managedConfigDocument
    );

    inspr.janusPaimosDependencyReporter.managedCompletionOutput =
      if managedReady then managedOutput else null;

    # The reporter demands exactly 0700 root on the journal directory, and the
    # journal must outlive a reboot: PAI-810 retains it until evidence is
    # accepted, and an exact-replay journal on tmpfs would re-pull after every
    # restart instead of replaying the recorded bytes.
    systemd.tmpfiles.rules = [
      "d ${builtins.dirOf cfg.journalDirectory} 0700 root root -"
      "d ${cfg.journalDirectory} 0700 root root -"
    ]
    ++ lib.optionals (managedMode && cfg.activate) [
      "d ${completionDirectory} 0700 100 993 -"
    ];

    systemd.services.janus-paimos-dependency-reporter-config =
      lib.mkIf (cfg.activate && (staticReady || managedReady))
        {
          description = "Publish the private Janus/Paimos dependency reporter config";
          after = [ "systemd-tmpfiles-setup.service" ];
          before =
            if staticMode then
              [ "janus-paimos-dependency-reporter.service" ]
            else
              [
                "janus-paimos-managed-completion-reporter.path"
                "janus-paimos-managed-completion-reporter.service"
              ];
          wantedBy = [ "multi-user.target" ];
          restartTriggers =
            if staticMode then
              [ documentFile ]
            else
              [
                managedConfigDocumentFile
                managedBindingDocumentFile
              ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            UMask = "0077";
            ExecStart = if staticMode then publish else publishManaged;
          };
        };

    systemd.services.janus-paimos-dependency-reporter = lib.mkIf staticMode {
      description = "Report the value-free Janus dependency fact to Paimos (JANUS-441)";
      after = [
        "network-online.target"
        "janus-paimos-dependency-reporter-config.service"
      ];
      wants = [ "network-online.target" ];
      # 🔴 Skip, do not fail: before activation the config does not exist, and a
      # failing unit on every boot would be noise indistinguishable from a real
      # outage. The binary is also fail-closed on its own if the file vanishes.
      unitConfig.ConditionPathExists = configFile;
      serviceConfig = {
        Type = "oneshot";
        # No arguments — the binary exits 1 on argc != 1.
        ExecStart = "${cfg.package}/bin/janus-paimos-dependency-reporter";
        UMask = "0077";
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.journalDirectory ];
        # AF_UNIX is required, not a widening: glibc's getaddrinfo opens a
        # unix socket for NSS (nscd, and nss-resolve if resolved is ever
        # enabled on this host), so without it the reporter cannot resolve the
        # Paimos origin and fails closed forever. Every other network-capable
        # hardened unit in this repo lists the same three families.
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        TimeoutStartSec = "60";
      };
    };

    systemd.timers.janus-paimos-dependency-reporter = lib.mkIf (staticMode && cfg.activate) {
      description = "Retry the Janus dependency report until its journal is complete";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "90s";
        OnUnitActiveSec = "${toString cfg.pollSeconds}s";
        RandomizedDelaySec = "15s";
        Persistent = true;
        Unit = "janus-paimos-dependency-reporter.service";
      };
    };

    # The separate admitted v0.1.35 input contains this reporter binary.
    # Producer-image rollout and explicit host activation remain separate gates;
    # missing configuration stays inert. The immutable v0.1.34 publication is
    # incomplete and must not be consumed.
    systemd.services.janus-paimos-managed-completion-reporter =
      lib.mkIf (managedMode && cfg.activate && managedReady)
        {
          description = "Report one validated managed-create completion to Paimos (NIX-449)";
          requires = [ "janus-paimos-dependency-reporter-config.service" ];
          after = [
            "network-online.target"
            "janus-paimos-dependency-reporter-config.service"
          ];
          wants = [ "network-online.target" ];
          unitConfig = {
            ConditionPathExists = [
              configFile
              managedBindingFile
              completionReadyFile
            ];
            StartLimitIntervalSec = 300;
            StartLimitBurst = 3;
          };
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            Restart = "on-failure";
            RestartSec = "15s";
            User = "root";
            Group = "root";
            # No arguments: the binary rejects argc != 1 and reads only its
            # three compiled-in config/binding/evidence paths.
            ExecStart = "${cfg.package}/bin/janus-paimos-managed-completion-reporter";
            UMask = "0077";
            AmbientCapabilities = [ ];
            CapabilityBoundingSet = [ ];
            LockPersonality = true;
            MemoryDenyWriteExecute = true;
            NoNewPrivileges = true;
            PrivateDevices = true;
            PrivateTmp = true;
            ProtectClock = true;
            ProtectControlGroups = true;
            ProtectHome = true;
            ProtectHostname = true;
            ProtectKernelLogs = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectSystem = "strict";
            ReadOnlyPaths = [
              configFile
              managedBindingFile
              completionReadyFile
              cfg.apiKeyFile
              cfg.handoffSecretFile
            ];
            ReadWritePaths = [ cfg.journalDirectory ];
            RestrictAddressFamilies = [
              "AF_UNIX"
              "AF_INET"
              "AF_INET6"
            ];
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            SystemCallArchitectures = "native";
            TimeoutStartSec = "60";
          };
        };

    # Watch one fixed file; never scan or discover historical journal state.
    # RemainAfterExit keeps a successful PathExists trigger from looping while
    # the immutable ready record remains present.
    systemd.paths.janus-paimos-managed-completion-reporter =
      lib.mkIf (managedMode && cfg.activate && managedReady)
        {
          description = "Watch for one validated managed-completion record";
          requires = [ "janus-paimos-dependency-reporter-config.service" ];
          after = [ "janus-paimos-dependency-reporter-config.service" ];
          wantedBy = [ "multi-user.target" ];
          pathConfig = {
            PathExists = completionReadyFile;
            Unit = "janus-paimos-managed-completion-reporter.service";
          };
        };
  };
}
