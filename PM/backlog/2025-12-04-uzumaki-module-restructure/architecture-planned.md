# Module Architecture - Planned State (Uzumaki Restructure)

> 📊 **Flowchart:** See [architecture-planned.mermaid](./architecture-planned.mermaid)

## Module Hierarchy

```text
modules/
├── common.nix                    # Base NixOS config (remains mostly unchanged)
├── lib/
│   └── utils.nix                 # Shared utility functions
├── shared/
│   ├── fish/
│   │   ├── functions.nix         # ← Fish functions (pingt, stress, etc.)
│   │   ├── aliases.nix           # ← Shared aliases
│   │   └── abbreviations.nix     # ← Shared abbreviations
│   ├── theme/
│   │   ├── palettes.nix          # ← Color definitions
│   │   ├── hm.nix                # ← Home-manager theme module
│   │   └── starship-template.toml
│   ├── stasysmo/                 # (stays as-is, good structure)
│   │   ├── nixos.nix
│   │   ├── home-manager.nix
│   │   ├── daemon.sh
│   │   └── reader.sh
│   └── eza-themes/
│       └── sysop.yml
└── uzumaki/                      # ← THE NEW PROPER MODULE
    ├── default.nix               # Entry point with platform detection
    ├── options.nix               # All option definitions
    ├── nixos.nix                 # NixOS-specific implementation
    ├── darwin.nix                # macOS/nix-darwin implementation
    ├── home-manager.nix          # Home-manager integration
    └── README.md                 # Documentation
```

## Usage Examples

### Server Configuration

```nix
# hosts/hsb1/configuration.nix
{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.zfs.nix
    ../../modules/uzumaki              # Single import!
  ];

  uzumaki = {
    enable = true;
    role = "server";

    fish = {
      enable = true;
      functions = {
        pingt = true;
        stress = true;
        helpfish = true;
      };
    };

    theme = {
      enable = true;
      # Palette auto-detected from hostname, or override:
      # palette = "green";
    };

    stasysmo.enable = true;
  };

  hokage = {
    hostName = "hsb1";
    userLogin = "mba";
    role = "server-home";
    # ... other hokage options
  };
}
```

### Desktop Configuration

```nix
# hosts/gpc0/configuration.nix
{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.zfs.nix
    ../../modules/uzumaki
  ];

  uzumaki = {
    enable = true;
    role = "desktop";

    # All fish functions enabled by default for desktop
    # All theme features enabled by default

    stasysmo.enable = true;
  };

  hokage = {
    hostName = "gpc0";
    gaming.enable = true;
    # ... other hokage options
  };
}
```

### macOS Configuration

```nix
# hosts/imac0/home.nix
{
  imports = [
    ../../modules/uzumaki
  ];

  uzumaki = {
    enable = true;
    role = "workstation";

    theme.hostname = "imac0";  # Explicit for macOS (no config.networking)

    # macOS-specific features auto-enabled based on role
  };
}
```

## Key Improvements

### 1. Single Entry Point

**Before:**

```nix
imports = [
  ../../modules/uzumaki/server.nix
  ../../modules/shared/stasysmo/nixos.nix
];
```

**After:**

```nix
imports = [
  ../../modules/uzumaki
];

uzumaki = {
  enable = true;
  role = "server";
  stasysmo.enable = true;
};
```

### 2. Proper NixOS Module Pattern

**Before:** Raw attribute sets with string interpolation

```nix
# uzumaki/server.nix
let
  mkFishFunction = name: def: ''
    function ${name} --description '${def.description}'
      ${def.body}
    end
  '';
in {
  programs.fish.interactiveShellInit = lib.mkAfter ''
    ${mkFishFunction "pingt" fishFunctions.pingt}
  '';
}
```

**After:** Proper module with options and mkIf

```nix
# uzumaki/nixos.nix
{ config, lib, pkgs, ... }:

let
  cfg = config.uzumaki;
in {
  config = lib.mkIf cfg.enable {
    programs.fish.interactiveShellInit = lib.mkIf cfg.fish.enable (
      lib.mkAfter (lib.concatStrings (
        lib.optional cfg.fish.functions.pingt (import ../shared/fish/functions.nix).pingt
        # ...
      ))
    );
  };
}
```

