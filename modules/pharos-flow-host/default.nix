# Pharos Flow host wiring (NIX-442 / PHAROS-257).
#
# Generates the value-free `inspr.pharos.flow-host-config.v1` document that
# pharosd reads through PHAROS_FLOW_CONFIG_FILE. Default is off: no runtime
# config, mount, credential or enabled host binding. This module creates no
# credential material — the API key is an external protected file this module
# only names, never reads, copies into the Nix store, prints or commits.
#
# 🔴 What this module deliberately does NOT do: it does not infer operator or
# project associations, does not enable PHAROS-206, and does not grant Flow
# navigation any delivery, provider or Janus authority. A published config is
# projection and guarded Review/Start routing only.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.inspr.pharosFlowHost;
  jsonFormat = pkgs.formats.json { };

  runtimeDirectory = builtins.dirOf cfg.configFile;

  isSymbolStart = value: builtins.match "[A-Za-z][A-Za-z0-9._-]{0,63}" value != null;
  isAbsolutePath = value: builtins.match "/[^[:space:]]*" value != null;
  # https only, no userinfo/query/fragment, empty or "/" path. HTTP loopback
  # is a harness-only Pharos flag and is never accepted here.
  isSafeOrigin = value: builtins.match "https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?" value != null;
  isHostId =
    value:
    let
      len = builtins.stringLength value;
    in
    len >= 1 && len <= 64 && isSymbolStart value;
  isProjectRef =
    value:
    let
      prefix = "paimos:proj-";
      prefixLen = builtins.stringLength prefix;
    in
    builtins.stringLength value > prefixLen && builtins.substring 0 prefixLen value == prefix;
  isNonEmpty = value: builtins.stringLength (lib.trim value) > 0;
  isHostAllow = value: isNonEmpty value && builtins.match ".*[*?@[:space:]].*" value == null;
  isOperatorRef = value: isNonEmpty value && builtins.match ".*[@[:space:]].*" value == null;

  bindingUnchecked = lib.types.submodule {
    options = {
      projectId = lib.mkOption {
        type = lib.types.ints.positive;
        example = 17;
        description = "Paimos project id. Must be >= 1; never invented.";
      };
      projectRef = lib.mkOption {
        type = lib.types.nullOr (lib.types.addCheck lib.types.str isProjectRef);
        default = null;
        example = "paimos:proj-9b2899fb59591130607952d66fcb5607";
        description = ''
          Optional exact Paimos project_ref. When set it must start with
          `paimos:proj-`. When omitted, pharosd derives the opaque ref from
          project_id. Never an email, organisation or mock identity.
        '';
      };
      label = lib.mkOption {
        type = lib.types.addCheck lib.types.str isNonEmpty;
        example = "Test project";
        description = "Nonempty binding label shown in the Flow shell header.";
      };
      hosts = lib.mkOption {
        type = lib.types.listOf (lib.types.addCheck lib.types.str isHostAllow);
        example = [ "hsb8" ];
        description = "Explicit Pharos host allowlist. No wildcards, implicit access or empty entries.";
      };
      operatorRefs = lib.mkOption {
        type = lib.types.listOf (lib.types.addCheck lib.types.str isOperatorRef);
        example = [ "operator-a" ];
        description = "Explicit operator_ref allowlist. Email addresses are rejected; Pharos matches these to the verified human session.";
      };
    };
  };

  renderBinding =
    binding:
    {
      project_id = binding.projectId;
      label = lib.trim binding.label;
      hosts = map lib.trim binding.hosts;
      operator_refs = map lib.trim binding.operatorRefs;
    }
    // lib.optionalAttrs (binding.projectRef != null) {
      project_ref = binding.projectRef;
    };

  document = {
    schema = "inspr.pharos.flow-host-config.v1";
    schema_version = 1;
    enabled = cfg.activate;
    host_id = cfg.hostId;
    paimos_origin = cfg.paimosOrigin;
    api_key_file = cfg.apiKeyFile;
    bindings = map renderBinding cfg.bindings;
  }
  // lib.optionalAttrs (cfg.instanceLabel != null && isNonEmpty cfg.instanceLabel) {
    instance_label = lib.trim cfg.instanceLabel;
  };

  documentFile = jsonFormat.generate "pharos-flow-host-config.json" document;

  owner = toString cfg.containerUid;

  # Atomic publish. Destination is a fresh inode (nlink == 1) with mode
  # 0400 owned by the pharosd container uid. The parent directory must also be
  # that uid with mode 0700: Flow's parser refuses a root-owned 0755 parent
  # (crates/pharosd/src/flow_host.rs validate_parent_directory). A /nix/store
  # path can never satisfy owner/mode/nlink, so this is never the runtime path.
  publish = pkgs.writeShellScript "publish-pharos-flow-host-config" ''
    set -eu
    destination=${lib.escapeShellArg cfg.configFile}
    temporary="${runtimeDirectory}/.config.$$"
    trap '${pkgs.coreutils}/bin/rm -f "$temporary"' EXIT HUP INT TERM
    ${pkgs.coreutils}/bin/install -d -m 0700 -o ${lib.escapeShellArg owner} -g ${lib.escapeShellArg owner} ${lib.escapeShellArg runtimeDirectory}
    ${pkgs.coreutils}/bin/install -m 0400 -o ${lib.escapeShellArg owner} -g ${lib.escapeShellArg owner} \
      ${documentFile} "$temporary"
    ${pkgs.coreutils}/bin/mv -f "$temporary" "$destination"
    trap - EXIT HUP INT TERM
  '';

  unique = values: builtins.length values == builtins.length (lib.unique values);
  bindingCount = builtins.length cfg.bindings;
