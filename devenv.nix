{
  pkgs,
  lib,
  nixpkgs-unstable,
  ...
}:

let
  unstablePkgs = nixpkgs-unstable.legacyPackages.${pkgs.system};

  # Platform detection
  isDarwin = pkgs.stdenv.isDarwin;
  isLinux = pkgs.stdenv.isLinux;

  # Common packages for all platforms
  commonPackages = with pkgs; [
    git
    gum
    prettier
  ];

  # macOS-specific packages (tools migrated from Homebrew)
  darwinPackages = with pkgs; [
    bat
    btop
    ripgrep
    fd
    fzf
    cloc
  ];

  # Linux-specific packages
  linuxPackages = with pkgs; [ ];
in
{
  # https://devenv.sh/reference/options/#cachixpull
  cachix.pull = [
    "devenv"
    "pbek-nixcfg-devenv"
  ];

  # https://devenv.sh/packages/
  packages =
    commonPackages
    ++ lib.optionals isDarwin darwinPackages
    ++ lib.optionals isLinux linuxPackages
    ++ [
      unstablePkgs.nh
      # Add more unstable packages here if needed
    ];

  # Languages (project-specific for nixcfg repo)
  # Note: Global Node/Python available via home-manager on macOS
  # These override globals when in devenv shell for this repo
  languages = lib.optionalAttrs isDarwin {
    javascript.enable = true; # Latest Node.js from nixpkgs
    python.enable = true; # Latest Python 3 from nixpkgs
  };

  enterShell = if isDarwin then "echo '🛠️ nixcfg  macOS'" else "echo '🛠️ nixcfg  Linux'";

  git-hooks.hooks = {
    statix.settings = {
      ignore = [ "hardware-configuration.nix" ];
      config = ''
        nix_version = '2.28.1'
      '';
    };
  };

  # See full reference at https://devenv.sh/reference/options/
}
