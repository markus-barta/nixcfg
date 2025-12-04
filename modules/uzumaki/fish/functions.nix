# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                   Fish Shell Functions                                       ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Shared fish function definitions used by the uzumaki module.
# These work on both NixOS and macOS (Home Manager).
#
# Format: Each function is an attribute set with:
#   - description: String shown in `functions -D <name>`
#   - body: The function implementation
#
# Used by:
#   - modules/uzumaki/default.nix (imports and applies based on platform)
#
# Note: This file was consolidated from modules/uzumaki/common.nix as part
# of the uzumaki module restructure (Phase 3).
#
{
  # ════════════════════════════════════════════════════════════════════════════
  # PINGT - Timestamped ping with color-coded output
  # ════════════════════════════════════════════════════════════════════════════
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

  # ════════════════════════════════════════════════════════════════════════════
  # SOURCEFISH - Load env vars from .env file
  # ════════════════════════════════════════════════════════════════════════════
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

  # ════════════════════════════════════════════════════════════════════════════
  # STRESS - CPU stress test
  # ════════════════════════════════════════════════════════════════════════════
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

  # ════════════════════════════════════════════════════════════════════════════
  # STASYSMOD - Toggle StaSysMo debug mode
  # ════════════════════════════════════════════════════════════════════════════
  stasysmod = {
    description = "Toggle StaSysMo debug mode (system metrics verbose output)";
    body = ''
      if set -q STASYSMO_DEBUG
        set -e STASYSMO_DEBUG
        echo "StaSysMo debug mode: OFF"
      else
        set -gx STASYSMO_DEBUG 1
        echo "StaSysMo debug mode: ON"
        echo ""
        # Show current debug state immediately
        if command -v stasysmo-reader &>/dev/null
          stasysmo-reader
        else
          echo "(stasysmo-reader not in PATH)"
        end
      end
    '';
  };

  # ════════════════════════════════════════════════════════════════════════════
  # HELPFISH - Show custom functions & abbreviations
  # ════════════════════════════════════════════════════════════════════════════
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

      # ── Custom Functions (🌀 Uzumaki) ──
      echo -e "$color_func┌── 🌀 Functions ─────────────────────────────────────────────────┐$color_reset"
      printf "  $color_func%-14s$color_reset  %s\n" "pingt" "Timestamped ping with color-coded output (yellow=timeout, red=error)"
      printf "  $color_func%-14s$color_reset  %s\n" "sourcefish" "Load .env file into current Fish session (parses KEY=value)"
      printf "  $color_func%-14s$color_reset  %s\n" "stress" "CPU stress test on all cores (stress [seconds] or Ctrl+C)"
      printf "  $color_func%-14s$color_reset  %s\n" "stasysmod" "Toggle StaSysMo debug mode (verbose metrics diagnostics)"
      printf "  $color_func%-14s$color_reset  %s\n" "helpfish" "Show this help (custom functions, aliases, abbreviations)"
      echo -e "$color_func└────────────────────────────────────────────────────────────────┘$color_reset\n"

      # ── Aliases ──
      echo -e "$color_alias┌── Aliases ─────────────────────────────────────────────────────┐$color_reset"
      printf "  $color_alias%-12s$color_reset →  %-22s $color_dim# %s$color_reset\n" "gitc" "git commit" "Commit changes"
      printf "  $color_alias%-12s$color_reset →  %-22s $color_dim# %s$color_reset\n" "gitps" "git push" "Push to remote"
      printf "  $color_alias%-12s$color_reset →  %-22s $color_dim# %s$color_reset\n" "gitpl" "git pull + submodule" "Pull with submodules"
      printf "  $color_alias%-12s$color_reset →  %-22s $color_dim# %s$color_reset\n" "gitplr" "git pull --rec" "Pull recursive"
      printf "  $color_alias%-12s$color_reset →  %-22s $color_dim# %s$color_reset\n" "gitsub" "git submodule update" "Update submodules"
      printf "  $color_alias%-12s$color_reset →  %-22s $color_dim# %s$color_reset\n" "gitpls" "git pull" "Pull only"
      printf "  $color_alias%-12s$color_reset →  %-22s $color_dim# %s$color_reset\n" "gita" "git add -A" "Stage all changes"
      printf "  $color_alias%-12s$color_reset →  %-22s $color_dim# %s$color_reset\n" "gitst" "git status" "Show status"
      printf "  $color_alias%-12s$color_reset →  %-22s $color_dim# %s$color_reset\n" "gitd" "git diff" "Show diff"
      printf "  $color_alias%-12s$color_reset →  %-22s $color_dim# %s$color_reset\n" "gitds" "git diff --staged" "Show staged diff"
      printf "  $color_alias%-12s$color_reset →  %-22s $color_dim# %s$color_reset\n" "gitl" "git log" "Show log"
      printf "  $color_alias%-12s$color_reset →  %-22s $color_dim# %s$color_reset\n" "ll" "eza -hal --icons" "List files detailed"
      printf "  $color_alias%-12s$color_reset →  %-22s $color_dim# %s$color_reset\n" "lg" "lazygit" "Git TUI"
      printf "  $color_alias%-12s$color_reset →  %-22s $color_dim# %s$color_reset\n" "j" "just" "Command runner"
      printf "  $color_alias%-12s$color_reset →  %-22s $color_dim# %s$color_reset\n" "duai" "dua interactive" "Disk usage TUI"
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