in
{
  options.inspr.pharosFlowHost = {
    enable = lib.mkEnableOption "declarative Pharos Flow host config wiring";

    activate = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Publish the Flow config and expect compose to set PHAROS_FLOW_CONFIG_FILE.
        🔴 Flip this only together with the matching `active` switch in
        hosts/csb1/pharos-flow-host.nix, and only after the RUNBOOK preflight
        confirms the API-key file exists — pharosd panics at startup on an
        incomplete Flow configuration.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/pharos/flow-host/config.json";
      description = "Private published path of the generated Flow config; identical inside pharosd.";
    };

    containerUid = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 10001;
      description = "Effective uid pharosd runs as. The config parent, config file and API key must be owned by it.";
    };

    hostId = lib.mkOption {
      type = lib.types.str;
      example = "pharos-csb1";
      description = "Pharos Flow host_id: 1-64 chars, first alphabetic, then alphanumeric / `.` / `_` / `-`.";
    };

    instanceLabel = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "Pharos csb1";
      description = "Optional instance label. When omitted, pharosd uses host_id.";
    };

    paimosOrigin = lib.mkOption {
      type = lib.types.str;
      example = "https://pm.barta.cm";
      description = "Credential-free https Paimos origin with no path, query or fragment.";
    };

    apiKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "In-container path of the Flow API key. Its own inode, never shared with the PHAROS-206 delivery key or copied into the Nix store.";
    };

    bindings = lib.mkOption {
      type = lib.types.listOf bindingUnchecked;
      default = [ ];
      description = "Project bindings. Empty until a real project/host/operator tuple is reviewed; `activate` then requires 1-32.";
    };

    generated = lib.mkOption {
      type = jsonFormat.type;
      readOnly = true;
      description = "The rendered Flow config document, for tests and review.";
    };

    source = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      description = "Store path of the rendered Flow config document.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = isHostId cfg.hostId;
        message = "inspr.pharosFlowHost.hostId must be 1-64 characters, start with a letter, and use only alphanumeric / `.` / `_` / `-`.";
      }
      {
        assertion = isSafeOrigin cfg.paimosOrigin;
        message = "inspr.pharosFlowHost.paimosOrigin must be a credential-free https origin with no path, query or fragment.";
      }
      {
        assertion = isAbsolutePath cfg.apiKeyFile && isAbsolutePath cfg.configFile;
        message = "inspr.pharosFlowHost apiKeyFile and configFile must be absolute paths.";
      }
      {
        assertion = cfg.apiKeyFile != cfg.configFile;
        message = "inspr.pharosFlowHost apiKeyFile must be a distinct inode from the published config file.";
      }
      {
        assertion = !cfg.activate || (bindingCount >= 1 && bindingCount <= 32);
        message = "inspr.pharosFlowHost.activate requires 1-32 project bindings; pharosd refuses an empty binding list.";
      }
      {
        assertion = bindingCount <= 32;
        message = "inspr.pharosFlowHost.bindings must not exceed 32 entries.";
      }
      {
        assertion = lib.all (
          binding:
          binding.projectId > 0
          && isNonEmpty binding.label
          && binding.hosts != [ ]
          && builtins.length binding.hosts <= 64
          && unique binding.hosts
          && lib.all isHostAllow binding.hosts
          && binding.operatorRefs != [ ]
          && builtins.length binding.operatorRefs <= 64
          && unique binding.operatorRefs
          && lib.all isOperatorRef binding.operatorRefs
          && (binding.projectRef == null || isProjectRef binding.projectRef)
        ) cfg.bindings;
        message = "inspr.pharosFlowHost bindings must have projectId >= 1, a nonempty label, 1-64 explicit hosts without wildcards, nonempty operator_refs with no email addresses, and an optional project_ref starting with paimos:proj-.";
      }
    ];

    inspr.pharosFlowHost = {
      generated = document;
      source = documentFile;
    };

    systemd.services.pharos-flow-host-config = lib.mkIf cfg.activate {
      description = "Publish the private Pharos Flow host config";
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
