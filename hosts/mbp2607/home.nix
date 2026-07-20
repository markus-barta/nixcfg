# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                   mbp2607 — MacBook Pro (Markus, commissioned 2026-07)       ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# First host on the YYMM naming scheme (PPM KB: NIX/guideline/host-naming-scheme)
# and first with user `markus` (mba retired for new hosts). Commissioning: NIX-215.
#
# FRESH START by design: no key material or config carried over from mbp0.
# Secret-dependent modules below are gated OFF until the host's SSH keys exist
# and are registered as agenix recipients (NIX-215 checklist) — flip them on
# in a follow-up commit once `just rekey` ran with the mbp2607 recipient.
#
{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:

let
  macosCommon = import ../../modules/uzumaki/macos-common.nix { inherit pkgs lib; };
in
{
  # ============================================================================
  # Module Imports
  # ============================================================================
  imports = [
    ../../modules/uzumaki/home-manager.nix
    ../../modules/shared/ssh-fleet.nix # Declarative SSH config for fleet hosts (LAN → Tailscale fallback, nicknames)
    # markus-defaults bundles all 3 INSPR public modules + Markus's values
    # (identities, contexts, instances, encrypted-secrets root)
    ../../modules/shared/markus-defaults.nix
  ];

  # ============================================================================
  # INSPR — secret-dependent modules (GATED — see header; NIX-215)
  # ============================================================================
  # Enabled 2026-07-03 (NIX-215): markus@mbp2607 user key in the markus
  # aggregate + host key on agents/shared/* — rekeyed in 31e3d1a8.
  inspr.secrets.agents.enable = true;
  # Non-secret routing only; workstation auth is interactive via OS keyring.
  inspr.paimos-cli.enable = true;
  # mbp2607-personal-userkey minted 2026-07-03, registered on markus-barta
  # GitHub account; privkey in secrets/agents/host/mbp2607/.
  inspr.git.atelier.personal.enable = true;
  # BYTEPOETS history — never enable on this host.
  inspr.git.atelier.bytepoets.enable = false;

  # Git identity is pure config (no secret material) — safe from day 1.
  inspr.git-identity.enable = true;

  # ============================================================================
  # UZUMAKI MODULE - Fish functions, theming, monitoring
  # ============================================================================
  uzumaki = {
    enable = true;
    role = "workstation";
    fish.editor = "nano"; # Options: nano, vim, code, etc.
    stasysmo.enable = true; # System metrics in Starship prompt
  };

  # ============================================================================
  # THEME - Must match actual hostname
  # ============================================================================
  # Palette entry lives in: modules/uzumaki/theme/theme-palettes.nix
  # (teal — greenish per Markus's pick, deliberately distinct from hsb1's
  # green and mbp0's lightGray so hosts stay visually unmistakable.)
  theme.hostname = "mbp2607";

  # ============================================================================
  # USER SETTINGS
  # ============================================================================
  home.username = "markus";
  home.homeDirectory = "/Users/markus";

  home.stateVersion = "24.11";
  home.enableNixpkgsReleaseCheck = false;
  programs.home-manager.enable = true;

  # ============================================================================
  # Fish Shell Configuration
  # ============================================================================
  programs.fish = {
    enable = true;

    shellInit = ''
      # Environment variables
      set -gx TERM xterm-256color
      set -gx EDITOR nano

      # zoxide integration
      set -gx ZOXIDE_CMD z

      # Add Nix profile completions
      if test -d ~/.nix-profile/share/fish/vendor_completions.d
        set -p fish_complete_path ~/.nix-profile/share/fish/vendor_completions.d
      end
    '';

    loginShellInit = ''
      # Ensure Nix paths are prioritized
      fish_add_path --prepend --move ~/.nix-profile/bin
      fish_add_path --prepend --move /nix/var/nix/profiles/default/bin
      # Homebrew (Apple Silicon) before system /usr/bin — brew-doctor compliance
      fish_add_path --prepend --move /opt/homebrew/bin
    '';

    interactiveShellInit = ''
      # Custom greeting
      function fish_greeting
          set_color cyan
          echo -n "Welcome to fish, the friendly interactive shell "
          set_color green
          echo -n (whoami)"@"(hostname -s)
          set_color yellow
          echo -n " · "(date "+%Y-%m-%d %H:%M")
          set_color normal
      end

      # Initialize zoxide
      zoxide init fish | source
    '';

    # Additional functions (pingt, sourcefish, etc. from uzumaki)
    functions = {
      # Custom cd using zoxide
      cd = ''
        if set -q ZOXIDE_CMD
            z $argv
        else
            builtin cd $argv
        end
      '';

      # Sudo with !! support
      sudo = {
        description = "Sudo with !! support";
        body = ''
          if test "$argv" = "!!"
              eval command sudo $history[1]
          else
              command sudo $argv
          end
        '';
      };

      # Homebrew maintenance (macOS-specific)
      brewall = ''
        brew update
        brew upgrade
        brew cleanup
        brew doctor
      '';
    };

    # macOS-specific aliases
    shellAliases = {
      mc = "env LANG=en_US.UTF-8 mc";
      # Force macOS native ping (inetutils has bugs on Darwin)
      ping = "/sbin/ping";
      traceroute = "/usr/sbin/traceroute";
      netstat = "/usr/sbin/netstat";
    };

    # macOS-specific abbreviations
    shellAbbrs = {
      flushdns = "sudo killall -HUP mDNSResponder && echo macOS DNS Cache Reset";
    };
  };

  # ============================================================================
  # Starship Prompt (config generated by theme-hm.nix)
  # ============================================================================
  programs.starship = {
    enable = true;
    enableFishIntegration = true;
    enableBashIntegration = true;
  };

  # ============================================================================
  # Terminal: Ghostty (Homebrew-installed, Nix-config-managed).
  # Config SSOT is `ghosttyConfig` in macos-common.nix — shared across hosts.
  # ============================================================================
  home.file."Library/Application Support/com.mitchellh.ghostty/config".text =
    macosCommon.ghosttyConfig;
  # Sanity check: warn at activation if Ghostty.app is missing OR doubled.
  home.activation.checkGhosttyInstall = macosCommon.ghosttyCheckActivation;
  # NIX-103: warn if macOS DirectoryService login shell doesn't match HM's fish.
  home.activation.checkLoginShell = macosCommon.loginShellCheckActivation "${config.home.homeDirectory}/.nix-profile/bin/fish";

  # macOS `defaults` (SSOT: macos-common.nix). Stops Finder writing .DS_Store to
  # network shares + USB drives — see the comment there for why.
  targets.darwin.defaults = macosCommon.darwinDefaults;

  # ============================================================================
  # Brewfile — declarative cask manifest (apply with `just bundle`)
  # ============================================================================
  # Fresh start: minimal on purpose — pull casks over from mbp0 only when
  # actually missed (its list: android-studio, crystalfetch, github, raycast,
  # utm, zed). Browser cask: add here once chosen (NIX-215 log).
  home.file.".config/homebrew/Brewfile".text = macosCommon.mkBrewfile {
    extraTaps = [
      "darrylmorley/whatcable" # whatcable's tap. brew 6: one-time `brew trust darrylmorley/whatcable` per host before `just bundle`
      "steipete/tap" # codexbar's tap. brew 6 gates loading behind trust (tapped != trusted): one-time `brew trust steipete/tap` per host before `just bundle`
    ];
    extraCasks = [
      "bettertouchtool" # trackpad/gestures — settings + license migrated from mbp0 (NIX-215); config stays BTT-managed, not Nix
      "cmux" # was hand-installed pre-Brewfile; adopted into the manifest so bundle-cleanup keeps it
      "steipete/tap/codexbar" # menu-bar Codex/Claude status app; fully-qualified — tap ships codexbar as BOTH formula and cask, bare name triggers "Treating codexbar as a cask" ambiguity warning
      "crystalfetch" # from mbp0's list (pulled on demand 2026-07-04, NIX-215)
      "github" # GitHub Desktop — from mbp0's list (2026-07-04)
      "helium-browser" # daily-driver browser; profile rsynced from mbp0 2026-07-03 (NIX-215) — hand-installed there, cask-managed here
      "raycast" # launcher — from mbp0's list (2026-07-04)
      "tailscale-app" # GUI variant (standalone, not App Store) — fleet convention for Markus's portables
      "utm" # VMs — from mbp0's list (2026-07-04)
      "whatcable" # cable identifier tool (darrylmorley/whatcable tap)
      "zed" # editor — from mbp0's list (2026-07-04)
    ];
  };

  # ============================================================================
  # Git Configuration
  # ============================================================================
  # Identity is managed by modules/shared/git-identity.nix (see above).
  # This block owns host-specific bits only: ignores + credential helpers.
  programs.git = {
    ignores = [
      "*~"
      ".DS_Store"
    ];

    settings.credential = {
      # Generic fallback (osxkeychain stores user/password for any HTTPS host)
      helper = "osxkeychain";
      # Per-host: GitHub goes through `gh` (token via `gh auth login` until
      # the atelier userkey lands — see gated modules above).
      "https://github.com".helper = "!gh auth git-credential";
      "https://gist.github.com".helper = "!gh auth git-credential";
    };
  };

  # ============================================================================
  # Zsh (System Shell Fallback)
  # ============================================================================
  programs.zsh = {
    enable = true;
    dotDir = "${config.xdg.configHome}/zsh"; # XDG-compliant (keeps home directory clean)
    initContent = ''
      export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
    '';
  };

  # ============================================================================
  # Direnv (Project Environment Loading)
  # ============================================================================
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # ============================================================================
  # Packages
  # ============================================================================
  # `macosCommon.commonPackages` is the single source of truth for the default
  # macOS dev toolkit. Per-host extras below — keep this list lean; if ALL
  # macOS hosts need it, add to commonPackages in macos-common.nix instead.
  home.packages = macosCommon.commonPackages ++ [
    # System Tools (per-arch — agenix pkg comes from `inputs`, not `pkgs`)
    inputs.agenix.packages.aarch64-darwin.default

    # INSPR CLI — agent-ready operating layer (check / heal / onboard)
    inputs.inspr-modules.packages.aarch64-darwin.inspr

    # Media / hardware CLI — adopted from stray brew formulae (drift found
    # 2026-07-19; brew copies removed via `just bundle-cleanup` after switch)
    pkgs.f3 # Fight Flash Fraud — flash-drive capacity tester
    pkgs.ffmpeg # transcoding CLI (brew install pulled 14 dep formulae; Nix build is self-contained)

    # Container stack — ported from mbp0 (2026-07-20; local containers now
    # needed for Janus Docker smoke). Colima owns the long-lived VM at host
    # level; devenv/direnv do not manage the daemon. `colima start` once after
    # switch to bring up the engine.
    pkgs.docker-client # Docker CLI only; engine provided by Colima on macOS
    pkgs.docker-compose # Compose v2 standalone binary; linked as Docker CLI plugin
    pkgs.colima # Lightweight Docker engine VM for macOS, no Docker Desktop
    pkgs.lima # Colima's VM substrate; useful for limactl diagnostics
  ];

  # Enable fontconfig
  fonts.fontconfig.enable = true;

  # Install Hack Nerd Font for macOS
  home.activation.installMacOSFonts = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    echo "Installing Hack Nerd Font for macOS..."
    mkdir -p "$HOME/Library/Fonts"

    FONT_PATH="${pkgs.nerd-fonts.hack}/share/fonts/truetype/NerdFonts/Hack"

    if [ -d "$FONT_PATH" ]; then
      for font in "$FONT_PATH"/*.ttf; do
        if [ -f "$font" ]; then
          font_name=$(basename "$font")
          target="$HOME/Library/Fonts/$font_name"
          if [ -L "$target" ]; then rm "$target"; fi
          if [ ! -e "$target" ]; then
            ln -sf "$font" "$target"
            echo "  Linked: $font_name"
          fi
        fi
      done
      echo "✅ Hack Nerd Font installed for macOS"
    fi
  '';

  # ============================================================================
  # Nano Configuration
  # ============================================================================
  home.file.".nanorc".text = ''
    include ${pkgs.nano}/share/nano/*.nanorc
    set autoindent
    set tabstospaces
    set tabsize 2
    set linenumbers
    set mouse
    set constantshow
  '';

  # ============================================================================
  # Additional Settings
  # ============================================================================
  xdg.enable = true;

  home.sessionVariables = {
    EDITOR = "nano";
  }
  # NIX-288: PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH → Chromium cask binary, so
  # agents get a stable declarative browser path for headless Playwright QA.
  // macosCommon.playwrightSessionVars;
}
