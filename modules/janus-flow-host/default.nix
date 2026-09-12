# Janus Flow host wiring (NIX-481 / JANUS-458).
#
# Generates the value-free `inspr.janus.flow-host-config.v1` document read
# through JANUS_FLOW_CONFIG_FILE. The default is fully off: no runtime config,
# mount, credential, or binding. The API key remains an external protected
# file; this module only names its in-container path.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.inspr.janusFlowHost;
  jsonFormat = pkgs.formats.json { };
  runtimeDirectory = builtins.dirOf cfg.configFile;

  isHostId = value: builtins.match "[A-Za-z][A-Za-z0-9._-]{0,63}" value != null;
  isAbsolutePath = value: builtins.match "/[^[:space:]]*" value != null;
  isSafeOrigin = value: builtins.match "https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?" value != null;
  isSafeBrowserUrl =
    value:
    isSafeOrigin value
    || builtins.match "https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9_-]+)+" value != null;
  isProjectRef =
    value:
    let
      prefix = "paimos:proj-";
      prefixLen = builtins.stringLength prefix;
    in
    builtins.stringLength value > prefixLen && builtins.substring 0 prefixLen value == prefix;
  isNonEmpty = value: builtins.stringLength (lib.trim value) > 0;
  isPrincipalRef =
    value:
    let
      normalized = lib.trim value;
    in
    normalized != ""
    && builtins.stringLength normalized <= 128
    && builtins.match ".*[@[:space:]].*" normalized == null;

  bindingType = lib.types.submodule {
    options = {
      projectId = lib.mkOption {
        type = lib.types.ints.positive;
        example = 17;
        description = "Exact Paimos project id; never inferred from an organisation or label.";
      };
      projectRef = lib.mkOption {
        type = lib.types.nullOr (lib.types.addCheck lib.types.str isProjectRef);
        default = null;
        example = "paimos:proj-9b2899fb59591130607952d66fcb5607";
        description = "Optional exact Paimos project_ref. When omitted, Janus derives it from projectId.";
      };
      label = lib.mkOption {
        type = lib.types.addCheck lib.types.str isNonEmpty;
        example = "Delivery stream";
        description = "Nonempty project label shown by the Flow shell.";
      };
      principalRefs = lib.mkOption {
        type = lib.types.listOf (lib.types.addCheck lib.types.str isPrincipalRef);
        example = [ "opaque-oidc-subject" ];
        description = ''
          Exact authenticated Janus session subjects allowed to use this
          project binding. Email addresses, whitespace, wildcards, and inferred
          identity joins are rejected.
        '';
      };
    };
  };

  renderBinding =
    binding:
    {
      project_id = binding.projectId;
      label = lib.trim binding.label;
      principal_refs = map lib.trim binding.principalRefs;
    }
    // lib.optionalAttrs (binding.projectRef != null) {
      project_ref = binding.projectRef;
    };

  document = {
    schema = "inspr.janus.flow-host-config.v1";
    schema_version = 1;
    enabled = cfg.activate;
    host_id = cfg.hostId;
    paimos_origin = cfg.paimosOrigin;
    api_key_file = cfg.apiKeyFile;
    bindings = map renderBinding cfg.bindings;
  }
  // lib.optionalAttrs (cfg.paimosBrowserUrl != null) {
    paimos_browser_url = cfg.paimosBrowserUrl;
  }
  // lib.optionalAttrs (cfg.instanceLabel != null && isNonEmpty cfg.instanceLabel) {
    instance_label = lib.trim cfg.instanceLabel;
  };

  documentFile = jsonFormat.generate "janus-flow-host-config.json" document;
  owner = toString cfg.containerUid;
  group = toString cfg.containerGid;

  # Janus validates both the parent and file after opening with O_NOFOLLOW. A
  # store path cannot satisfy its ownership/mode/link contract, so publish a
  # fresh runtime inode and replace it atomically in the same directory.
  publish = pkgs.writeShellScript "publish-janus-flow-host-config" ''
    set -eu
    destination=${lib.escapeShellArg cfg.configFile}
    temporary="${runtimeDirectory}/.config.$$"
    trap '${pkgs.coreutils}/bin/rm -f "$temporary"' EXIT HUP INT TERM
    ${pkgs.coreutils}/bin/install -d -m 0700 -o ${lib.escapeShellArg owner} -g ${lib.escapeShellArg group} ${lib.escapeShellArg runtimeDirectory}
    ${pkgs.coreutils}/bin/install -m 0400 -o ${lib.escapeShellArg owner} -g ${lib.escapeShellArg group} \
      ${documentFile} "$temporary"
    ${pkgs.coreutils}/bin/mv -f "$temporary" "$destination"
    trap - EXIT HUP INT TERM
  '';

  unique = values: builtins.length values == builtins.length (lib.unique values);
  bindingCount = builtins.length cfg.bindings;
