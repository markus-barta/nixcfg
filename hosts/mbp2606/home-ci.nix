# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║            mbp2606 — `ci` user: runner pool for inspr-at/paimos             ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Third account on this host (NIX-600). It runs the Lima job VMs and the runner
# controller and holds nothing personal: no git identity, no agent secrets, no
# fleet ssh config. Its only credential is the inspr-mbp2606-runner GitHub App
# key in ~/.config/aeon-builder (1Password: "GitHub App inspr-mbp2606-runner
# (inspr-at)"), which never enters a VM.
#
# Admin on purpose (Markus, 2026-09-30): too many tools fail as a Standard user.
# Apply as ci:
#
#   nix run home-manager -- switch --flake <checkout>#ci@mbp2606
#
# Switch the pool: `aeon-builder on|off|status` here, or from nixcfg on another
# Mac `just mbp2606-builder on|off|status`. Markus turns it off when mailina
# needs the machine.
{ pkgs, ... }:

{
  imports = [ ../../modules/aeon-builder ];

  home.username = "ci";
  home.homeDirectory = "/Users/ci";
  home.stateVersion = "24.11";
  home.enableNixpkgsReleaseCheck = false;
  programs.home-manager.enable = true;

  home.packages = [
    pkgs.just
    pkgs.jq
  ];

  services.aeonBuilder.enable = true;
}
