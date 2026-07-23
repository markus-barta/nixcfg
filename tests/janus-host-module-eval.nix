let
  flake = builtins.getFlake (toString ../.);
  system = "x86_64-linux";
  pkgs = flake.inputs.nixpkgs.legacyPackages.${system};
  evaluated = flake.inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    specialArgs = {
      inputs = flake.inputs;
    };
    modules = [
      ../modules/janus-host-secrets/default.nix
      (
        { ... }:
        {
          system.stateVersion = "25.05";
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          inspr.janusHostSecrets = {
            enable = true;
            package = pkgs.hello;
            hostRef = "host_58f36c72a91e";
            scopeRef = "scp_0123456789abcdef0123456789abcdef01234567";
            producerKeys = [
              {
                keyId = "key_7f4a29c10e8d";
                publicKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
              }
            ];
            slots = [
              {
                serviceRef = "svc_0bca8d31f7e2";
                slotRef = "slot_49c0e8a17d63";
                secretRef = "sec_7a6fd9e3b521";
                declarationFingerprint = "decl_a84f209c4b32";
              }
            ];
          };
        }
      )
    ];
  };
  failedAssertions = builtins.filter (item: !item.assertion) evaluated.config.assertions;
  service = evaluated.config.systemd.services.janus-host-secret-restore;
in
assert failedAssertions == [ ];
assert service.before == [ "docker.service" ];
assert service.requiredBy == [ "docker.service" ];
assert service.serviceConfig.ReadOnlyPaths == [ "/etc/ssh/ssh_host_ed25519_key" ];
assert service.serviceConfig.CapabilityBoundingSet == "";
"janus_host_module_eval=ok"