in
{
  options.inspr.janusFlowHost = {
    enable = lib.mkEnableOption "declarative Janus Flow host config wiring";

    activate = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Publish the config consumed through JANUS_FLOW_CONFIG_FILE. Keep false
        until the dedicated API key and exact project/principal binding exist;
        invalid configured input prevents Janus from starting.
      '';
    };
    configFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/janus/flow-host/config.json";
      description = "Private runtime path of the generated Flow config.";
    };
    containerUid = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 100;
      description = "Effective uid of the Janus Go envelope.";
    };
    containerGid = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 101;
      description = "Effective primary gid of the Janus Go envelope.";
    };
    hostId = lib.mkOption {
      type = lib.types.str;
      example = "janus-csb1";
      description = "Flow host_id accepted by Janus: 1-64 safe identifier characters.";
    };
    instanceLabel = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "Janus csb1";
      description = "Optional Flow shell instance label.";
    };
    paimosOrigin = lib.mkOption {
      type = lib.types.str;
      example = "https://pm.barta.cm";
      description = "Server-only HTTPS Paimos origin with no path, query, fragment, or userinfo.";
    };
    paimosBrowserUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://flow.example/paimos";
      description = "Optional HTTPS browser base URL, including a canonical native public base path.";
    };
    apiKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "In-container API-key path. The credential remains outside the Nix store.";
    };
    bindings = lib.mkOption {
      type = lib.types.listOf bindingType;
      default = [ ];
      description = "Explicit project/session-subject bindings. activate requires 1-32 entries.";
    };
    generated = lib.mkOption {
      type = jsonFormat.type;
      readOnly = true;
      description = "Rendered Flow document for review and focused evaluation.";
    };
    source = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      description = "Store source copied into the private runtime inode.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = isHostId cfg.hostId;
        message = "inspr.janusFlowHost.hostId must be 1-64 characters, start with a letter, and use only alphanumeric / `.` / `_` / `-`.";
      }
      {
        assertion = isSafeOrigin cfg.paimosOrigin;
        message = "inspr.janusFlowHost.paimosOrigin must be a credential-free root HTTPS origin.";
      }
      {
        assertion = cfg.paimosBrowserUrl == null || isSafeBrowserUrl cfg.paimosBrowserUrl;
        message = "inspr.janusFlowHost.paimosBrowserUrl must be a credential-free HTTPS URL with a canonical native base path.";
      }
      {
        assertion = isAbsolutePath cfg.apiKeyFile && isAbsolutePath cfg.configFile;
        message = "inspr.janusFlowHost apiKeyFile and configFile must be absolute paths.";
      }
      {
        assertion = builtins.dirOf cfg.apiKeyFile == runtimeDirectory && cfg.apiKeyFile != cfg.configFile;
        message = "inspr.janusFlowHost apiKeyFile must be a distinct inode in the private config directory.";
      }
      {
        assertion = !cfg.activate || (bindingCount >= 1 && bindingCount <= 32);
        message = "inspr.janusFlowHost.activate requires 1-32 explicit bindings.";
      }
      {
        assertion = bindingCount <= 32;
        message = "inspr.janusFlowHost.bindings must not exceed 32 entries.";
      }
      {
        assertion = lib.all (
          binding:
          binding.projectId > 0
          && isNonEmpty binding.label
          && binding.principalRefs != [ ]
          && builtins.length binding.principalRefs <= 64
          && unique binding.principalRefs
          && lib.all isPrincipalRef binding.principalRefs
          && (binding.projectRef == null || isProjectRef binding.projectRef)
        ) cfg.bindings;
        message = "inspr.janusFlowHost bindings require projectId, label, 1-64 unique non-email principalRefs, and an optional paimos:proj- projectRef.";
      }
    ];

    inspr.janusFlowHost = {
      generated = document;
      source = documentFile;
    };

    systemd.services.janus-flow-host-config = lib.mkIf cfg.activate {
      description = "Publish the private Janus Flow host config";
      after = [ "systemd-tmpfiles-setup.service" ];
      before = [
        "docker.service"
        "compose-csb1.service"
      ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ documentFile ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
        ExecStart = publish;
      };
    };

    # Config publication is a hard startup precondition when a binding is
    # active. This declaration merges with the host's existing edge and Docker
    # requirements without weakening either one.
    systemd.services.compose-csb1 = lib.mkIf cfg.activate {
      requires = [ "janus-flow-host-config.service" ];
      after = [ "janus-flow-host-config.service" ];
    };
  };
}
