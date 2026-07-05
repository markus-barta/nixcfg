{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    literalExpression
    mkIf
    mkOption
    types
    ;

  cfg = config.services.hostdash.manifest;
  jsonFormat = pkgs.formats.json { };
  palettes = import ./uzumaki/theme/theme-palettes.nix;

  hostName = config.networking.hostName;
  defaultPaletteName =
    if builtins.hasAttr hostName palettes.hostPalette then
      palettes.hostPalette.${hostName}
    else
      palettes.defaultPalette;
  effectivePaletteName = if cfg.paletteName != null then cfg.paletteName else defaultPaletteName;
  paletteExists = builtins.hasAttr effectivePaletteName palettes.palettes;
  selectedPalette =
    if paletteExists then
      palettes.palettes.${effectivePaletteName}
    else
      {
        name = effectivePaletteName;
        category = "unknown";
        description = "";
        gradient.primary = "#000000";
        text = { };
        zellij = { };
      };

  effectiveSlug = if cfg.slug != null then cfg.slug else cfg.host.name;
  effectiveStorageKey =
    if cfg.storageKey != null then cfg.storageKey else "hostdash.${effectiveSlug}";
  effectiveOutputPath =
    if cfg.outputPath != null then cfg.outputPath else "hostdash-config/${effectiveSlug}.json";

  statusType = types.enum [
    "up"
    "down"
    "cert"
    "external"
    "protected"
    "checking"
    "passive"
  ];

  metaItemType = types.either types.str (
    types.submodule {
      options = {
        text = mkOption {
          type = types.str;
          example = "hosts/hsb8/docker";
          description = "Metadata text shown by HostDash.";
        };
        code = mkOption {
          type = types.bool;
          default = false;
          example = true;
          description = "Render this metadata item as code.";
        };
      };
    }
  );

  wingType = types.submodule {
    options = {
      id = mkOption {
        type = types.str;
        example = "home";
        description = "Stable wing identifier used by service cards.";
      };
      name = mkOption {
        type = types.str;
        example = "Home Automation";
        description = "Human-readable wing label.";
      };
      color = mkOption {
        type = types.str;
        default = "var(--home)";
        example = "var(--home)";
        description = "HostDash CSS color token or literal color for this wing.";
      };
      icon = mkOption {
        type = types.str;
        default = "server";
        example = "house";
        description = "HostDash icon id without the i- prefix.";
      };
    };
  };

  serviceType = types.submodule {
    options = {
      wing = mkOption {
        type = types.str;
        example = "home";
        description = "Wing id that owns this service card.";
      };
      name = mkOption {
        type = types.str;
        example = "Home Assistant";
        description = "Service card title.";
      };
      purpose = mkOption {
        type = types.str;
        default = "";
        example = "Home automation hub";
        description = "Short service purpose shown on the card.";
      };
      icon = mkOption {
        type = types.str;
        default = "server";
        example = "logo-ha";
        description = "HostDash icon id without the i- prefix.";
      };
      url = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "http://hsb8.lan:8123/";
        description = "Primary URL for active service cards.";
      };
      urls = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = literalExpression ''
          {
            lanHostname = "http://hsb8.lan:8123/";
            lanIp = "http://192.168.1.100:8123/";
            tailnet = "http://hsb8:8123/";
          }
        '';
        description = "Named URL variants for LAN, IP, tailnet, and public access patterns.";
      };
      sameHost = mkOption {
        type = types.bool;
        default = false;
        example = true;
        description = "Whether HostDash may rewrite this URL to the dashboard host.";
      };
      scheme = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "http:";
        description = "Optional URL scheme override when sameHost is true.";
      };
      port = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = ":8123";
        description = "Display port and same-host target port.";
      };
      hostPort = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = ":8443";
        description = "Target port when it differs from the displayed port.";
      };
      path = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/";
        description = "Target path when sameHost URL rewriting is enabled.";
      };
      search = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "?view=dashboard";
        description = "Target query string when sameHost URL rewriting is enabled.";
      };
      passive = mkOption {
        type = types.bool;
        default = false;
        example = true;
        description = "Render the card as informational rather than clickable.";
      };
      foot = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "agent · outbound only";
        description = "Footer text for passive cards.";
      };
      status = mkOption {
        type = types.nullOr statusType;
        default = null;
        example = "external";
        description = "Optional static status. Runtime status belongs to Pharos.";
      };
      probe = mkOption {
        type = types.nullOr (types.either types.bool types.str);
        default = null;
        example = false;
        description = "HostDash probe policy hint. Runtime probe results are not stored here.";
      };
      certIssue = mkOption {
        type = types.bool;
        default = false;
        example = true;
        description = "Render the HostDash TLS-certificate static status.";
      };
      note = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "Protected by SSO";
        description = "Optional tooltip note for this service.";
      };
      statusPolicy = mkOption {
        type = types.submodule {
          options = {
            source = mkOption {
              type = types.enum [
                "hostdash-probe"
                "hostdash-static"
                "passive"
                "pharos-runtime"
              ];
              default = "hostdash-probe";
              example = "pharos-runtime";
              description = "Declared owner or method for service status.";
            };
            staticState = mkOption {
              type = types.nullOr statusType;
              default = null;
              example = "external";
              description = "Static status value when source is hostdash-static.";
            };
          };
        };
        default = { };
        example = literalExpression ''
          {
            source = "hostdash-static";
            staticState = "external";
          }
        '';
        description = "Declared status policy without embedding runtime state.";
      };
      privilegedAction = mkOption {
        type = types.bool;
        default = false;
        example = false;
        description = "Whether this card exposes a privileged action that must route through Janus.";
      };
    };
  };

  optionalNonNull = name: value: lib.optionalAttrs (value != null) { ${name} = value; };

  serviceUrlVariants =
    service:
    let
      scheme =
        if service.scheme != null then
          lib.removeSuffix ":" service.scheme
        else if service.url != null && lib.hasPrefix "https://" service.url then
          "https"
        else
          "http";
      port =
        if service.hostPort != null then
          service.hostPort
        else if service.port != null then
          service.port
        else
          "";
      path = if service.path != null then service.path else "/";
      search = if service.search != null then service.search else "";
    in
    lib.mapAttrs (_: accessHost: "${scheme}://${accessHost}${port}${path}${search}") cfg.host.access;

  renderService =
    service:
    let
      effectiveUrls =
        if service.urls != { } then
          service.urls
        else if cfg.host.access != { } && (service.port != null || service.hostPort != null) then
          serviceUrlVariants service
        else
          { };
    in
    {
      inherit (service)
        wing
        name
        purpose
        icon
        sameHost
        passive
        certIssue
        statusPolicy
        privilegedAction
        ;
      urls = effectiveUrls;
    }
    // optionalNonNull "url" service.url
    // optionalNonNull "scheme" service.scheme
    // optionalNonNull "port" service.port
    // optionalNonNull "hostPort" service.hostPort
    // optionalNonNull "path" service.path
    // optionalNonNull "search" service.search
    // optionalNonNull "foot" service.foot
    // optionalNonNull "status" service.status
    // optionalNonNull "probe" service.probe
    // optionalNonNull "note" service.note;

  manifest = {
    schema = "inspr.hostdash.config.v1";
    version = 1;
    generatedBy = "nixcfg";
    slug = effectiveSlug;
    storageKey = effectiveStorageKey;
    host = cfg.host;
    meta = cfg.meta;
    palette = {
      name = effectivePaletteName;
      displayName = selectedPalette.name;
      category = selectedPalette.category;
      description = selectedPalette.description;
      accent = selectedPalette.gradient.primary;
      gradient = selectedPalette.gradient;
      text = selectedPalette.text;
      zellij = selectedPalette.zellij;
    };
    wings = cfg.wings;
    services = map renderService cfg.services;
    policy = {
      declaredOnly = true;
      runtimeStateOwner = cfg.runtimeStateOwner;
      privilegedActions = cfg.privilegedActions;
    };
  };

  wingIds = map (wing: wing.id) cfg.wings;
  missingWingIds = lib.unique (
    lib.filter (wingId: !(lib.elem wingId wingIds)) (map (service: service.wing) cfg.services)
  );
