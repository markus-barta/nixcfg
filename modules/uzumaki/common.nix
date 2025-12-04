# Uzumaki Common - Shared Fish function definitions
# These are exported as raw strings for use by both:
#   - uzumaki/server.nix (NixOS - uses interactiveShellInit)
#   - uzumaki/macos.nix (Home Manager - uses programs.fish.functions)
#
{
  # ============================================================================
  # FISH FUNCTION: pingt
  # ============================================================================
  # Timestamped ping with color-coded output for timeouts and errors
  pingt = {
    description = "Timestamped ping with color-coded output";
    body = ''
      # Colors (256-color mode)
      set -l color_gray (set_color brblack)
      set -l color_yellow (set_color yellow)
      set -l color_red (set_color red)
      set -l color_reset (set_color normal)
      set -l separator '·'

      # Run ping and process each line
      command ping $argv 2>&1 | while read -l line
        set -l timestamp (date '+%H:%M:%S')

        # Color-code based on content
        if string match -q '*timeout*' -- $line; or string match -q '*Request timeout*' -- $line
          # Timeout messages in yellow
          printf '%s%s %s%s %s%s%s\n' $color_gray $timestamp $separator $color_reset $color_yellow $line $color_reset
        else if string match -q '*sendto:*' -- $line; or string match -q '*No route to host*' -- $line; or string match -q '*Host is down*' -- $line; or string match -q '*Destination Host Unreachable*' -- $line
          # Error messages in red
          printf '%s%s %s%s %s%s%s\n' $color_gray $timestamp $separator $color_reset $color_red $line $color_reset
        else
          # Normal output
          printf '%s%s %s%s %s\n' $color_gray $timestamp $separator $color_reset $line
        end
      end
    '';
  };

  # ============================================================================
  # FISH FUNCTION: sourcefish
  # ============================================================================
  # Load environment variables from a .env file into current Fish session
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

  # ============================================================================
  # FISH FUNCTION: sourceenv
  # ============================================================================
  # Quick env loader (simpler version of sourcefish)
  sourceenv = {
    description = "Quick load env vars from file (simple format)";
    body = ''
      sed -e 's/^/set -gx /' -e 's/=/\ /' $argv | source
    '';
  };

  # ============================================================================
  # FISH FUNCTION: stress
  # ============================================================================
  # CPU stress test using stress-ng with all cores at 100% load
  # Usage: stress [seconds]
  #   stress 15  - Run for 15 seconds
  #   stress     - Run until Ctrl+C
  stress = {
    description = "CPU stress test (all cores at 100%)";
    body = ''
      set -l cores (nproc --all 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
      if test (count $argv) -gt 0
        echo "Starting CPU stress test on $cores cores for $argv[1] seconds..."
        stress-ng --cpu $cores --cpu-load 100 --cpu-method matrixprod --timeout "$argv[1]s"
      else
        echo "Starting CPU stress test on $cores cores (Ctrl+C to stop)..."
        stress-ng --cpu $cores --cpu-load 100 --cpu-method matrixprod
      end
    '';
  };

  # ============================================================================
  # FISH FUNCTION: helpfish
  # ============================================================================
  # Display all custom functions and abbreviations with descriptions
  helpfish = {
    description = "Show custom functions & abbreviations with descriptions";
    body = ''
      set -l color_heading (set_color -o bryellow)
      set -l color_func (set_color brgreen)
      set -l color_abbr (set_color brcyan)
      set -l color_alias (set_color brmagenta)
      set -l color_dim (set_color brblack)
      set -l color_reset (set_color normal)

      echo -e "\n$color_heading╔════════════════════════════════════════════════════════════════╗"
      echo -e "║          Custom Fish Functions & Abbreviations                 ║"
      echo -e "╚════════════════════════════════════════════════════════════════╝$color_reset\n"

      # ── Custom Functions ──
      echo -e "$color_func┌── Functions ──────────────────────────────────────────────────┐$color_reset"
      # Filter to show only our custom functions (not builtins or fish_*)
      for func in pingt sourcefish sourceenv stress helpfish
        if functions -q $func
          set -l desc (functions -D $func 2>/dev/null)
          if test -z "$desc" -o "$desc" = "-"
            set desc "(no description)"
          end
          printf "  $color_func%-18s$color_reset %s\n" $func "$desc"
        end
      end
      echo -e "$color_func└────────────────────────────────────────────────────────────────┘$color_reset\n"

      # ── Aliases ──
      echo -e "$color_alias┌── Aliases ─────────────────────────────────────────────────────┐$color_reset"
      printf "  $color_alias%-12s$color_reset →  %s  $color_dim# %s$color_reset\n" "gitc" "git commit" "Commit changes"
      printf "  $color_alias%-12s$color_reset →  %s  $color_dim# %s$color_reset\n" "gitps" "git push" "Push to remote"
      printf "  $color_alias%-12s$color_reset →  %s  $color_dim# %s$color_reset\n" "gitpl" "git pull + submodule" "Pull with submodules"
      printf "  $color_alias%-12s$color_reset →  %s  $color_dim# %s$color_reset\n" "gitplr" "git pull --rec" "Pull recursive"
      printf "  $color_alias%-12s$color_reset →  %s  $color_dim# %s$color_reset\n" "gitsub" "git submodule update" "Update submodules"
      printf "  $color_alias%-12s$color_reset →  %s  $color_dim# %s$color_reset\n" "gitpls" "git pull" "Pull only"
      printf "  $color_alias%-12s$color_reset →  %s  $color_dim# %s$color_reset\n" "gita" "git add -A" "Stage all changes"
      printf "  $color_alias%-12s$color_reset →  %s  $color_dim# %s$color_reset\n" "gitst" "git status" "Show status"
      printf "  $color_alias%-12s$color_reset →  %s  $color_dim# %s$color_reset\n" "gitd" "git diff" "Show diff"
      printf "  $color_alias%-12s$color_reset →  %s  $color_dim# %s$color_reset\n" "gitds" "git diff --staged" "Show staged diff"
      printf "  $color_alias%-12s$color_reset →  %s  $color_dim# %s$color_reset\n" "gitl" "git log" "Show log"
      printf "  $color_alias%-12s$color_reset →  %s  $color_dim# %s$color_reset\n" "ll" "eza -hal --icons" "List files detailed"
      printf "  $color_alias%-12s$color_reset →  %s  $color_dim# %s$color_reset\n" "lg" "lazygit" "Git TUI"
      printf "  $color_alias%-12s$color_reset →  %s  $color_dim# %s$color_reset\n" "j" "just" "Command runner"
      printf "  $color_alias%-12s$color_reset →  %s  $color_dim# %s$color_reset\n" "duai" "dua interactive" "Disk usage TUI"
      echo -e "$color_alias└────────────────────────────────────────────────────────────────┘$color_reset\n"

      # ── Abbreviations (modern CLI replacements) ──
      echo -e "$color_abbr┌── Abbreviations (type & press Space to expand) ───────────────┐$color_reset"
      printf "  $color_abbr%-12s$color_reset →  %-15s  $color_dim# %s$color_reset\n" "cl" "clear" "Clear screen"
      printf "  $color_abbr%-12s$color_reset →  %-15s  $color_dim# %s$color_reset\n" "less" "bat" "Better pager with syntax"
      printf "  $color_abbr%-12s$color_reset →  %-15s  $color_dim# %s$color_reset\n" "man" "batman" "Man pages with bat"
      printf "  $color_abbr%-12s$color_reset →  %-15s  $color_dim# %s$color_reset\n" "du" "dua" "Modern disk usage"
      printf "  $color_abbr%-12s$color_reset →  %-15s  $color_dim# %s$color_reset\n" "ncdu" "dua interactive" "Disk usage TUI"
      printf "  $color_abbr%-12s$color_reset →  %-15s  $color_dim# %s$color_reset\n" "df" "duf" "Modern df"
      printf "  $color_abbr%-12s$color_reset →  %-15s  $color_dim# %s$color_reset\n" "tree" "erd" "Modern tree"
      printf "  $color_abbr%-12s$color_reset →  %-15s  $color_dim# %s$color_reset\n" "tmux" "zellij" "Modern multiplexer"
      printf "  $color_abbr%-12s$color_reset →  %-15s  $color_dim# %s$color_reset\n" "dig" "dog" "Modern DNS lookup"
      printf "  $color_abbr%-12s$color_reset →  %-15s  $color_dim# %s$color_reset\n" "diff" "difft" "Structural diff"
      printf "  $color_abbr%-12s$color_reset →  %-15s  $color_dim# %s$color_reset\n" "ping" "pingt" "Timestamped ping"
      printf "  $color_abbr%-12s$color_reset →  %-15s  $color_dim# %s$color_reset\n" "tar" "ouch" "Smart archive tool"
      printf "  $color_abbr%-12s$color_reset →  %-15s  $color_dim# %s$color_reset\n" "ps" "procs" "Modern ps"
      printf "  $color_abbr%-12s$color_reset →  %-15s  $color_dim# %s$color_reset\n" "whois" "rdap" "Modern whois"
      printf "  $color_abbr%-12s$color_reset →  %-15s  $color_dim# %s$color_reset\n" "vim" "hx" "Helix editor"
      printf "  $color_abbr%-12s$color_reset →  %-15s  $color_dim# %s$color_reset\n" "killall" "pkill" "Kill by name"
      echo -e "$color_abbr└────────────────────────────────────────────────────────────────┘$color_reset\n"

      # ── SSH shortcuts ──
      echo -e "$color_abbr┌── SSH Shortcuts (with zellij session) ────────────────────────┐$color_reset"
      printf "  $color_abbr%-8s$color_reset →  %s\n" "hsb0" "Home server 0 (192.168.1.99)"
      printf "  $color_abbr%-8s$color_reset →  %s\n" "hsb1" "Home server 1 (192.168.1.101)"
      printf "  $color_abbr%-8s$color_reset →  %s\n" "hsb8" "Home server 8 (192.168.1.100)"
      printf "  $color_abbr%-8s$color_reset →  %s\n" "gpc0" "Gaming PC (192.168.1.154)"
      printf "  $color_abbr%-8s$color_reset →  %s\n" "csb0" "Cloud server 0 (cs0.barta.cm)"
      printf "  $color_abbr%-8s$color_reset →  %s\n" "csb1" "Cloud server 1 (cs1.barta.cm)"
      echo -e "$color_abbr└────────────────────────────────────────────────────────────────┘$color_reset\n"
    '';
  };
}
