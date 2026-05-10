# Uzumaki macOS Common - Shared macOS configuration for all Mac hosts
# Provides common fish + starship + Ghostty (config) + Brewfile (cask manifest).
#
# Key exports (consumed by per-host home.nix):
#   - fishConfig                   programs.fish settings (functions, aliases, abbrs)
#   - ghosttyConfig                ~/Library/.../com.mitchellh.ghostty/config text
#   - ghosttyCheckActivation       HM activation script: warns if Ghostty.app
#                                   missing or doubled (single source of truth check)
#   - mkBrewfile { ... }           Renders ~/.config/homebrew/Brewfile from
#                                   commonCasks/Taps + per-host extras (NIX-107)
#   - commonPackages               Default macOS Nix packages (CLI tools)
#   - nanoConfig                   ~/.nanorc text
#   - fontActivation               Hack Nerd Font installer (HM activation)
#   - appLinkActivation            Empty since WezTerm purge 2026-05-05
#
# History:
#   - 2026-05-05: WezTerm purged fleet-wide; Ghostty became the daily
#                  (still installed via Homebrew — maintainer doesn't ship Nix)
#   - 2026-05-10: Ghostty config moved into Nix (ghosttyConfig)
#                  + install-state check (ghosttyCheckActivation)
#                  + declarative cask manifest via mkBrewfile (NIX-107 Path A)
#
# Usage in home.nix (for mba-imac-work style):
#   let macosCommon = import ../../modules/uzumaki/macos-common.nix { inherit pkgs lib; };
#   in { programs.fish = macosCommon.fishConfig; ... }
#
{ pkgs, lib, ... }:

let
  # Import fish configuration (consolidated into uzumaki)
  fishModule = import ./fish;
  fishAliases = fishModule.aliases;
  fishAbbrs = fishModule.abbreviations;
  uzumakiFunctions = fishModule.functions;

  # ── NIX-107: declarative cask manifest baseline ─────────────────────
  # commonCasks/Taps are scoped here (let-bindings) so mkBrewfile below
  # can reference them. Not exported in the returned attrset because
  # consumers wire only via `mkBrewfile { extraCasks = ...; ... }`.
  # See the doc comment block on `mkBrewfile` for the full rationale.
  commonCasks = [
    "ghostty" # Terminal — config wired in this same file (ghosttyConfig export)
  ];
  commonTaps = [
    # (none currently universal — all observed taps are per-host:
    # ddev/ddev on M5, 7 dev-tool taps on imac0. Keep empty until a true
    # cross-host need emerges.)
  ];