in
{
  options.services.hostdash.manifest = {
    enable = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = "Generate a declarative HostDash/Pharos host manifest.";
    };

    slug = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "hsb8";
      description = "Stable HostDash slug. Defaults to host.name.";
    };

    storageKey = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "hostdash.hsb8";
      description = "Browser storage key used by HostDash. Defaults to hostdash.<slug>.";
    };

    outputPath = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "hostdash-config/hsb8.json";
      description = "Path under /etc for the generated JSON artifact.";
    };

    effectiveOutputPath = mkOption {
      type = types.str;
      readOnly = true;
      description = "Resolved /etc-relative path for the generated JSON artifact.";
    };

    paletteName = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "custom-hsb8";
      description = ''
        Palette name from modules/uzumaki/theme/theme-palettes.nix.
        Defaults to the existing hostPalette mapping, then the palette file default.
      '';
    };

    host = mkOption {
      type = types.submodule {
        options = {
          name = mkOption {
            type = types.str;
            default = hostName;
            example = "hsb8";
            description = "Host name shown by HostDash.";
          };
          role = mkOption {
            type = types.str;
            default = "services";
            example = "parents' home";
            description = "Short host role or site label.";
          };
          os = mkOption {
            type = types.str;
            default = "NixOS";
            example = "NixOS";
            description = "Operating system label.";
          };
          fqdn = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "hsb8.lan";
            description = "Preferred LAN hostname or FQDN.";
          };
          ip = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "192.168.1.100";
            description = "Preferred LAN IP address.";
          };
          site = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "ww87";
            description = "Physical or logical site label.";
          };
          title = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "hsb8 · parents' home";
            description = "Browser title override.";
          };
          heading = mkOption {
            type = types.str;
            default = "Services";
            example = "Services";
            description = "Main HostDash heading.";
          };
          eyebrow = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "NixOS · hsb8.lan · 192.168.1.100";
            description = "Optional HostDash eyebrow text.";
          };
          subtitle = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "parents' home · hsb8.lan · 192.168.1.100 · NixOS";
            description = "Optional HostDash subtitle text.";
          };
          access = mkOption {
            type = types.attrsOf types.str;
            default = { };
            example = literalExpression ''
              {
                lanHostname = "hsb8.lan";
                lanIp = "192.168.1.100";
                tailnet = "hsb8";
              }
            '';
            description = "Named host access hints for consumers that need URL variants.";
          };
        };
      };
      default = { };
      example = literalExpression ''
        {
          name = "hsb8";
          role = "parents' home";
          fqdn = "hsb8.lan";
          ip = "192.168.1.100";
        }
      '';
      description = "Host metadata rendered into the generated manifest.";
    };

    meta = mkOption {
      type = types.listOf metaItemType;
      default = [ ];
      example = literalExpression ''
        [
          { text = "hosts/hsb8/docker"; code = true; }
          { text = "hsb8-home"; code = true; }
          "Europe/Vienna"
        ]
      '';
      description = "HostDash metadata chips.";
    };

    wings = mkOption {
      type = types.listOf wingType;
      default = [ ];
      example = literalExpression ''
        [
          { id = "home"; name = "Home Automation"; color = "var(--home)"; icon = "house"; }
        ]
      '';
      description = "Declared HostDash service groups.";
    };

    services = mkOption {
      type = types.listOf serviceType;
      default = [ ];
      example = literalExpression ''
        [
          {
            wing = "home";
            name = "Home Assistant";
            purpose = "Home automation hub";
            icon = "logo-ha";
            url = "http://hsb8.lan:8123/";
            urls.lanIp = "http://192.168.1.100:8123/";
            sameHost = true;
            port = ":8123";
          }
        ]
      '';
      description = "Declared HostDash service cards. Runtime state belongs to Pharos.";
    };

    runtimeStateOwner = mkOption {
      type = types.enum [
        "pharos"
        "hostdash"
        "none"
      ];
      default = "pharos";
      example = "pharos";
      description = "System that owns runtime/observed state for this manifest.";
    };

    privilegedActions = mkOption {
      type = types.submodule {
        options = {
          mode = mkOption {
            type = types.enum [
              "none"
              "janus"
              "external"
            ];
            default = "none";
            example = "none";
            description = "How privileged actions are handled for this host manifest.";
          };
          janusRequired = mkOption {
            type = types.bool;
            default = false;
            example = false;
            description = "Whether privileged actions must route through Janus.";
          };
        };
      };
      default = { };
      example = literalExpression ''
        {
          mode = "janus";
          janusRequired = true;
        }
      '';
      description = "Declared privileged-action boundary for Agora consumers.";
    };

    generated = mkOption {
      type = jsonFormat.type;
      readOnly = true;
      description = "Generated HostDash/Pharos manifest value.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = paletteExists;
        message = "services.hostdash.manifest.paletteName must exist in theme-palettes.nix: ${effectivePaletteName}";
      }
      {
        assertion = missingWingIds == [ ];
        message = "services.hostdash.manifest.services references undefined wing id(s): ${lib.concatStringsSep ", " missingWingIds}";
      }
      {
        assertion = (!cfg.privilegedActions.janusRequired) || cfg.privilegedActions.mode == "janus";
        message = "services.hostdash.manifest.privilegedActions.mode must be janus when janusRequired is true.";
      }
    ];

    services.hostdash.manifest = {
      generated = manifest;
      effectiveOutputPath = effectiveOutputPath;
    };

    environment.etc.${effectiveOutputPath}.source =
      jsonFormat.generate "hostdash-${effectiveSlug}-config.json" manifest;
  };
}