### 3. Platform Detection

The `default.nix` automatically detects the platform and loads the right implementation:

```nix
# uzumaki/default.nix
{ config, lib, pkgs, ... }:

let
  isNixOS = builtins.hasAttr "systemd" config;  # or check for config.system
  isDarwin = pkgs.stdenv.isDarwin;
in {
  imports = [
    ./options.nix
    (if isNixOS then ./nixos.nix else ./darwin.nix)
    ./home-manager.nix
  ];
}
```

### 4. Role-Based Defaults

Each role pre-configures sensible defaults:

| Feature        | server | desktop | workstation |
| -------------- | ------ | ------- | ----------- |
| Fish functions | ✓      | ✓       | ✓           |
| Zellij         | ✓      | ✓       | ✓           |
| Theme          | ✓      | ✓       | ✓           |
| StaSysMo       | opt-in | opt-in  | opt-in      |
| Desktop apps   | ✗      | ✓       | ✓           |
| Plasma-manager | ✗      | ✓       | ✗           |
| WezTerm config | ✗      | ✗       | ✓           |
| macOS apps     | ✗      | ✗       | ✓           |

### 5. Consistent Fish Function Export

Functions defined once, used everywhere without string interpolation:

```nix
# modules/shared/fish/functions.nix
{
  pingt = {
    description = "Timestamped ping with color-coded output";
    body = ''
      # ... implementation
    '';
  };
  # ...
}
```

Both NixOS and macOS modules import this directly and use it in the appropriate way for their platform.

## Relationship to Hokage

```text
┌─────────────────────────────────────────────────────────────────────┐
│                            HOST CONFIG                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────────────────┐        ┌──────────────────────┐           │
│  │       HOKAGE         │        │       UZUMAKI        │           │
│  │   (External from     │        │    (Local module)    │           │
│  │    pbek/nixcfg)      │        │                      │           │
│  ├──────────────────────┤        ├──────────────────────┤           │
│  │ • User management    │        │ • Fish functions     │           │
│  │ • SSH setup          │        │ • Per-host theming   │           │
│  │ • Git config         │        │ • StaSysMo metrics   │           │
│  │ • Desktop apps       │  ──►   │ • Shell aliases      │   ◄──     │
│  │ • Gaming support     │ hokage │ • Zellij config      │ uzumaki   │
│  │ • ZFS utilities      │ options│ • Editor setup       │ options   │
│  │ • Catppuccin (base)  │        │ • Tokyo Night theme  │           │
│  └──────────────────────┘        └──────────────────────┘           │
│           │                               │                          │
│           └───────────────┬───────────────┘                          │
│                           │                                          │
│                           ▼                                          │
│              ┌──────────────────────┐                                │
│              │   FINAL SYSTEM       │                                │
│              │   • Hokage provides  │                                │
│              │     base infra       │                                │
│              │   • Uzumaki provides │                                │
│              │     personalization  │                                │
│              │   • common.nix       │                                │
│              │     integrates both  │                                │
│              └──────────────────────┘                                │
└─────────────────────────────────────────────────────────────────────┘
```

**Key Insight:** Uzumaki is the "son of Hokage" - it builds on top of hokage's infrastructure to add personalized tooling and theming. Hokage handles the heavy lifting (user management, system setup), while Uzumaki adds the personal touch (custom fish functions, per-host color themes).

## Migration Path

1. **Phase 1:** Create `uzumaki/default.nix` and `uzumaki/options.nix`
2. **Phase 2:** Migrate server.nix → `uzumaki/nixos.nix`
3. **Phase 3:** Migrate desktop.nix → extend `uzumaki/nixos.nix`
4. **Phase 4:** Migrate macos.nix → `uzumaki/darwin.nix`
5. **Phase 5:** Update one host (hsb1) as pilot
6. **Phase 6:** Migrate remaining hosts
7. **Phase 7:** Remove old files, update documentation
