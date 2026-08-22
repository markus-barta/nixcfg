# Janus -> Paimos external-stage dependency reporter (NIX-381 / JANUS-441).
#
# Root-owned one-shot unit around `janus-paimos-dependency-reporter` from the
# Janus Rust engine. The binary has no listener, no daemon loop, no command
# surface and no argument surface at all — it refuses to start when argc != 1 —
# and it reads exactly one hard-coded path:
#
#   /run/janus-paimos-dependency-reporter/config.json   (SYSTEM_CONFIG_PATH)
#
# so this module publishes that file and nothing else. Evidence is limited by
# the binary to a value-free `authorization` or `credential_handoff` enum plus a
# timestamp; Janus can satisfy or block only its declared prerequisite and can
# never complete an owner stage.
#
# 🔴 Fail-closed by construction. `run()` is fully idempotent: once the durable
# journal records a completed report it returns Ok without a single network
# call, so a repeating timer converges and then goes quiet. Until `activate` is
# set the config file is never published, and ConditionPathExists makes the unit
# *skip* rather than fail — a not-yet-provisioned handoff produces no alerts and
# no flapping.
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

  isHandoffId = value: builtins.match "[0-9A-HJKMNP-TV-Z]{26}" value != null;
  isSymbol = value: builtins.match "[a-z][a-z0-9._-]{0,63}" value != null;
  isWireDigest = value: builtins.match "sha256:[0-9a-f]{64}" value != null;
  isAbsolutePath = value: builtins.match "/[^[:space:]]*" value != null;
  isSafeOrigin = value: builtins.match "https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?" value != null;
  # RFC 3339 UTC, as `valid_timestamp` in the reporter accepts it.
  isTimestamp =
    value:
    builtins.match "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z" value != null;

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
    expected = {
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
    evidence = {
      kind = cfg.evidence.kind;
      observed_at = cfg.evidence.observedAt;
    };
  };

  documentFile = jsonFormat.generate "janus-paimos-dependency-reporter-config.json" document;

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
in
{
  options.inspr.janusPaimosDependencyReporter = {
    enable = lib.mkEnableOption "declarative Janus/Paimos external-stage dependency reporter";

    activate = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Publish the reporter config and arm the timer. 🔴 Flip only together with
        `active` in hosts/csb1/paimos-delivery-stage.nix and only once Paimos has
        minted the handoff and both credential files exist.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      description = "Janus engine build providing bin/janus-paimos-dependency-reporter.";
    };

    paimosOrigin = lib.mkOption {
      type = lib.types.str;
      example = "https://paimos.barta.cm";
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
      description = "The single value-free dependency fact to report. Null until the privileged step is observed.";
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
        assertion = !cfg.activate || (cfg.expected != null && cfg.evidence != null);
        message = "inspr.janusPaimosDependencyReporter.activate requires the minted `expected` binding and one `evidence` fact.";
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
    ];

    inspr.janusPaimosDependencyReporter.generated = lib.mkIf (
      cfg.expected != null && cfg.evidence != null
    ) document;

    # The reporter demands exactly 0700 root on the journal directory, and the
    # journal must outlive a reboot: PAI-810 retains it until evidence is
    # accepted, and an exact-replay journal on tmpfs would re-pull after every
    # restart instead of replaying the recorded bytes.
    systemd.tmpfiles.rules = [
      "d ${builtins.dirOf cfg.journalDirectory} 0700 root root -"
      "d ${cfg.journalDirectory} 0700 root root -"
    ];

    systemd.services.janus-paimos-dependency-reporter-config =
      lib.mkIf (cfg.activate && cfg.expected != null && cfg.evidence != null)
        {
          description = "Publish the private Janus/Paimos dependency reporter config";
          after = [ "systemd-tmpfiles-setup.service" ];
          before = [ "janus-paimos-dependency-reporter.service" ];
          wantedBy = [ "multi-user.target" ];
          restartTriggers = [ documentFile ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            UMask = "0077";
            ExecStart = publish;
          };
        };

    systemd.services.janus-paimos-dependency-reporter = {
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
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        TimeoutStartSec = "60";
      };
    };

    systemd.timers.janus-paimos-dependency-reporter = lib.mkIf cfg.activate {
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
  };
}
