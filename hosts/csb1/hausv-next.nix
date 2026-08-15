# NIX-368 / HAUSV-513: one deliberately ungated, tailnet-only preview slot.
# The slot is isolated from every production HAUSV path, secret and network.
{ pkgs, ... }:

let
  hausvNext = pkgs.writeShellApplication {
    name = "hausv-next";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      docker
      gawk
      git
      gnugrep
      gnutar
      iproute2
      util-linux
    ];
    text = builtins.readFile ./scripts/hausv-next.sh;
  };
in
{
  environment.etc = {
    "hausv-next/compose.yml".source = ./docker/hausv-next/compose.yml;
    "hausv-next/Dockerfile".source = ./docker/hausv-next/Dockerfile;
    "hausv-next/fixture.conf".source = ./docker/hausv-next/fixture.conf;
  };

  environment.systemPackages = [ hausvNext ];

  systemd.tmpfiles.rules = [
    "d /var/lib/hausv-next 0700 root root -"
    "d /var/lib/hausv-next/releases 0700 root root -"
    "d /var/lib/hausv-next/quarantine 0700 root root -"
    "d /var/lib/hausv-next/data 0750 65532 65532 -"
    "f /run/lock/compose-hausv-next.lock 0600 root root -"
  ];
}
