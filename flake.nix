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
    # See: +pm/backlog/2025-12-01-catppuccin-follows-cleanup.md
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
    # NixFleet - Fleet management dashboard
    nixfleet.url = "github:markus-barta/nixfleet";
    nixfleet.inputs.nixpkgs.follows = "nixpkgs";
    # NCPS - Nix binary Cache Proxy Service
    ncps.url = "github:kalbasit/ncps";
    ncps.inputs.nixpkgs.follows = "nixpkgs";
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
      system = "x86_64-linux";
      # Overlay providing pkgs.stable and pkgs.unstable attributes
      overlays-nixpkgs = _final: _prev: {
        stable = import nixpkgs-stable {
          inherit system;
          config.allowUnfree = true;
        };
        unstable = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
      };
      # Local packages overlay
      overlays-local = final: _prev: {
        pingt = final.callPackage ./pkgs/pingt { };
        ncps = inputs.ncps.packages.${final.system}.default;
        nixfleet-agent = inputs.nixfleet.packages.${final.system}.default;
      };
      allOverlays = [
        overlays-nixpkgs
        overlays-local
      ];
      commonServerModules = [
        home-manager.nixosModules.home-manager
        ./modules/common.nix # Shared config for ALL servers (fish, starship, packages, etc.)
        { }
        (_: {
          nixpkgs.overlays = allOverlays;
        })
        # We still need the age module for servers, because it needs to evaluate "age" in the services
        agenix.nixosModules.age
        # NixFleet agent for fleet management
        inputs.nixfleet.nixosModules.nixfleet-agent
      ];
      pkgs = import nixpkgs {
        inherit system;
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
      # Note: NixOS hosts get hostname from config.networking.hostName (see common.nix)
      #
      mkDarwinHome =
        hostname:
        home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs {
            system = "x86_64-darwin";
            config.allowUnfree = true;
            overlays = allOverlays;
          };
          modules = [
            ./hosts/${hostname}/home.nix
            # NixFleet agent for fleet management
            inputs.nixfleet.homeManagerModules.nixfleet-agent
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
      homeConfigurations."markus@imac0" = mkDarwinHome "imac0";
      homeConfigurations."imac0" = self.homeConfigurations."markus@imac0";

      homeConfigurations."markus@mba-imac-work" = mkDarwinHome "mba-imac-work";
      homeConfigurations."mba-imac-work" = self.homeConfigurations."markus@mba-imac-work";

      homeConfigurations."mba@mba-mbp-work" = mkDarwinHome "mba-mbp-work";
      homeConfigurations."mba-mbp-work" = self.homeConfigurations."mba@mba-mbp-work";

      # ========================================================================
      # NixOS Configurations
      # ========================================================================
      nixosConfigurations = {
        # Home Automation Server - Home Server Barta 1 (formerly miniserver24)
        # Using external hokage consumer pattern
        hsb1 = nixpkgs.lib.nixosSystem {
          inherit system;
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
          inherit system;
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
          inherit system;
          modules = [
            home-manager.nixosModules.home-manager
            { home-manager.sharedModules = [ plasma-manager.homeModules.plasma-manager ]; }
            (_: { nixpkgs.overlays = allOverlays; })
            agenix.nixosModules.age
            # espanso-fix removed - espanso is disabled and it pulls in rustc!
            inputs.nixcfg.nixosModules.hokage # External hokage module (loads first)
            ./modules/common.nix # OUR config (loads AFTER hokage to override)
            ./hosts/gpc0/configuration.nix
            disko.nixosModules.disko
            # NixFleet agent for fleet management
            inputs.nixfleet.nixosModules.nixfleet-agent
          ];
          specialArgs = self.commonArgs // {
            inherit inputs;
          };
        };

        # Home Server Barta 8 (Parents' home automation server)
        # Using external hokage consumer pattern
        hsb8 = nixpkgs.lib.nixosSystem {
          inherit system;
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

        # Cloud Server Barta 1 (Netcup VPS - Grafana, InfluxDB, Paperless, Docmost)
        # Hokage Migration: 2025-11-29
        # Using external hokage consumer pattern
        csb1 = nixpkgs.lib.nixosSystem {
          inherit system;
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
          inherit system;
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
      };

      packages.x86_64-linux = {
        # pingt - Timestamped ping with color-coded output
        pingt = pkgs.callPackage ./pkgs/pingt { };

        # Generate Markdown docs for hokage module options
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
                ./modules/hokage
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

      # macOS packages (for imac0, mba-mbp-work, etc.)
      packages.x86_64-darwin = {
        pingt =
          let
            pkgsDarwin = import nixpkgs {
              system = "x86_64-darwin";
              config.allowUnfree = true;
            };
          in
          pkgsDarwin.callPackage ./pkgs/pingt { };
      };

      packages.aarch64-darwin = {
        pingt =
          let
            pkgsDarwin = import nixpkgs {
              system = "aarch64-darwin";
              config.allowUnfree = true;
            };
          in
          pkgsDarwin.callPackage ./pkgs/pingt { };
      };
    };
}
