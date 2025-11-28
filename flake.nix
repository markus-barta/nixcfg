{
  description = "pbek's machines";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-25.05";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
    pia.url = "github:pia-foss/manual-connections";
    pia.flake = false;
    catppuccin.url = "github:catppuccin/starship";
    catppuccin.flake = false;
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
    espanso-fix.url = "github:pitkling/nixpkgs/espanso-fix-capabilities-export";
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
      espanso-fix,
      ...
    }@inputs:

    let
      system = "x86_64-linux";
      overlaysDir = ./overlays;
      overlaysFromDir = builtins.filter (x: x != null) (
        builtins.attrValues (
          builtins.mapAttrs (
            name: type:
            if type == "regular" && builtins.match ".*\\.nix$" name != null then
              import (overlaysDir + "/${name}")
            else
              null
          ) (builtins.readDir overlaysDir)
        )
      );
      # Only include user-defined overlays here (exclude the meta overlays-nixpkgs to avoid recursion)
      validOverlays = builtins.filter (x: builtins.isFunction x) overlaysFromDir;
      # Provide stable and unstable package sets as attributes of pkgs while ensuring our local overlays are also applied there.
      overlays-nixpkgs = _final: _prev: {
        stable = import nixpkgs-stable {
          inherit system;
          config.allowUnfree = true;
          overlays = validOverlays;
        };
        unstable = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = validOverlays;
        };
      };
      allOverlays = validOverlays ++ [ overlays-nixpkgs ];
      commonServerModules = [
        home-manager.nixosModules.home-manager
        ./modules/common.nix # Shared config for ALL servers (fish, starship, packages, etc.)
        { }
        (_: {
          nixpkgs.overlays = allOverlays;
        })
        # We still need the age module for servers, because it needs to evaluate "age" in the services
        agenix.nixosModules.age
      ];
      commonDesktopModules = [
        home-manager.nixosModules.home-manager
        { home-manager.sharedModules = [ plasma-manager.homeModules.plasma-manager ]; }
        (_: {
          nixpkgs.overlays = allOverlays;
        })
        agenix.nixosModules.age
        espanso-fix.nixosModules.espanso-capdacoverride
      ];
      mkDesktopHost =
        hostName: extraModules:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules =
            commonDesktopModules
            ++ [
              ./hosts/${hostName}/configuration.nix
            ]
            ++ extraModules;
          specialArgs = self.commonArgs // {
            inherit inputs;
          };
        };
      mkServerHost =
        hostName: extraModules:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules =
            commonServerModules
            ++ [
              ./hosts/${hostName}/configuration.nix
            ]
            ++ extraModules;
          specialArgs = self.commonArgs // {
            inherit inputs;
          };
        };
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = allOverlays;
      };
    in
    {
      #     config = nixpkgs.config.systems.${builtins.currentSystem}.config;
      #     hostname = config.networking.hostName;
      #    nixosModules = import ./modules { inherit (nixpkgs) lib; };
      commonArgs = {
        lib-utils = import ./lib/utils.nix { inherit (nixpkgs) lib; };
      };

      # ========================================================================
      # macOS Home Manager Configurations
      # ========================================================================
      homeConfigurations."markus@imac0" = home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs {
          system = "x86_64-darwin";
          config.allowUnfree = true;
          overlays = allOverlays;
        };
        modules = [ ./hosts/imac0/home.nix ];
        extraSpecialArgs = self.commonArgs // {
          inherit inputs;
        };
      };
      # Short alias so `home-manager switch --flake .#imac0` also works
      homeConfigurations."imac0" = self.homeConfigurations."markus@imac0";

      homeConfigurations."markus@imac-mba-work" = home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs {
          system = "x86_64-darwin";
          config.allowUnfree = true;
          overlays = allOverlays;
        };
        modules = [ ./hosts/imac-mba-work/home.nix ];
        extraSpecialArgs = self.commonArgs // {
          inherit inputs;
        };
      };
      # Short alias so `home-manager switch --flake .#imac-mba-work` works (what you just tried)
      homeConfigurations."imac-mba-work" = self.homeConfigurations."markus@imac-mba-work";

      # ========================================================================
      # NixOS Configurations
      # ========================================================================
      nixosConfigurations = {
        # MBA Miniserver24 - Build/Test Server
        miniserver24 = mkServerHost "miniserver24" [ disko.nixosModules.disko ];

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

        # MBA Gaming PC
        mba-gaming-pc = mkDesktopHost "mba-gaming-pc" [ disko.nixosModules.disko ];

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
      };

      checks.x86_64-linux = {
        # Unstable (nixos-unstable) test using local overlay package
        qownnotes-unstable = pkgs.testers.runNixOSTest ./tests/qownnotes.nix;
      };

      packages.x86_64-linux = {
        inherit (pkgs) qownnotes;
        qownnotes-stable = pkgs.stable.qownnotes;
      }
      // {
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
    };
}
