{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkIf
    mkOption
    types
    ;

  cfg = config.services.janus.managedServiceManifest;
  jsonFormat = pkgs.formats.json { };
  runtimeDirectory = "/run/pharos/managed-service-declarations";
  runtimeManifest = "${runtimeDirectory}/manifest.json";
  unsafeLabelFragments = map builtins.fromJSON [
    ''"\u0080"''
    ''"\u0081"''
    ''"\u0082"''
    ''"\u0083"''
    ''"\u0084"''
    ''"\u0085"''
    ''"\u0086"''
    ''"\u0087"''
    ''"\u0088"''
    ''"\u0089"''
    ''"\u008a"''
    ''"\u008b"''
    ''"\u008c"''
    ''"\u008d"''
    ''"\u008e"''
    ''"\u008f"''
    ''"\u0090"''
    ''"\u0091"''
    ''"\u0092"''
    ''"\u0093"''
    ''"\u0094"''
    ''"\u0095"''
    ''"\u0096"''
    ''"\u0097"''
    ''"\u0098"''
    ''"\u0099"''
    ''"\u009a"''
    ''"\u009b"''
    ''"\u009c"''
    ''"\u009d"''
    ''"\u009e"''
    ''"\u009f"''
    ''"\u00a0"''
    ''"\u061c"''
    ''"\u1680"''
    ''"\u2000"''
    ''"\u2001"''
    ''"\u2002"''
    ''"\u2003"''
    ''"\u2004"''
    ''"\u2005"''
    ''"\u2006"''
    ''"\u2007"''
    ''"\u2008"''
    ''"\u2009"''
    ''"\u200a"''
    ''"\u200b"''
    ''"\u200c"''
    ''"\u200d"''
    ''"\u200e"''
    ''"\u200f"''
    ''"\u2028"''
    ''"\u2029"''
    ''"\u202a"''
    ''"\u202b"''
    ''"\u202c"''
    ''"\u202d"''
    ''"\u202e"''
    ''"\u202f"''
    ''"\u205f"''
    ''"\u2060"''
    ''"\u2061"''
    ''"\u2062"''
    ''"\u2063"''
    ''"\u2064"''
    ''"\u2065"''
    ''"\u2066"''
    ''"\u2067"''
    ''"\u2068"''
    ''"\u2069"''
    ''"\u3000"''
    ''"\ufeff"''
  ];

  validRef =
    prefix: value:
    builtins.stringLength value <= 96 && builtins.match "${prefix}[a-z0-9_]{8,}" value != null;
  safeLabel =
    value:
    value != ""
    && value == lib.strings.trim value
    && builtins.stringLength value <= 120
    && builtins.match "[^[:cntrl:]]+" value != null
    && !lib.any (fragment: lib.hasInfix fragment value) unsafeLabelFragments;

  sourceType = types.enum [
    "generated"
    "import"
  ];

  slotType = types.submodule {
    options = {
      slotRef = mkOption {
        type = types.str;
        example = "slot_49c0e8a17d63";
        description = "Opaque stable reference for this declared secret slot.";
      };
      safeLabel = mkOption {
        type = types.str;
        example = "Canary API token";
        description = "Value-free display label; never used as authority.";
      };
      deliveryProfileRef = mkOption {
        type = types.str;
        example = "delivery_2d7a0f63c951";
        description = "Opaque reviewed private-env-file target profile.";
      };
      reloadProfileRef = mkOption {
        type = types.str;
        example = "reload_65bc19f3a087";
        description = "Opaque reviewed service reload profile.";
      };
      healthProfileRef = mkOption {
        type = types.str;
        example = "health_918d0ce7b4a2";
        description = "Opaque reviewed post-reload health profile.";
      };
      allowedSources = mkOption {
        type = types.listOf sourceType;
        default = [ "generated" ];
        example = [
          "generated"
          "import"
        ];
        description = "Reviewed value origins offered by the managed flow.";
      };
    };
  };

  serviceType = types.submodule {
    options = {
      serviceRef = mkOption {
        type = types.str;
        example = "svc_0bca8d31f7e2";
        description = "Opaque stable reference for the reviewed runtime service.";
      };
      safeLabel = mkOption {
        type = types.str;
        example = "Managed service canary";
        description = "Value-free service label; never used as authority.";
      };
      runtimeKind = mkOption {
        type = types.enum [ "compose" ];
        default = "compose";
        description = "Closed v1 runtime kind; new kinds require a contract revision.";
      };
      slots = mkOption {
        type = types.listOf slotType;
        default = [ ];
        description = "Secret slots consumed by this reviewed service.";
      };
    };
  };

  renderSlot = slot: {
    slot_ref = slot.slotRef;
    safe_label = slot.safeLabel;
    consumer_kind = "managed_service";
    delivery = {
      kind = "private_env_file";
      profile_ref = slot.deliveryProfileRef;
    };
    reload = {
      method = "compose_recreate";
      profile_ref = slot.reloadProfileRef;
    };
    health = {
      probe = "compose_healthcheck";
      profile_ref = slot.healthProfileRef;
    };
    allowed_sources = lib.sort builtins.lessThan slot.allowedSources;
  };

  renderService = service: {
    service_ref = service.serviceRef;
    safe_label = service.safeLabel;
    runtime_kind = service.runtimeKind;
    slots = map renderSlot (lib.sort (left: right: left.slotRef < right.slotRef) service.slots);
  };

  renderedServices = map renderService (
    lib.sort (left: right: left.serviceRef < right.serviceRef) cfg.services
  );
  fingerprintBody = {
    host_ref = cfg.hostRef;
    services = renderedServices;
  };
  declarationFingerprint = "decl_${builtins.hashString "sha256" (builtins.toJSON fingerprintBody)}";
  manifest = {
    schema = "inspr.pharos.managed-service-declarations.v1";
    schema_version = 1;
    generated_by = "nixcfg";
    host_ref = cfg.hostRef;
    declaration_fingerprint = declarationFingerprint;
    services = renderedServices;
  };
  manifestFile = jsonFormat.generate "managed-service-declarations.json" manifest;
  publishManifest = pkgs.writeShellScript "publish-managed-service-declarations" ''
    set -eu
    destination=${lib.escapeShellArg runtimeManifest}
    temporary="${runtimeDirectory}/.manifest.$$"
    trap '${pkgs.coreutils}/bin/rm -f "$temporary"' EXIT HUP INT TERM
    ${pkgs.coreutils}/bin/install -d -m 0755 ${lib.escapeShellArg runtimeDirectory}
    ${pkgs.coreutils}/bin/install -m 0644 ${manifestFile} "$temporary"
    ${pkgs.coreutils}/bin/mv -f "$temporary" "$destination"
    trap - EXIT HUP INT TERM
  '';

  serviceRefs = map (service: service.serviceRef) cfg.services;
  slotRefs = lib.concatMap (service: map (slot: slot.slotRef) service.slots) cfg.services;
  unique = values: builtins.length values == builtins.length (lib.unique values);
  every = predicate: values: lib.all predicate values;
in
{
  options.services.janus.managedServiceManifest = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Generate the strict value-free managed-service declaration for Pharos.";
    };
    hostRef = mkOption {
      type = types.str;
      default = "";
      example = "host_58f36c72a91e";
      description = "Opaque enrolled-host reference.";
    };
    services = mkOption {
      type = types.listOf serviceType;
      default = [ ];
      description = "Reviewed managed services and their fixed secret slot profiles.";
    };
    outputPath = mkOption {
      type = types.str;
      default = "pharos/managed-service-declarations.json";
      readOnly = true;
      description = "Stable /etc-relative path for the generated Pharos manifest.";
    };
    declarationFingerprint = mkOption {
      type = types.str;
      readOnly = true;
      description = "Deterministic fingerprint over the canonical declaration body.";
    };
    generated = mkOption {
      type = jsonFormat.type;
      readOnly = true;
      description = "Generated value-free managed-service manifest.";
    };
    source = mkOption {
      type = types.path;
      readOnly = true;
      description = "Generated manifest JSON store path.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = validRef "host_" cfg.hostRef;
        message = "services.janus.managedServiceManifest.hostRef must be an opaque host_ ref.";
      }
      {
        assertion = cfg.services != [ ] && builtins.length cfg.services <= 64;
        message = "managed-service manifest must declare between 1 and 64 services.";
      }
      {
        assertion = unique serviceRefs && unique slotRefs;
        message = "managed-service serviceRef and slotRef values must be globally unique.";
      }
      {
        assertion = every (validRef "svc_") serviceRefs && every (validRef "slot_") slotRefs;
        message = "managed-service serviceRef/slotRef values must be opaque domain refs.";
      }
      {
        assertion = every safeLabel (
          (map (service: service.safeLabel) cfg.services)
          ++ (lib.concatMap (service: map (slot: slot.safeLabel) service.slots) cfg.services)
        );
        message = "managed-service safe labels must be bounded, trimmed, and control-free.";
      }
      {
        assertion = every (
          service: service.slots != [ ] && builtins.length service.slots <= 32
        ) cfg.services;
        message = "each managed service must declare between 1 and 32 slots.";
      }
      {
        assertion = every (
          service:
          every (
            slot:
            validRef "delivery_" slot.deliveryProfileRef
            && validRef "reload_" slot.reloadProfileRef
            && validRef "health_" slot.healthProfileRef
            && slot.allowedSources != [ ]
            && builtins.length slot.allowedSources <= 2
            && unique slot.allowedSources
          ) service.slots
        ) cfg.services;
        message = "managed-service slot profiles and source policies must be closed and unique.";
      }
    ];

    services.janus.managedServiceManifest = {
      inherit declarationFingerprint;
      generated = manifest;
      source = manifestFile;
    };
    environment.etc.${cfg.outputPath}.source = manifestFile;
    systemd.services.pharos-managed-service-declarations = {
      description = "Publish value-free managed-service declarations for Pharos";
      after = [ "systemd-tmpfiles-setup.service" ];
      before = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ manifestFile ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = publishManifest;
      };
    };
  };
}
