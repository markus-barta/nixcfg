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
            beforeUnits = [ ];
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
            agent = {
              enable = true;
              tokenFile = "/run/agenix/pharos-managed-host-agent-token";
              composeProject = "csb1";
              profiles = [
                {
                  serviceRef = "svc_0bca8d31f7e2";
                  slotRef = "slot_49c0e8a17d63";
                  deliveryProfileRef = "delivery_2d7a0f63c951";
                  reloadProfileRef = "reload_65bc19f3a087";
                  healthProfileRef = "health_918d0ce7b4a2";
                  composeFile = "/home/mba/Code/nixcfg/hosts/csb1/docker/docker-compose.yml";
                  composeService = "janus-managed-secret-canary";
                  containerName = "janus-managed-secret-canary";
                }
              ];
            };
          };
        }
      )
    ];
  };
  failedAssertions = builtins.filter (item: !item.assertion) evaluated.config.assertions;
  service = evaluated.config.systemd.services.janus-host-secret-restore;
  agent = evaluated.config.systemd.services.janus-managed-host-agent;
in
assert failedAssertions == [ ];
assert service.before == [ ];
assert service.requiredBy == [ ];
assert service.serviceConfig.ReadOnlyPaths == [ "/etc/ssh/ssh_host_ed25519_key" ];
assert service.serviceConfig.CapabilityBoundingSet == "";
assert
  agent.requires == [
    "docker.service"
    "janus-host-secret-restore.service"
  ];
assert agent.serviceConfig.ExecStart == "${pkgs.hello}/bin/janus-managed-host-agent";
assert
  agent.serviceConfig.RestrictAddressFamilies == [
    "AF_INET"
    "AF_INET6"
    "AF_UNIX"
  ];
assert agent.serviceConfig.CapabilityBoundingSet == "";
"janus_host_module_eval=ok"
