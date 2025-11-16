# mba-msww87 server
{
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/hokage
    ./disk-config.zfs.nix
  ];

  networking = {
    # SSH is already enabled by the server-common mixin
    firewall = {
      allowedTCPPorts = [
        80 # HTTP
        443 # HTTPS
        8883 # MQTT
      ];
      allowedUDPPorts = [
        443 # HTTPS
      ];
    };
  };

  users.users.gb = {
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDAwgtI71qYnLJnq0PPs/PWR0O+0zvEQfT7QYaHbrPUdILnK5jqZTj6o02kyfce6JLk+xyYhI596T6DD9But943cKFY/cYG037EjlECq+LXdS7bRsb8wYdc8vjcyF21Ol6gSJdT3noAzkZnqnucnvd7D1lae2ZVw7km6GQvz5XQGS/LQ38JpPZ2JYb0ufT3Z1vgigq9GqhCU6C7NdUslJJJ1Lj4JfPqQTbS1ihZqMe3SQ+ctfmHNYniUkd5Potu7wLMG1OJDL13BXu/M5IihgerZ3QuPb2VPQkb37oxKfquMKveYL9bt4fmK+7+CRHJnzFB45HfG5PiTKsyjuPR5A1N3U5Os+9Wrav9YrqDHWjCaFI1EIY4HRM/kRufD+0ncvvXpsp4foS9DAhK5g3OObRlKgPEc4hkD7hC2KBXUt7Kyg6SLL89gD42qSXLxZlxaTD65UaqB28PuOt7+LtKEPhm1jfH65cKu5vGqUp3145hSJuHB4FuA0ieplfxO78psVM= Gerhard@imac-gb.local"
    ];
  };

  hokage = {
    hostName = "mba-msww87";
    users = [
      "mba"
      "gb"
    ];
    zfs.hostId = "cdbc4e20";
    serverMba.enable = true;
  };
}
