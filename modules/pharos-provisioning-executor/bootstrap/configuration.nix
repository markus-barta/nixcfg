{
  lib,
  pkgs,
  runtime,
  ...
}:
{
  assertions = [
    {
      assertion = builtins.match "[a-z0-9][a-z0-9-]{0,62}" runtime.host != null;
      message = "The managed Pharos host name is invalid";
    }
    {
      assertion = builtins.match "https://[^[:space:]]+" runtime.pharos_url != null;
      message = "The managed Pharos endpoint must use HTTPS";
    }
    {
      assertion =
        builtins.match "ssh-ed25519 [A-Za-z0-9+/]+={0,3}( [^[:cntrl:]]+)?" runtime.ssh_public_key != null;
      message = "The managed Pharos operator key must be an Ed25519 public key";
    }
  ];

  boot.initrd.availableKernelModules = [
    "ahci"
    "ata_piix"
    "sd_mod"
    "sr_mod"
    "virtio_blk"
    "virtio_pci"
    "virtio_scsi"
  ];
  boot.loader.grub = {
    enable = true;
    devices = [ runtime.disk ];
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  networking = {
    hostName = runtime.host;
    useDHCP = lib.mkDefault true;
    firewall.allowedTCPPorts = [ 22 ];
  };

  services.openssh = {
    enable = true;
    settings = {
      KbdInteractiveAuthentication = false;
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };
  users.users.root.openssh.authorizedKeys.keys = [ runtime.ssh_public_key ];

  virtualisation = {
    podman.enable = true;
    oci-containers = {
      backend = "podman";
      containers.pharos-beacon = {
        image = "@BEACON_IMAGE@";
        entrypoint = "/usr/local/bin/pharos-beacon";
        autoStart = true;
        environmentFiles = [ "/etc/pharos/pharos-beacon.env" ];
        environment = {
          PHAROS_URL = runtime.pharos_url;
          PHAROS_INTERVAL = toString runtime.heartbeat_interval_secs;
          PHAROS_HOSTNAME = runtime.host;
          PHAROS_ROLE = runtime.role;
        };
        user = "65534:65534";
        extraOptions = [
          "--network=host"
          "--read-only"
          "--cap-drop=ALL"
          "--security-opt=no-new-privileges"
          "--pids-limit=64"
          "--memory=256m"
          "--cpus=0.5"
          "--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=32m,mode=1777"
        ];
      };
    };
  };

  environment.systemPackages = [ pkgs.gitMinimal ];
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  system.stateVersion = "25.11";
}
