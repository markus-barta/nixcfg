{ config, pkgs, inputs, username, ... }:
{
  imports = [
    ./desktop-common.nix
    ./desktop-common-plasma6.nix
  ];

  environment.systemPackages = with pkgs; [
    # Add missing dependency for espanso
    wl-clipboard
  ];

  # Get around: [ERROR] Error: could not open uinput device
  boot.kernelModules = [ "uinput" ];

  # Get around permission denied error on /dev/uinput
  services.udev.extraRules = ''
    KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput", GROUP="input", MODE="0660"
  '';

  home-manager.users.${username} = {
    # https://mynixos.com/home-manager/options/services.espanso
    services.espanso = {
      package = (pkgs.callPackage ../../apps/espanso/espanso.nix { });
    };
  };
}