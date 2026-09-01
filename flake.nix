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
    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.disko.follows = "disko";
    };
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    nixcfg.url = "github:pbek/nixcfg";
    nixpkgs-zfs.follows = "nixcfg/nixpkgs-zfs";
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
      url = "github:inspr-at/janus/rust-engine-v0.1.17";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # NIX-381 — a SECOND, deliberately separate Janus pin.
    #
    # `janus-paimos-dependency-reporter` is the JANUS-441 external-stage
    # reporter. It does not exist in the pinned v0.1.17 engine, and — audited
    # 2026-08-22 — it is also absent from the release container image: the
    # rust-engine-v0.1.33 `Dockerfile.engine` copies eleven binaries and not
    # this one. The upstream *flake* does install it, so nixcfg can package it
    # from source without editing the Janus repository.
    #
    # It is a separate input rather than a bump of `janus` above because that
    # attribute feeds two live csb1 paths — modules/pharos-guarded-deploy
    # (`janusd`) and modules/janus-host-secrets — and moving them sixteen
    # releases sideways is a far larger blast radius than the single root-only
    # one-shot unit this reporter needs. Retire this input once `janus` itself
    # reaches v0.1.33 or later.
    janus-paimos-reporter = {
      url = "github:inspr-at/janus/rust-engine-v0.1.33";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Paimos — operator CLI plus the process-owning Agent Intercom daemon.
    # NIX-392 deliberately pins a released tag: Home Manager must not move the
    # executable control plane just because upstream main advances. Bumps use
    # the reviewed Paimos release flow and refresh vendorHash when Go deps move.
    paimos = {
      url = "github:inspr-at/paimos/v26.09.01.15.52";
      flake = false;
    };
    # INSPR atelier — public Home Manager + NixOS modules (atelier-pattern
    # graduation; INSPR-27/28). The shared atelier (this library) holds the
    # workstation-side primitives that used to live in modules/shared/ here.
    # Studios (this nixcfg + former-employer studio + future family/paid-product
    # context flakes) provide identity-specific values; the atelier stays
    # opinionated only about mechanics. (Older docs: "Pattern β".)
    inspr-modules.url = "github:inspr-at/inspr-modules";
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
      ...
    }@inputs:

    let
      linuxSystem = "x86_64-linux";
      nixDeploymentEvidence = import ./lib/pharos-deployment-evidence.nix {
        inherit self;
        nixpkgs = inputs.nixpkgs;
        lockFile = ./flake.lock;
      };
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
        claude-agent-sdk = final.callPackage ./pkgs/claude-agent-sdk { };
        # Stub: hokage/desktop.nix references sonar but it doesn't exist in nixpkgs
        sonar = final.hello;
        # Compatibility for pbek/nixcfg c0385905: its desktop module still
        # requests the removed cryfs alias. Nixpkgs recommends gocryptfs until
        # CryFS 2.x stabilises; keep the substitution local and explicit.
        cryfs = final.gocryptfs;
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
          system.configurationRevision = nixDeploymentEvidence.source_revision;
          environment.etc."pharos-deployment/evidence.json".text = builtins.toJSON nixDeploymentEvidence;
          # OPS-186: /etc/pharos-deployment/evidence.json is a symlink into the active
          # generation. A container that bind-mounts that FILE pins the inode from its
          # start and never sees a later switch. Copy the document into a tmpfs
          # directory at every activation; beacons mount the DIRECTORY.
          system.activationScripts.pharosDeploymentEvidence = {
            deps = [ "etc" ];
            text = ''
              mkdir -p /run/pharos-deployment
              install -m 0644 /etc/pharos-deployment/evidence.json /run/pharos-deployment/.evidence.json.tmp
              mv -f /run/pharos-deployment/.evidence.json.tmp /run/pharos-deployment/evidence.json
            '';
          };
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
        nixpkgs-zfs = import inputs.nixpkgs-zfs {
          localSystem = {
            system = linuxSystem;
          };
          config.allowUnfree = true;
        };
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
      # Loads an explicit home module so ONE host can carry SEVERAL users.
      # mbp2606 has two (mba + mailina); Home Manager standalone is per-user, so
      # each gets its own profile and generations (NIX-216).
      mkDarwinHomeModule =
        system: hostname: module:
        home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs {
            localSystem = {
              inherit system;
            };
            config.allowUnfree = true;
            overlays = allOverlays;
          };
          modules = [
            module
          ];
          extraSpecialArgs = commonArgs // {
            inherit inputs hostname;
          };
        };

      # Default: hosts/<hostname>/home.nix
      mkDarwinHome = system: hostname: mkDarwinHomeModule system hostname ./hosts/${hostname}/home.nix;
    in
    {
      inherit commonArgs;

      # ========================================================================
      # macOS Home Manager Configurations
      # ========================================================================
      # Apple Silicon — private M5 Max (was mbp0, now mbp2606). Provisioned
      # 2026-06-15 from the retired work host's config and key material
      # (June 2026 employer exit), so agenix access continues intentionally.
      # Personal-only — the former work push-atelier is disabled in hosts/mbp2606/home.nix.
      # Renamed mbp0 -> mbp2606 (2026-08-07, NIX-216): handed to Mailina, name
      # follows the YYMM commission-month scheme and is immutable thereafter.
      # `mba` stays as Markus's backup/admin account on the machine by design.
      homeConfigurations."mba@mbp2606" = mkDarwinHome "aarch64-darwin" "mbp2606";
      homeConfigurations."mbp2606" = self.homeConfigurations."mba@mbp2606";

      # Second user on the same host — her own identity + tooling, none of
      # Markus's agent/secret plumbing (see hosts/mbp2606/home-mailina.nix).
      homeConfigurations."mailina@mbp2606" =
        mkDarwinHomeModule "aarch64-darwin" "mbp2606"
          ./hosts/mbp2606/home-mailina.nix;

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
      # Deployment evidence is deliberately strict for the NixOS surface: even
      # selecting a server configuration must fail when self.rev or the primary
      # nixpkgs lock facts cannot be proven.
      nixosConfigurations = builtins.deepSeq nixDeploymentEvidence {
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

        # miniserver-bp moved out of this repo on 2026-05-02 (INSPR-24
        # atelier-pattern graduation; "Pattern β" in older docs). It was a
        # former-employer internal-ops host, not a personal one — belonged in
        # that studio. (msbp itself was retired 2026-05-05;
        # successor hosts in the former studio carry that context.)

        # hsb2 (Raspberry Pi Zero W) retired 2026-06-14 (NIX-194): its only job —
        # the FLIRC IR→Sony bridge — moved to hsb1; host config removed from repo.
        # Pi-Zero powered off. SSH-fleet aliases + RPi3B fate tracked in NIX-187.
      };

      # Value-free public evaluation surface used by the NIX-348 contract test
      # and by reviewers inspecting a clean revision.
      inherit nixDeploymentEvidence;

      packages.x86_64-linux = {
        # pingt - Timestamped ping with color-coded output
        pingt = pkgs.callPackage ./pkgs/pingt { };

        # paimos-cli - Agent-facing CLI for PAIMOS
        paimos-cli = pkgs.callPackage ./pkgs/paimos-cli {
          src = inputs.paimos;
        };
        claude-agent-sdk = pkgs.callPackage ./pkgs/claude-agent-sdk { };

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
          claude-agent-sdk = pkgsDarwin.callPackage ./pkgs/claude-agent-sdk { };
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
          claude-agent-sdk = pkgsDarwin.callPackage ./pkgs/claude-agent-sdk { };
        };
    };
}