in
{
  # ============================================================================
  # Fish Shell Configuration (macOS-specific)
  # ============================================================================
  fishConfig = {
    enable = true;

    # Shell initialization (config.fish equivalent)
    shellInit = ''
      # NOTE: Mouse tracking reset removed - was breaking Starship $fill
      # Fix tracked historically in PPM

      # Environment variables
      set -gx TERM xterm-256color
      set -gx EDITOR nano

      # zoxide integration
      set -gx ZOXIDE_CMD z

      # Add Nix profile completions to fish (enables completions for just, fd, etc.)
      if test -d ~/.nix-profile/share/fish/vendor_completions.d
        set -p fish_complete_path ~/.nix-profile/share/fish/vendor_completions.d
      end
    '';

    # Login shell initialization - prepend Nix paths to PATH
    loginShellInit = ''
      # Ensure Nix paths are prioritized
      fish_add_path --prepend --move ~/.nix-profile/bin
      fish_add_path --prepend --move /nix/var/nix/profiles/default/bin
      # VSCodium CLI (codium) - installed via Homebrew cask
      fish_add_path --append /Applications/VSCodium.app/Contents/Resources/app/bin
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

    # Functions - uzumaki functions + macOS-specific
    functions = {
      # Uzumaki shared functions
      inherit (uzumakiFunctions)
        pingt
        sourcefish
        stress
        helpfish
        imacw
        ;

      # Custom cd function using zoxide
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

      # Homebrew maintenance
      brewall = ''
        brew update
        brew upgrade
        brew cleanup
        brew doctor
      '';
    };

    # Aliases - merge uzumaki config with macOS-specific aliases
    shellAliases = fishAliases // {
      # macOS specific aliases
      mc = "env LANG=en_US.UTF-8 mc";
      # Force macOS native ping (inetutils ping has bugs on Darwin)
      ping = "/sbin/ping";
      # Other macOS network tools for reference
      traceroute = "/usr/sbin/traceroute";
      netstat = "/usr/sbin/netstat";
    };

    # Abbreviations - merge uzumaki config with macOS-specific abbreviations
    # SSH shortcuts (hsb0, hsb1, hsb8, gpc0, csb0, csb1) are in uzumaki/fish/config.nix
    shellAbbrs = fishAbbrs // {
      co = "codium ."; # Open VSCodium editor
      flushdns = "sudo killall -HUP mDNSResponder && echo macOS DNS Cache Reset";
    };
  };

  # ============================================================================
  # Ghostty Terminal — config + install-state check (since 2026-05-10)
  # WezTerm pre-2026-05-05; Ghostty replaces it. NIX-106 follow-up tracks the
  # bigger question of declarative brew management (Brewfile / nix-darwin).
  # ============================================================================
  #
  # Install-ownership model (single source of truth per concern):
  #   - Ghostty.app  →  Homebrew (`brew install --cask ghostty`)
  #                     Why: Ghostty maintainer doesn't ship a Nix package
  #                     (deliberate stance). Homebrew is the only sane
  #                     macOS-native install path today.
  #   - Ghostty config → Nix (this file → ~/Library/.../config)
  #                     Why: declarative SSOT across all 4 macOS hosts.
  #
  # The `ghosttyCheckActivation` script below WARNS at HM activation time if:
  #   - The config is wired but no Ghostty.app is found (config wasted)
  #   - Multiple Ghostty.app installs are detected (doubled stuff — pick one)
  # Silent on the happy path (single Homebrew install in /Applications/).
  #
  # Wire-up at consumer (per-host home.nix):
  #   home.file."Library/Application Support/com.mitchellh.ghostty/config".text =
  #     macosCommon.ghosttyConfig;
  #   home.activation.checkGhosttyInstall = macosCommon.ghosttyCheckActivation;
  #
  # Conservative ports of WezTerm choices: Hack Nerd Font Mono @ 12pt, Tokyo Night,
  # macOS-blurred translucent window, blinking bar cursor, Option-as-Alt for special
  # chars. Defaults inherited where Ghostty's defaults already do the right thing
  # (cmd+c/v copy/paste, cmd+plus/minus font-size, cmd+t tabs — no custom keybinds).
  # Login shell intentionally NOT set — Ghostty inherits from chsh, which respects
  # each user's per-host shell choice (fish on M5/imac0; whatever on BYTEPOETS Macs).
  ghosttyConfig = ''
    # ─────────────────────────────────────────────────────────────────────
    # INSPR-managed Ghostty config
    # SOURCE OF TRUTH: nixcfg/modules/uzumaki/macos-common.nix → ghosttyConfig
    # Edit there + `just safe-switch` to apply. Do NOT hand-edit this file.
    # Ghostty 1.3+ format. https://ghostty.org/docs/config
    # ─────────────────────────────────────────────────────────────────────

    # ── Fonts ──
    font-family = Hack Nerd Font Mono
    font-size = 12

    # ── Theme (Tokyo Night, matches our Starship/Eza palette) ──
    theme = tokyonight

    # ── Window ──
    window-padding-x = 8
    window-padding-y = 8
    window-padding-balance = true
    background-opacity = 0.92
    background-blur-radius = 10

    # ── Cursor ──
    cursor-style = bar
    cursor-style-blink = true

    # ── macOS Option key for special chars (Alt+7 = | etc.) ──
    macos-option-as-alt = true

    # ── Quality-of-life ──
    confirm-close-surface = false
    copy-on-select = false
    mouse-hide-while-typing = true
  '';

  # ── Install-state sanity check (companion to ghosttyConfig above) ──
  # Runs at every HM activation. Warns on misalignment between "Nix wrote
  # the config" and "macOS has the .app to read it." Doesn't block — advisory.
  # See the doc comment block above for the install-ownership model.
  ghosttyCheckActivation = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    # Detect Ghostty.app in known locations.
    ghostty_locations=()
    [ -d "/Applications/Ghostty.app" ] && ghostty_locations+=("/Applications/Ghostty.app")
    [ -d "$HOME/Applications/Ghostty.app" ] && ghostty_locations+=("$HOME/Applications/Ghostty.app")

    # Detect install method (best-effort: Caskroom presence = Homebrew).
    install_method="unknown"
    if [ -d "/opt/homebrew/Caskroom/ghostty" ] || [ -d "/usr/local/Caskroom/ghostty" ]; then
        install_method="Homebrew (cask)"
    fi

    n=''${#ghostty_locations[@]}
    if [ "$n" -eq 0 ]; then
        echo ""
        echo "⚠️  Ghostty config wired in Nix, but Ghostty.app NOT FOUND."
        echo "   The rendered config at ~/Library/Application Support/com.mitchellh.ghostty/"
        echo "   config has nothing to read it. Install Ghostty via Homebrew:"
        echo "       brew install --cask ghostty"
        echo "   (See modules/uzumaki/macos-common.nix → ghosttyConfig install-ownership note.)"
    elif [ "$n" -gt 1 ]; then
        echo ""
        echo "⚠️  Multiple Ghostty.app installations detected:"
        for loc in "''${ghostty_locations[@]}"; do
            echo "       • $loc"
        done
        echo "   Recommend keeping ONLY the Homebrew install (/Applications/Ghostty.app)"
        echo "   and removing any duplicates. Spotlight + Dock + dock-jump will pick"
        echo "   one unpredictably otherwise."
    fi
    # Silent on the happy path: single install + Homebrew detected.
  '';

  # ============================================================================
  # NIX-103: Login-shell parity check (companion to NIX-105 safe-switch)
  # ============================================================================
  #
  # WHY: HM's `programs.<shell>.enable = true` installs + configures the shell,
  # but DOES NOT change the macOS DirectoryService UserShell record. Drift is
  # silent — your fish config is loaded, but `chsh` still says zsh, so terminal
  # apps that respect login shell (Ghostty, Terminal.app) launch zsh first
  # (which then exec's fish via .zshrc trampoline IF configured, else stays zsh).
  # Surfaced 2026-05-05 on M5 (programs.fish.enable=true but login shell still
  # /bin/zsh until manual `sudo chsh` ran).
  #
  # WHAT IT CHECKS (advisory — never auto-mutates):
  #   1. macOS DirectoryService UserShell matches the expected path
  #   2. The expected path is in /etc/shells (otherwise chsh refuses)
  # If either fails, prints exact fix commands. Silent on the happy path.
  #
  # WHY ADVISORY-ONLY: chsh requires interactive auth (Touch ID or password);
  # /etc/shells append requires sudo. Auto-mutating either from an activation
  # script would either fail silently or hang waiting for input. Better to
  # surface the gap + let the user run two commands once.
  #
  # WIRE-UP at consumer (per-host home.nix):
  #   home.activation.checkLoginShell = macosCommon.loginShellCheckActivation
  #     "${config.home.homeDirectory}/.nix-profile/bin/fish";
  #
  # The expected-path STRING is what you'd `chsh -s <path>` to. Stable form
  # is the user-profile symlink (`~/.nix-profile/bin/<shell>`), NOT the
  # Nix-store path (rotates with each generation).
  loginShellCheckActivation =
    expectedShellPath:
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      expected="${expectedShellPath}"
      # Note: HM activation PATH doesn't include awk; use bash parameter
      # expansion to extract the value after "UserShell: " from dscl output.
      raw=$(/usr/bin/dscl . -read /Users/$USER UserShell 2>/dev/null)
      actual="''${raw##* }"  # strip everything up to and including last space

      shell_mismatch=0
      etc_shells_missing=0

      if [ "$actual" != "$expected" ]; then
          shell_mismatch=1
      fi

      if ! grep -qFx "$expected" /etc/shells 2>/dev/null; then
          etc_shells_missing=1
      fi

      if [ "$shell_mismatch" = "0" ] && [ "$etc_shells_missing" = "0" ]; then
          # Happy path: silent.
          true
      else
          echo ""
          echo "⚠️  Login shell parity check (NIX-103):"
          if [ "$etc_shells_missing" = "1" ]; then
              echo "   • $expected is NOT in /etc/shells (chsh will refuse)."
              echo "     Fix: echo \"$expected\" | sudo tee -a /etc/shells"
          fi
          if [ "$shell_mismatch" = "1" ]; then
              echo "   • DirectoryService UserShell mismatch:"
              echo "       expected (HM-configured): $expected"
              echo "       actual (macOS):           $actual"
              echo "     Fix: sudo chsh -s \"$expected\" $USER"
              echo "     (Then open a NEW terminal session for the change to take effect."
              echo "      Existing sessions stay on the old shell.)"
          fi
          echo ""
          echo "   Both fixes are one-time; this check stays silent once aligned."
          echo "   See NIX-103 for the rationale (HM doesn't touch chsh by design)."
      fi
    '';

  # ============================================================================
  # Brewfile generation (NIX-107 Path A — declarative cask manifest)
  # ============================================================================
  #
  # WHY: Today (2026-05-10) brew installs are imperative + per-host. New macOS
  # host onboarding requires N manual `brew install --cask ...` steps. Drift
  # detection is per-app activation scripts (like ghosttyCheckActivation above)
  # — doesn't scale. Path A: generate a Brewfile from declarations here, run
  # `just bundle` to install.
  #
  # WHY NOT Path B (nix-darwin homebrew module): nix-darwin has unresolved
  # foundational issues on macOS Tahoe 26.x (e.g. nix-darwin#1544
  # `darwin-rebuild: command not found` post-install, #1627 Mac App Store via
  # flakes broken). Cask inventory built here is reusable 1:1 for B when
  # Tahoe-stability lands.
  #
  # SCOPE v1: casks only (the GUI-app double-install risk surfaced 2026-05-10).
  # Formulae + taps are smaller risk surface (Nix commonPackages already covers
  # most CLI tools). Could extend mkBrewfile to handle them in v2.
  #
  # COMMON BASELINE = strict. Only `ghostty` for now — INSPR-required because
  # we Nix-manage its config + the activation check expects the .app to exist.
  # `commonCasks`/`commonTaps` live in the outer `let` block above (so
  # `mkBrewfile` can reference them); not exported in the returned attrset.
  # Each macOS host adds its per-host extras via the consumer wire-up:
  #
  #   home.file.".config/homebrew/Brewfile".text = macosCommon.mkBrewfile {
  #     extraCasks = [ "raycast" "zed" "..." ];  # this host's GUI apps
  #     extraTaps  = [ ];                         # custom taps (rare)
  #     extraBrews = [ ];                         # CLI tools NOT covered by Nix
  #   };
  #
  # APPLY: `just bundle` (additive — installs missing, NEVER removes). For
  # full declarative cleanup (`brew bundle cleanup` to remove non-listed casks),
  # use `just bundle-cleanup` — destructive, requires explicit invocation.
  # PREVIEW: `just bundle-check` — diff Brewfile vs installed, no side effects.

  # mkBrewfile : { extraCasks ? [], extraTaps ? [], extraBrews ? [] } -> string
  # Renders a Brewfile combining commonCasks/Taps with the host's extras.
  # Brewfile syntax docs: https://github.com/Homebrew/homebrew-bundle
  mkBrewfile =
    {
      extraCasks ? [ ],
      extraTaps ? [ ],
      extraBrews ? [ ],
    }:
    let
      allTaps = commonTaps ++ extraTaps;
      allCasks = commonCasks ++ extraCasks;
      tapLines = builtins.concatStringsSep "\n" (map (t: ''tap "${t}"'') allTaps);
      brewLines = builtins.concatStringsSep "\n" (map (b: ''brew "${b}"'') extraBrews);
      caskLines = builtins.concatStringsSep "\n" (map (c: ''cask "${c}"'') allCasks);
    in
    ''
      # ─────────────────────────────────────────────────────────────────────
      # INSPR-managed Brewfile (NIX-107 Path A)
      # SOURCE OF TRUTH: nixcfg/modules/uzumaki/macos-common.nix → mkBrewfile
      #   - commonCasks: strict INSPR baseline
      #   - extraCasks/Taps/Brews: per-host (declared in this host's home.nix)
      # APPLY: `just bundle` (additive only — installs missing, never removes)
      # CLEANUP (destructive): `just bundle-cleanup` (uninstalls non-listed casks)
      # Edit lists + `just safe-switch` to re-render this file, then `just bundle`.
      # ─────────────────────────────────────────────────────────────────────

      ${if allTaps == [ ] then "# (no taps)" else "# Taps\n${tapLines}"}

      ${
        if extraBrews == [ ] then
          "# (no brew formulae — Nix commonPackages covers most CLI tools)"
        else
          "# Brew formulae (top-level)\n${brewLines}"
      }

      # Casks (GUI apps managed via Homebrew; configs Nix-managed where applicable)
      ${caskLines}
    '';

  # ============================================================================
  # Common macOS Packages
  # ============================================================================
  commonPackages = with pkgs; [
    # Interpreters (global baseline - always available)
    nodejs # Latest Node.js - for IDEs, scripts, terminal
    bun # JS runtime + package manager (provides bun, bunx)
    python3 # Latest Python 3 - for IDEs, scripts, terminal

    # CLI Development Tools
    cloc # Count lines of code
    devenv # Development environments CLI (for .envrc)
    gh # GitHub CLI
    jq # JSON processor
    just # Command runner
    lazygit # Git TUI

    # File Management & Utilities
    tree # Directory tree viewer
    pv # Pipe viewer (progress for pipes)
    tealdeer # tldr - simplified man pages
    fswatch # File system watcher
    mc # midnight-commander - file manager
    procps # Linux utilities (watch, ps, etc.)

    # Terminal Multiplexer
    zellij # Modern terminal multiplexer

    # Networking Tools
    netcat # Network utility
    wakeonlan # Wake-on-LAN utility
    websocat # WebSocket client

    # Text Processing
    lynx # Text-based web browser
    html2text # HTML to text converter

    # Backup & Archive
    restic # Backup program
    rage # Age encryption (Rust implementation)

    # macOS Built-in Overrides
    rsync # Modern rsync (macOS has 2006 version!)
    wget # File downloader (not in macOS)

    # CLI tools
    zoxide # Smart directory jumper
    bat # Better cat with syntax highlighting
    btop # Better top/htop
    ripgrep # Fast grep (rg)
    fd # Fast find
    fzf # Fuzzy finder
    eza # Modern ls replacement (used by ll alias)
    prettier # Code formatter
    nano # Modern nano with syntax highlighting

    # Utilities
    nmap # Network scanner

    # AI Coding Agents now installed via ai-clis-npm.nix (always-latest)

    # Fonts
    (pkgs.nerd-fonts.hack)
  ];

  # ============================================================================
  # Nano Configuration
  # ============================================================================
  nanoConfig = pkgs: ''
    # Modern nano configuration with syntax highlighting

    # Enable syntax highlighting from Nix package
    include ${pkgs.nano}/share/nano/*.nanorc

    # Auto-indent
    set autoindent

    # Convert tabs to spaces
    set tabstospaces
    set tabsize 2

    # Line numbers
    set linenumbers

    # Use mouse
    set mouse

    # Better search
    set casesensitive
    set regexp

    # Backup files
    set backup
    set backupdir "~/.nano/backups"

    # Show cursor position
    set constantshow

    # Auto-detect file type
    set matchbrackets "(<[{)>]}"
  '';

  # ============================================================================
  # Font Installation Activation Script
  # ============================================================================
  fontActivation =
    pkgs:
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      echo "Installing Hack Nerd Font for macOS..."
      mkdir -p "$HOME/Library/Fonts"

      # Find all Hack Nerd Font files in the Nix store
      FONT_PATH="${pkgs.nerd-fonts.hack}/share/fonts/truetype/NerdFonts/Hack"

      if [ -d "$FONT_PATH" ]; then
        # COPY font files to ~/Library/Fonts/ (not symlink - macOS needs real files)
        for font in "$FONT_PATH"/*.ttf; do
          if [ -f "$font" ]; then
            font_name=$(basename "$font")
            target="$HOME/Library/Fonts/$font_name"

            # Remove old file/symlink if it exists
            if [ -e "$target" ] || [ -L "$target" ]; then
              rm -f "$target"
            fi

            # Copy the font file (macOS Font Book doesn't always follow symlinks)
            cp "$font" "$target"
            echo "  Copied: $font_name"
          fi
        done
        
        # Clear font cache
        if command -v atsutil >/dev/null 2>&1; then
          atsutil databases -remove >/dev/null 2>&1 || true
        fi
        
        echo "✅ Hack Nerd Font installed for macOS"
        echo "   ⚠️  You may need to restart apps or log out/in for fonts to appear"
      else
        echo "⚠️  Font path not found: $FONT_PATH"
      fi
    '';

  # ============================================================================
  # macOS App Linking Activation Script
  # ============================================================================
  # Creates macOS aliases (not symlinks!) so Spotlight can index them.
  # Symlinks to /nix/store don't get indexed by Spotlight.
  appLinkActivation = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    echo "Linking macOS GUI applications..."

    # Ensure main Applications directory exists
    mkdir -p "$HOME/Applications"

    # Apps to link to main Applications folder (from Home Manager Apps).
    # Empty since WezTerm purge 2026-05-05 — Ghostty is installed outside Nix
    # (Homebrew). Add new HM-installed GUI apps here as they're enabled.
    apps=()

    for app in "''${apps[@]}"; do
      source="$HOME/Applications/Home Manager Apps/$app"
      target="$HOME/Applications/$app"

      if [ -e "$source" ]; then
        # Cleanup potential duplicates from buggy Finder script
        rm -rf "$target" alias* 2>/dev/null || true
        find "$HOME/Applications" -name "$app alias*" -delete 2>/dev/null || true

        # Remove old symlink, alias, or Homebrew version
        if [ -L "$target" ] || [ -e "$target" ]; then
          echo "  Removing old $app..."
          rm -rf "$target"
        fi

        # Create macOS alias (not symlink!) - Spotlight indexes aliases properly
        echo "  Creating alias for $app"
        /usr/bin/osascript -e "tell application \"Finder\" to make alias file to POSIX file \"$source\" at POSIX file \"$HOME/Applications\" with properties {name:\"$app\"}" >/dev/null 2>&1
      fi
    done

    # One-shot cleanup: drop the lingering WezTerm.app alias from the
    # pre-2026-05-05 era (the activation no longer creates it; this removes
    # the old one if still present). Safe to run repeatedly — no-op when
    # the alias is already gone. Drop this block in a few weeks once all
    # macOS hosts have activated at least once after 2026-05-05.
    if [ -e "$HOME/Applications/WezTerm.app" ] || [ -L "$HOME/Applications/WezTerm.app" ]; then
      echo "  Removing lingering WezTerm.app alias (post-2026-05-05 cleanup)..."
      rm -rf "$HOME/Applications/WezTerm.app"
    fi

    echo "✅ macOS GUI applications aliased"
  '';
}
