{ config, pkgs, inputs, ... }:
{
  imports = [
    ./desktop-common.nix
    ./desktop-common-plasma6.nix
  ];
}