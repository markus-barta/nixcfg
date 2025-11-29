# csb1 - Cloud Server Barta 1 (Netcup VPS)
# Hokage Migration: 2025-11-29
{
  pkgs,
  lib,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.zfs.nix
    ../../modules/uzumaki/mba-server.nix # Fish sourcefish, zellij, EDITOR
  ];

  # ============================================================================
  # BOOTLOADER CONFIGURATION
  # ============================================================================
  boot.supportedFilesystems = [ "zfs" ];

  boot.loader.grub = {
    enable = true;
    zfsSupport = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    mirroredBoots = [
      {
        devices = [ "nodev" ];
        path = "/boot";
      }
    ];
  };

  # Network settings for the initial RAM disk (initrd)
  boot.initrd.network = {
    enable = true;
    postCommands = ''
      sleep 2
      zpool import -a;
    '';
  };

  # ============================================================================
  # ZFS CONFIGURATION
  # ============================================================================
  services.zfs.autoScrub.enable = true;

  # ============================================================================
  # NETWORKING
  # ============================================================================
  networking = {
    hostName = "csb1";
    hostId = "dabfdc02"; # Required for ZFS
    networkmanager.enable = true;

    # Firewall - allow web traffic
    firewall = {
      allowedTCPPorts = [
        80 # HTTP
        443 # HTTPS
      ];
    };
  };

  # ============================================================================
  # MOSQUITTO MQTT BROKER PERMISSIONS
  # ============================================================================
  users.groups.mosquitto = {
    gid = 1883;
  };

  system.activationScripts.mosquittoPermissions = ''
    if [ -d /home/mba/docker/mosquitto ]; then
      chown -R mba:mosquitto /home/mba/docker/mosquitto
      chmod -R 775 /home/mba/docker/mosquitto
    fi
  '';

  # ============================================================================
  # HOKAGE MODULE CONFIGURATION
  # ============================================================================
  hokage = {
    hostName = "csb1";
    userLogin = "mba";
    userNameLong = "Markus Barta";
    userNameShort = "Markus";
    userEmail = "markus@barta.com";
    role = "server-remote";
    useInternalInfrastructure = false;
    useSecrets = true;
    useSharedKey = false;
    zfs.enable = true;
    zfs.hostId = "dabfdc02";
    programs.git.enableUrlRewriting = false;
    # NOTE: starship & atuin are configured via common.nix (DRY pattern)
  };

  # ============================================================================
  # 🚨 SSH KEY SECURITY - CRITICAL FIX FROM hsb8/hsb1 INCIDENTS
  # ============================================================================
  # The external hokage server-cloud module auto-injects external SSH keys
  # (omega@yubikey, omega@rsa, etc). We use lib.mkForce to REPLACE these
  # with ONLY authorized keys.
  #
  # Security Policy: csb1 allows mba (Markus) SSH keys only.
  #
  # See: hosts/csb1/docs/SSH-KEY-SECURITY-NOTE.md
  # ============================================================================
  users.users.mba = {
    extraGroups = [ "mosquitto" ];

    openssh.authorizedKeys.keys = lib.mkForce [
      # markus@iMac-5k-MBA-home.local (id_rsa)
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H1iVXWYKnHkxQsS7tGsZq3SoHxlVccd+kroMC/DhC4MWwVnJInWwDpo/bz7LiLuh+1Bmq04PswD78EiHVVQ+O7Ckk32heWrywD2vufihukhKRTy5zl6uodb5+oa8PBholTnw09d3M0gbsVKfLEi4NDlgPJiiQsIU00ct/y42nI0s1wXhYn/Oudfqh0yRfGvv2DZowN+XGkxQQ5LSCBYYabBK/W9imvqrxizttw02h2/u3knXcsUpOEhcWJYHHn/0mw33tl6a093bT2IfFPFb3LE2KxUjVqwIYz8jou8cb0F/1+QJVKtqOVLMvDBMqyXAhCkvwtEz13KEyt"
      # hsb1 (miniserver24): Node-RED container SSH automation
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAhUleyXsqtdA4LC17BshpLAw0X1vMLNKp+lOLpf2bw1 mba@miniserver24"
    ];

  };

  # ============================================================================
  # SSH CONFIGURATION
  # ============================================================================
  services.openssh.ports = [ 2222 ];
  # Password auth disabled after successful migration (2025-11-29)

  # ============================================================================
  # 🚨 PASSWORDLESS SUDO - Required (lost when removing serverMba mixin)
  # ============================================================================
  security.sudo-rs.wheelNeedsPassword = false;

  # ============================================================================
  # ZELLIJ THEME - Host-Specific
  # ============================================================================
  # Zellij package + fish sourcefish come from modules/uzumaki/mba-server.nix
  # Only the csb1-specific theme is defined here
  home-manager.users.mba = {
    home.file.".config/zellij/config.kdl".text = ''
      // Zellij keybindings configuration
      keybinds {
          unbind "Ctrl o"
          normal {
              bind "Ctrl a" { MoveTab "Left"; }
              bind "Ctrl e" { SwitchToMode "Session"; }
          }
          session {
              bind "Ctrl e" { SwitchToMode "Normal"; }
          }
          tab {
              bind "c" {
                  NewTab {
                      cwd "~"
                  }
                  SwitchToMode "normal";
              }
          }
      }

      // csb1 theme (pink/magenta)
      themes {
          csb1 {
              bg "#c45fc0"
              fg "#cb54e3"
              red "#f5f5f5"
              green "#cb54e3"
              blue "#0000ff"
              yellow "#ffff00"
              magenta "#ff00ff"
              orange "#ed94ff"
              cyan "#00ffff"
              black "#00000f"
              white "#ffffff"
          }
      }

      session_serialization true
      theme "csb1"
    '';
  };
}
