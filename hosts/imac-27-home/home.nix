{ pkgs, ... }:

{
  # Home Manager needs a bit of information about you and the paths it should manage
  home.username = "markus";
  home.homeDirectory = "/Users/markus";

  # This value determines the Home Manager release that your configuration is
  # compatible with. This helps avoid breakage when a new Home Manager release
  # introduces backwards incompatible changes.
  home.stateVersion = "24.11";

  # Let Home Manager install and manage itself
  programs.home-manager.enable = true;

  # ============================================================================
  # Fish Shell Configuration
  # ============================================================================
  programs.fish = {
    enable = true;

    # Shell initialization (config.fish equivalent)
    shellInit = ''
      # Environment variables
      set -gx TERM xterm-256color

      # zoxide integration
      set -gx ZOXIDE_CMD z
    '';

    # Login shell initialization - prepend Nix paths to PATH
    loginShellInit = ''
      # Ensure Nix paths are prioritized
      fish_add_path --prepend --move ~/.nix-profile/bin
      fish_add_path --prepend --move /nix/var/nix/profiles/default/bin
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

    # Functions
    functions = {
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

      # sourceenv - load env vars from file
      sourceenv = ''
        sed -e 's/^/set -gx /' -e 's/=/\ /' $argv | source
      '';

      # sourcefish - load env vars from .env file
      sourcefish = {
        description = "Load env vars from a .env file into current Fish session";
        body = ''
          set file "$argv[1]"
          if test -z "$file"
              echo "Usage: sourcefish PATH_TO_ENV_FILE"
              return 1
          end
          if test -f "$file"
              for line in (cat "$file" | grep -v '^[[:space:]]*#' | grep .)
                  set key (echo $line | cut -d= -f1)
                  set val (echo $line | cut -d= -f2-)
                  set -gx $key "$val"
              end
          else
              echo "File not found: $file"
              return 1
          end
        '';
      };

      # pingt wrapper
      pingt = {
        description = "Timestamped ping (calls ~/Scripts/pingt.sh)";
        body = ''
          /Users/markus/Scripts/pingt.sh $argv
        '';
      };
    };

    # Aliases
    shellAliases = {
      mc = "env LANG=en_US.UTF-8 mc";
      lg = "lazygit";
    };

    # Abbreviations
    shellAbbrs = {
      flushdns = "sudo killall -HUP mDNSResponder && echo macOS DNS Cache Reset";
      qc99 = "ssh mba@miniserver99 -t \"zellij attach ms99 -c\"";
      qc24 = "ssh mba@miniserver24 -t \"zellij attach ms24 -c\"";
      qc0 = "ssh mba@cs0.barta.cm -p 2222 -t \"zellij attach csb0 -c\"";
      qc1 = "ssh mba@cs1.barta.cm -p 2222 -t \"zellij attach csb1 -c\"";
    };
  };

  # ============================================================================
  # Starship Prompt Configuration
  # ============================================================================
  programs.starship = {
    enable = true;
    enableFishIntegration = true;
    # Settings disabled - using home.file to preserve Unicode
    /*
      settings = {
        # Global settings
        command_timeout = 2000;

        # Prompt layout
        format = "$username$hostname $directory$git_branch$git_commit$git_status\${custom.gitcount} $python$nodejs$rust$golang $docker_context $kubernetes\n$character";
        right_format = "$time";

        # Prompt character
        character = {
          success_symbol = "[➜](bold cyan) ";
          error_symbol = "[✗](bold red) ";
        };

        # User + Host
        username = {
          style_user = "bold green";
          show_always = true;
          format = "[$user]($style)";
        };

        hostname = {
          ssh_only = false;
          style = "bold yellow";
          format = "@[$hostname]($style)";
        };

        # Directory
        directory = {
          style = "bold blue";
          truncation_length = 0; # full path always
          truncate_to_repo = false; # don't cut at repo root
          format = "[$path]($style) ";
        };

        # Git
        git_branch = {
          symbol = " ";
          style = "bold purple";
        };

        git_commit = {
          commit_hash_length = 7;
          style = "bold white";
          only_detached = false;
          tag_disabled = true;
          format = "[($hash)]($style)";
        };

        git_status = {
          style = "bold red";
          conflicted = "⚡";
          ahead = "⇡";
          behind = "⇣";
          diverged = "⇕";
          untracked = "?";
          stashed = "📦";
          modified = "!";
          staged = "+";
          renamed = "»";
          deleted = "✘";
        };

        # Custom gitcount module (commit count)
        custom.gitcount = {
          command = "git rev-list --count HEAD";
          when = "git rev-parse --is-inside-work-tree >/dev/null 2>&1";
          format = "[#$output](dimmed green)";
        };

        # Languages
        nodejs = {
          symbol = " ";
          style = "green";
          detect_files = [ "package.json" ];
        };

        python = {
          symbol = "🐍 ";
          style = "yellow";
        };

        rust = {
          symbol = "🦀 ";
          style = "red";
        };

        golang = {
          symbol = " ";
          style = "cyan";
        };

        # Docker
        docker_context = {
          symbol = "🐳 ";
          style = "blue";
          only_with_files = true;
        };

        # Kubernetes
        kubernetes = {
          symbol = "⎈ ";
          style = "cyan bold";
          disabled = false;
        };

        # Time (right prompt)
        time = {
          disabled = false;
          format = "[$time]($style)";
          time_format = "%H:%M";
          style = "bold white";
        };
      };
    */
  };

  # ============================================================================
  # WezTerm Terminal Configuration
  # ============================================================================
  programs.wezterm = {
    enable = true;
    extraConfig = ''
      local wezterm = require("wezterm")
      local act = wezterm.action
      local config = wezterm.config_builder()

      ------------------------------------------------------------
      -- ## Fonts & Text
      ------------------------------------------------------------
      config.font_size = 12
      config.line_height = 1.1
      config.font = wezterm.font("Hack Nerd Font Mono")

      ------------------------------------------------------------
      -- ## Colors & Cursor
      ------------------------------------------------------------
      config.color_scheme = "tokyonight_night"
      config.colors = {
          cursor_bg = "#7aa2f7",
          cursor_border = "#7aa2f7",
          cursor_fg = "black",
      }
      config.default_cursor_style = "BlinkingBar"

      ------------------------------------------------------------
      -- ## Window Look & Feel
      ------------------------------------------------------------
      config.window_decorations = "RESIZE|INTEGRATED_BUTTONS"
      config.hide_tab_bar_if_only_one_tab = false
      config.native_macos_fullscreen_mode = true

      config.window_background_opacity = 0.9
      config.macos_window_background_blur = 10
      config.window_padding = { left = 8, right = 8, top = 8, bottom = 8 }

      -- Double terminal grid size
      config.initial_cols = 160
      config.initial_rows = 48

      ------------------------------------------------------------
      -- ## Behavior
      ------------------------------------------------------------
      config.adjust_window_size_when_changing_font_size = false
      config.audible_bell = "Disabled"

      -- macOS Alt keys
      config.send_composed_key_when_left_alt_is_pressed = true
      config.send_composed_key_when_right_alt_is_pressed = true

      ------------------------------------------------------------
      -- ## Keys
      ------------------------------------------------------------
      config.keys = {
          { key = "c",   mods = "CMD",       action = act.CopyTo("Clipboard") },
          { key = "v",   mods = "CMD",       action = act.PasteFrom("Clipboard") },

          { key = "-",   mods = "CMD",       action = act.DecreaseFontSize },
          { key = "0",   mods = "CMD",       action = act.ResetFontSize },
          { key = "=",   mods = "CMD",       action = act.IncreaseFontSize },
          { key = "=",   mods = "CMD|SHIFT", action = act.IncreaseFontSize },

          -- Fullscreen
          { key = "f",   mods = "CMD|CTRL",  action = act.ToggleFullScreen },
          { key = "F11", mods = "",          action = act.ToggleFullScreen },

          -- Tabs & windows
          { key = "t",   mods = "CMD",       action = act.SpawnTab("CurrentPaneDomain") },
          { key = "w",   mods = "CMD",       action = act.CloseCurrentPane({ confirm = true }) },
          { key = "n",   mods = "CMD",       action = act.SpawnWindow },
      }

      ------------------------------------------------------------
      -- ## Mouse
      ------------------------------------------------------------
      config.mouse_bindings = {
          {
              event = { Down = { streak = 1, button = { WheelUp = 1 } } },
              mods = "CMD",
              action = act.IncreaseFontSize,
          },
          {
              event = { Down = { streak = 1, button = { WheelDown = 1 } } },
              mods = "CMD",
              action = act.DecreaseFontSize,
          },
      }

      return config
    '';
  };

  # ============================================================================
  # Git Configuration with Dual Identity
  # ============================================================================
  programs.git = {
    enable = true;

    # Global gitignore
    ignores = [
      "*~"
      ".DS_Store"
    ];

    settings = {
      # User settings
      user = {
        name = "Markus Barta";
        email = "markus@barta.com"; # Personal (default)
      };

      # macOS keychain credential helper
      credential.helper = "osxkeychain";

      # Sourcetree diff/merge tools (preserved from existing config)
      difftool.sourcetree = {
        cmd = ''opendiff "$LOCAL" "$REMOTE"'';
        path = "";
      };
      mergetool.sourcetree = {
        cmd = ''/Applications/Sourcetree.app/Contents/Resources/opendiff-w.sh "$LOCAL" "$REMOTE" -ancestor "$BASE" -merge "$MERGED"'';
        trustExitCode = true;
      };

      # Commit template (preserved from existing config)
      commit.template = "/Users/markus/.stCommitMsg";
    };

    # Dual identity: automatic work identity for BYTEPOETS projects
    includes = [
      {
        condition = "gitdir:~/Code/BYTEPOETS/";
        contents = {
          user = {
            name = "mba";
            email = "markus.barta@bytepoets.com";
          };
        };
      }
    ];
  };

  # ============================================================================
  # Zsh Configuration (System Shell)
  # ============================================================================
  programs.zsh = {
    enable = true;

    # Prepend Nix paths to PATH (same as Fish loginShellInit)
    initExtra = ''
      # Ensure Nix paths are prioritized
      export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
    '';
  };

  # ============================================================================
  # Direnv Configuration
  # ============================================================================
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true; # Better Nix integration
    # Fish integration is automatic
    # Zsh integration is automatic
  };

  # ============================================================================
  # Global Packages
  # ============================================================================
  home.packages = with pkgs; [
    # Interpreters (global baseline - always available)
    nodejs # Latest Node.js - for IDEs, scripts, terminal
    python3 # Latest Python 3 - for IDEs, scripts, terminal

    # CLI tools (moved from Homebrew - these are in devenv, but keeping here for global access)
    zoxide # Smart directory jumper

    # Fonts
    (pkgs.nerd-fonts.hack)
  ];

  # Enable fontconfig for fonts to be recognized
  fonts.fontconfig.enable = true;

  # ============================================================================
  # Starship Config File (preserves Nerd Font Unicode)
  # ============================================================================
  home.file.".config/starship.toml" = {
    source = ./config/starship.toml;
  };

  # ============================================================================
  # Scripts Management
  # ============================================================================
  home.file."Scripts" = {
    source = ./scripts;
    recursive = true; # Links all files in directory
    # Preserves executable permissions from git
  };

  # ============================================================================
  # Additional Settings
  # ============================================================================

  # XDG directories (macOS doesn't use XDG but home-manager expects it)
  xdg.enable = true;

  # Session variables
  home.sessionVariables = {
    # Additional environment variables can go here
  };
}
