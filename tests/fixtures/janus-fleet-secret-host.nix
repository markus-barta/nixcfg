{ ... }:

{
  system.stateVersion = "25.05";
  boot.loader.grub.enable = false;
  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
  };
  systemd.services.fixture-consumer.serviceConfig = {
    Type = "oneshot";
    ExecStart = "/bin/true";
  };

  inspr.janusFleetSecrets.consumers.fixture-consumer = "shared-alert-url";
}
