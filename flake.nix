{
  description = "pbek's machines";

  inputs = {
    # Using unstable because pbek's hokage requires unstable-only features
    # (environment.corePackages doesn't exist in stable)
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-25.05";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
    pia.url = "github:pia-foss/manual-connections";
    pia.flake = false;
    # Catppuccin: Required by hokage, we use Tokyo Night instead
    # Follow-up tracking lives in PPM (`pm.barta.cm`)
    catppuccin.follows = "nixcfg/catppuccin";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    nixcfg.url = "github:pbek/nixcfg";
    # nixcfg.inputs.nixpkgs.follows = "nixpkgs"; # Do not follow pbek's nixpkgs, use our own
    # pbek's hokage module unconditionally imports inputs.nixhostforge via
    # modules/hokage/nixhostforge.nix. Follow pbek's own locked input so CI does
    # not need a mutable relative-path stub in flake.lock; the service remains
    # disabled unless a host explicitly enables it.
    nixhostforge.follows = "nixcfg/nixhostforge";
    # NCPS - Nix binary Cache Proxy Service
    ncps.url = "github:kalbasit/ncps/ff083aff";
    ncps.inputs.nixpkgs.follows = "nixpkgs";
    # git-hooks — explicit top-level input so devenv uses a current version
    # (ncps pins an old transitive git-hooks-nix without modules/all-modules.nix)
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
    # Helium browser
    helium-nix = {
      url = "github:AlvaroParker/helium-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # OPUS SmartHome Stream to MQTT Bridge
    opus-stream = {
      url = "github:markus-barta/opus-stream-to-mqtt";
      flake = false;
    };
    hostdash = {
      url = "github:markus-barta/hostdash";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    janus = {
      url = "github:markus-barta/janus/rust-engine-v0.1.5";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Paimos — agent-facing CLI. Tracking `main`, so `update-flake-lock`
    # auto-bumps rev+hash on every scheduled run. `vendorHash` in
    # pkgs/paimos-cli/default.nix still has to be refreshed manually when Go
    # deps change (buildGoModule can't read it from flake.lock).
    paimos = {
      url = "github:markus-barta/paimos";
      flake = false;
    };
    # INSPR atelier — public Home Manager + NixOS modules (atelier-pattern
    # graduation; INSPR-27/28). The shared atelier (this library) holds the
    # workstation-side primitives that used to live in modules/shared/ here.
    # Studios (this nixcfg + BYTEPOETS bpnixcfg + future family/paid-product
    # context flakes) provide identity-specific values; the atelier stays
    # opinionated only about mechanics. (Older docs: "Pattern β".)
    inspr-modules.url = "github:markus-barta/inspr-modules";
    inspr-modules.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      home-manager,
      nixpkgs,
      nixpkgs-stable,
      agenix,
      disko,
      plasma-manager,
      ...
    }@inputs:

    let
      linuxSystem = "x86_64-linux";
      # Overlay providing pkgs.stable and pkgs.unstable attributes
      overlays-nixpkgs = _final: _prev: {
        stable = import nixpkgs-stable {
          localSystem = {
            system = linuxSystem;
          };
          config.allowUnfree = true;
        };
        unstable = import nixpkgs {
          localSystem = {
            system = linuxSystem;
          };
          config.allowUnfree = true;
        };
      };
      # Local packages overlay
      overlays-local = final: prev: {
        pingt = final.callPackage ./pkgs/pingt { };
        tokstat = final.callPackage ./pkgs/tokstat { };
        paimos-cli = final.callPackage ./pkgs/paimos-cli {
          src = inputs.paimos;
        };
        # Stub: hokage/desktop.nix references sonar but it doesn't exist in nixpkgs
        sonar = final.hello;
        # direnv 2.37.1's upstream test suite hangs in the Nix sandbox on
        # x86_64-darwin (one of the zsh integration tests blocks indefinitely
        # with no CPU). Upstream CI runs the same suite on every release, so
        # skipping here only loses a redundant local re-run.
        direnv = prev.direnv.overrideAttrs (_: {
          doCheck = false;
          doInstallCheck = false;
        });
        # ncps = inputs.ncps.packages.${final.stdenv.hostPlatform.system}.default;
      };
      allOverlays = [
        overlays-nixpkgs
        overlays-local
      ];
      commonServerModules = [
        home-manager.nixosModules.home-manager
        ./modules/common.nix # Shared config for ALL servers (fish, starship, packages, etc.)
        ./modules/hostdash-manifest.nix # Declarative HostDash/Pharos manifest schema
        { nixpkgs.hostPlatform = linuxSystem; }
        (_: {
          nixpkgs.overlays = allOverlays;
        })
        (_: {
          system.configurationRevision = self.rev or null;
        })
        # We still need the age module for servers, because it needs to evaluate "age" in the services
        agenix.nixosModules.age
      ];
      pkgs = import nixpkgs {
        localSystem = {
          system = linuxSystem;
        };
        config.allowUnfree = true;
        overlays = allOverlays;
      };

      # Shared args for all configurations
      commonArgs = {
        lib-utils = import ./lib/utils.nix { inherit (nixpkgs) lib; };
      };

      # ════════════════════════════════════════════════════════════════════════
      # macOS Home Manager Helper
      # ════════════════════════════════════════════════════════════════════════
      #
      # Creates a Darwin home-manager config with hostname passed for theming.
      # Flakes use pure evaluation, so env vars like $HOST aren't available.
      # This passes hostname explicitly via extraSpecialArgs.
      #
      # First arg `system` is the Darwin system string ("x86_64-darwin" for
      # Intel, "aarch64-darwin" for Apple Silicon). Previously hard-coded to
      # x86_64-darwin; widened to support Apple Silicon hosts (the M5 portable
      # line is aarch64-darwin).
      #
      # Note: NixOS hosts get hostname from config.networking.hostName (see common.nix)
      #
      mkDarwinHome =
        system: hostname:
        home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs {
            localSystem = {
              inherit system;
            };
            config.allowUnfree = true;
            overlays = allOverlays;
          };
          modules = [
            ./hosts/${hostname}/home.nix
          ];
          extraSpecialArgs = commonArgs // {
            inherit inputs hostname;
          };
        };
    in
    {
      inherit commonArgs;

      # ========================================================================
      # macOS Home Manager Configurations
      # ========================================================================
      # Apple Silicon — private M5 Max (mbp0). New physical device, provisioned
      # 2026-06-15 from the retired work host's config and key material
      # (BYTEPOETS departure), so agenix access continues intentionally.
      # Personal-only — BYTEPOETS push-atelier disabled in hosts/mbp0/home.nix.
      homeConfigurations."mba@mbp0" = mkDarwinHome "aarch64-darwin" "mbp0";
      homeConfigurations."mbp0" = self.homeConfigurations."mba@mbp0";

      # Apple Silicon — MacBook Pro, commissioned 2026-07 (NIX-215). First host
      # on the YYMM naming scheme (PPM KB: NIX/guideline/host-naming-scheme) and
      # first with user `markus` (mba retired for new hosts). Fresh start — no
      # key material or config carried over from mbp0 by design; secret-dependent
      # modules gated off in home.nix until agenix recipient registration.
      homeConfigurations."markus@mbp2607" = mkDarwinHome "aarch64-darwin" "mbp2607";
      homeConfigurations."mbp2607" = self.homeConfigurations."markus@mbp2607";

      # ========================================================================
      # NixOS Configurations
      # ========================================================================
      nixosConfigurations = {
        # Home Automation Server - Home Server Barta 1 (formerly miniserver24)
        # Using external hokage consumer pattern
        hsb1 = nixpkgs.lib.nixosSystem {
          modules = commonServerModules ++ [
            inputs.nixcfg.nixosModules.hokage # External hokage module
            ./hosts/hsb1/configuration.nix
            disko.nixosModules.disko
          ];
          specialArgs = self.commonArgs // {
            inherit inputs;
            # lib-utils already provided by self.commonArgs
          };
        };

        # DNS/DHCP Server (AdGuard Home) - Home Server Barta 0
        # DNS/DHCP Server (AdGuard Home) - Home Server Barta 0
        # Using external hokage consumer pattern
        hsb0 = nixpkgs.lib.nixosSystem {
          modules = commonServerModules ++ [
            inputs.nixcfg.nixosModules.hokage # External hokage module
            ./hosts/hsb0/configuration.nix
            disko.nixosModules.disko
          ];
          specialArgs = self.commonArgs // {
            inherit inputs;
            # lib-utils already provided by self.commonArgs
          };
        };

        # Gaming PC 0 (formerly mba-gaming-pc)
        # Using external hokage consumer pattern
        # NOTE: common.nix must load AFTER hokage to override its settings (fish, zellij, theme)
        gpc0 = nixpkgs.lib.nixosSystem {
          modules = [
            { nixpkgs.hostPlatform = linuxSystem; }
            home-manager.nixosModules.home-manager
            { home-manager.sharedModules = [ plasma-manager.homeModules.plasma-manager ]; }
            (_: { nixpkgs.overlays = allOverlays; })
            agenix.nixosModules.age
            # espanso-fix removed - espanso is disabled and it pulls in rustc!
            inputs.nixcfg.nixosModules.hokage # External hokage module (loads first)
            ./modules/common.nix # OUR config (loads AFTER hokage to override)
            ./hosts/gpc0/configuration.nix
            disko.nixosModules.disko
          ];
          specialArgs = self.commonArgs // {
            inherit inputs;
          };
        };

        # Home Server Barta 8 (Parents' home automation server)
        # Using external hokage consumer pattern
        hsb8 = nixpkgs.lib.nixosSystem {
          modules = commonServerModules ++ [
            inputs.nixcfg.nixosModules.hokage # External hokage module
            ./hosts/hsb8/configuration.nix
            disko.nixosModules.disko
          ];
          specialArgs = self.commonArgs // {
            inherit inputs;
            # lib-utils already provided by self.commonArgs
          };
        };

        # Home Server Barta 9 (Parents-in-law home automation server)
        # Mac mini Late 2009, ext4 (no disko, no ZFS)
        # NIX-138 (2026-05-27): forcedeth-DHCP-race workaround via static IP
        hsb9 = nixpkgs.lib.nixosSystem {
          modules = commonServerModules ++ [
            inputs.nixcfg.nixosModules.hokage # External hokage module
            ./hosts/hsb9/configuration.nix
          ];
          specialArgs = self.commonArgs // {
            inherit inputs;
          };
        };

        # Cloud Server Barta 1 (Netcup VPS - Grafana, InfluxDB, Paperless, Docmost)
        # Hokage Migration: 2025-11-29
        # Using external hokage consumer pattern
        csb1 = nixpkgs.lib.nixosSystem {
          modules = commonServerModules ++ [
            inputs.nixcfg.nixosModules.hokage # External hokage module
            ./hosts/csb1/configuration.nix
            disko.nixosModules.disko
          ];
          specialArgs = self.commonArgs // {
            inherit inputs;
            # lib-utils already provided by self.commonArgs
          };
        };

        # Cloud Server Barta 0 (Netcup VPS - Node-RED, MQTT, Smart Home Hub)
        # Hokage Migration: Planned 2025-11
        # Using external hokage consumer pattern
        csb0 = nixpkgs.lib.nixosSystem {
          modules = commonServerModules ++ [
            inputs.nixcfg.nixosModules.hokage # External hokage module
            ./hosts/csb0/configuration.nix
            disko.nixosModules.disko
          ];
          specialArgs = self.commonArgs // {
            inherit inputs;
            # lib-utils already provided by self.commonArgs
          };
        };

        # miniserver-bp moved to BYTEPOETS/bpnixcfg on 2026-05-02 (INSPR-24
        # atelier-pattern graduation; "Pattern β" in older docs). It was a
        # BYTEPOETS internal-ops host, not a personal one — belonged in the
        # BYTEPOETS studio. (msbp itself was retired 2026-05-05;
        # bonelio-staging + bonelio-live now carry the BYTEPOETS context.)

        # hsb2 (Raspberry Pi Zero W) retired 2026-06-14 (NIX-194): its only job —
        # the FLIRC IR→Sony bridge — moved to hsb1; host config removed from repo.
        # Pi-Zero powered off. SSH-fleet aliases + RPi3B fate tracked in NIX-187.
      };

      packages.x86_64-linux = {
        # pingt - Timestamped ping with color-coded output
        pingt = pkgs.callPackage ./pkgs/pingt { };

        # paimos-cli - Agent-facing CLI for PAIMOS
        paimos-cli = pkgs.callPackage ./pkgs/paimos-cli {
          src = inputs.paimos;
        };

        # Generate Markdown docs for hokage module options.
        # NOTE: hokage is consumed as a flake input (`inputs.nixcfg`) — pbek's
        # nixcfg, NOT a local module here. The path used to be `./modules/hokage`
        # back when hokage was vendored locally; that path is stale and would
        # break `nix flake check` (and any direct eval) with "Path does not
        # exist in Git repository". Use the flake-input's source path instead.
        hokage-options-md =
          let
            inherit (nixpkgs) lib;
            makeOptionsDoc = import (nixpkgs + "/nixos/lib/make-options-doc");
            # Minimal utils implementation needed by some modules during evaluation
            utilsStub = {
              removePackagesByName =
                list: excluded:
                lib.filter (
                  p: !(lib.any (q: (q.pname or q.name or "") == (p.pname or p.name or "")) excluded)
                ) list;
            };
            eval = lib.evalModules {
              modules = [
                { _module.check = false; }
                (inputs.nixcfg + "/modules/hokage")
              ];
              # Provide required special arguments used by the modules
              specialArgs = self.commonArgs // {
                inherit inputs pkgs;
                utils = utilsStub;
              };
            };
            # Patch problematic examples that reference removed kernels
            optionsHokagePatched =
              let
                oh = eval.options.hokage;
              in
              oh
              // {
                kernel = (oh.kernel or { }) // {
                  requirements = (oh.kernel.requirements or { }) // {
                    example = [ ];
                  };
                };
              };
            docs = makeOptionsDoc {
              inherit lib pkgs;
              options = optionsHokagePatched;
            };
          in
          docs.optionsCommonMark;
      };

      # Legacy x86_64 macOS package outputs (no active x86_64-darwin host).
      packages.x86_64-darwin =
        let
          pkgsDarwin = import nixpkgs {
            localSystem = {
              system = "x86_64-darwin";
            };
            config.allowUnfree = true;
          };
        in
        {
          pingt = pkgsDarwin.callPackage ./pkgs/pingt { };
          paimos-cli = pkgsDarwin.callPackage ./pkgs/paimos-cli {
            src = inputs.paimos;
          };
        };

      packages.aarch64-darwin =
        let
          pkgsDarwin = import nixpkgs {
            localSystem = {
              system = "aarch64-darwin";
            };
            config.allowUnfree = true;
          };
        in
        {
          pingt = pkgsDarwin.callPackage ./pkgs/pingt { };
          paimos-cli = pkgsDarwin.callPackage ./pkgs/paimos-cli {
            src = inputs.paimos;
          };
        };
    };
}
