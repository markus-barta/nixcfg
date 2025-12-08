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
  # HOSTCOLORS - Show host color palette overview
  # ════════════════════════════════════════════════════════════════════════════
  hostcolors = {
    description = "Show infrastructure hosts with their color-coded themes";
    body = ''
      set -l reset (set_color normal)
      set -l bold (set_color -o)
      set -l dim (set_color brblack)

      # Define colors for each host (matching theme-palettes.nix)
      set -l c_csb0 (set_color "#98b8d8")  # Ice Blue
      set -l c_csb1 (set_color "#769ff0")  # Blue
      set -l c_hsb0 (set_color "#d4c060")  # Yellow
      set -l c_hsb1 (set_color "#68c878")  # Green
      set -l c_hsb8 (set_color "#e09050")  # Orange
      set -l c_gpc0 (set_color "#9868d0")  # Purple
      set -l c_imac0 (set_color "#a8aeb8") # Light Gray
      set -l c_imacw (set_color "#686c70") # Dark Gray
      set -l c_mbpw (set_color "#a8a098")  # Warm Gray

      echo ""
      echo "$bold╔════════════════════════════════════════════════════════════════════════╗$reset"
      echo "$bold║                    Infrastructure Host Colors                          ║$reset"
      echo "$bold╚════════════════════════════════════════════════════════════════════════╝$reset"
      echo ""
      echo "  $dim CLOUD (Internet-facing)           HOME (Local network)$reset"
      echo "  ┌─────────────────────────┐        ┌─────────────────────────┐"
      printf "  │  $c_csb0●$reset csb0    $c_csb0Ice Blue$reset   │        │  $c_hsb0●$reset hsb0    $c_hsb0Yellow$reset     │\n"
      printf "  │  $c_csb1●$reset csb1    $c_csb1Blue$reset       │        │  $c_hsb1●$reset hsb1    $c_hsb1Green$reset      │\n"
      echo "  └─────────────────────────┘        │  $c_hsb8●$reset hsb8    $c_hsb8Orange$reset     │"
      echo "                                     └─────────────────────────┘"
      echo ""
      echo "  $dim GAMING                            WORKSTATIONS$reset"
      echo "  ┌─────────────────────────┐        ┌─────────────────────────┐"
      printf "  │  $c_gpc0●$reset gpc0    $c_gpc0Purple$reset     │        │  $c_imac0●$reset imac0   $c_imac0Light Gray$reset │\n"
      echo "  └─────────────────────────┘        │  $c_imacw●$reset imac-w  $c_imacw Dark Gray$reset │"
      echo "                                     │  $c_mbpw●$reset mba-mbp $c_mbpw Warm Gray$reset │"
      echo "                                     └─────────────────────────┘"
      echo ""
      echo "  $dim Colors flow through: Starship prompt → Zellij frame → Eza theme$reset"
      echo "  $dim Recognize hosts instantly by their accent color!$reset"
      echo ""
    '';
  };

  # ════════════════════════════════════════════════════════════════════════════
  # HOSTSECRETS - Show runbook secrets status (wrapper for runbook-secrets.sh)
  # ════════════════════════════════════════════════════════════════════════════
  hostsecrets = {
    description = "Show runbook secrets status for all hosts (plain/encrypted)";
    body = ''
      # Find nixcfg directory - check common locations
      set -l nixcfg_dir ""
      for dir in ~/Code/nixcfg ~/nixcfg /etc/nixos
        if test -f "$dir/scripts/runbook-secrets.sh"
          set nixcfg_dir "$dir"
          break
        end
      end

      if test -z "$nixcfg_dir"
        echo "Error: Could not find nixcfg directory with runbook-secrets.sh"
        echo "Checked: ~/Code/nixcfg, ~/nixcfg, /etc/nixos"
        return 1
      end

      # Run the script with list command
      bash "$nixcfg_dir/scripts/runbook-secrets.sh" list
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

      # All boxes are exactly 76 chars wide (74 inside + 2 border)
      echo -e "\n$color_heading╔════════════════════════════════════════════════════════════════════════╗"
      echo -e "║                 Custom Fish Functions & Abbreviations                  ║"
      echo -e "╚════════════════════════════════════════════════════════════════════════╝$color_reset\n"

      # ── Functions ──
      echo -e "$color_func┌─ Functions ────────────────────────────────────────────────────────────┐$color_reset"
      printf " $color_func%-12s$color_reset %-58s\n" "pingt"      "Timestamped ping with color-coded output (yellow/red)"
      printf " $color_func%-12s$color_reset %-58s\n" "sourcefish" "Load .env file into current Fish session (KEY=value)"
      printf " $color_func%-12s$color_reset %-58s\n" "stress"     "CPU stress test on all cores (stress [sec] or Ctrl+C)"
      printf " $color_func%-12s$color_reset %-58s\n" "stasysmod"  "Toggle StaSysMo debug mode (verbose metrics)"
      printf " $color_func%-12s$color_reset %-58s\n" "hostcolors" "Show infrastructure hosts with color-coded themes"
      printf " $color_func%-12s$color_reset %-58s\n" "hostsecrets" "Show runbook secrets status (plain/encrypted)"
      printf " $color_func%-12s$color_reset %-58s\n" "helpfish"   "Show this help (functions, aliases, abbreviations)"
      echo -e "$color_func└────────────────────────────────────────────────────────────────────────┘$color_reset\n"

      # ── Aliases ──
      echo -e "$color_alias┌─ Aliases ─────────────────────────────────────────────────────────────┐$color_reset"
      printf " $color_alias%-10s$color_reset → %-22s $color_dim# %-24s$color_reset\n" "gitc"   "git commit"           "Commit changes"
      printf " $color_alias%-10s$color_reset → %-22s $color_dim# %-24s$color_reset\n" "gitps"  "git push"             "Push to remote"
      printf " $color_alias%-10s$color_reset → %-22s $color_dim# %-24s$color_reset\n" "gitpl"  "git pull + submodule" "Pull with submodules"
      printf " $color_alias%-10s$color_reset → %-22s $color_dim# %-24s$color_reset\n" "gitplr" "git pull --rec"       "Pull recursive"
      printf " $color_alias%-10s$color_reset → %-22s $color_dim# %-24s$color_reset\n" "gitsub" "git submodule update" "Update submodules"
      printf " $color_alias%-10s$color_reset → %-22s $color_dim# %-24s$color_reset\n" "gitpls" "git pull"             "Pull only"
      printf " $color_alias%-10s$color_reset → %-22s $color_dim# %-24s$color_reset\n" "gita"   "git add -A"           "Stage all changes"
      printf " $color_alias%-10s$color_reset → %-22s $color_dim# %-24s$color_reset\n" "gitst"  "git status"           "Show status"
      printf " $color_alias%-10s$color_reset → %-22s $color_dim# %-24s$color_reset\n" "gitd"   "git diff"             "Show diff"
      printf " $color_alias%-10s$color_reset → %-22s $color_dim# %-24s$color_reset\n" "gitds"  "git diff --staged"    "Show staged diff"
      printf " $color_alias%-10s$color_reset → %-22s $color_dim# %-24s$color_reset\n" "gitl"   "git log"              "Show log"
      printf " $color_alias%-10s$color_reset → %-22s $color_dim# %-24s$color_reset\n" "ll"     "eza -hal --icons"     "List files detailed"
      printf " $color_alias%-10s$color_reset → %-22s $color_dim# %-24s$color_reset\n" "lg"     "lazygit"              "Git TUI"
      printf " $color_alias%-10s$color_reset → %-22s $color_dim# %-24s$color_reset\n" "j"      "just"                 "Command runner"
      printf " $color_alias%-10s$color_reset → %-22s $color_dim# %-24s$color_reset\n" "duai"   "dua interactive"      "Disk usage TUI"
      echo -e "$color_alias└────────────────────────────────────────────────────────────────────────┘$color_reset\n"

      # ── Abbreviations ──
      echo -e "$color_abbr┌─ Abbreviations (type & press Space to expand) ─────────────────────────┐$color_reset"
      printf " $color_abbr%-10s$color_reset → %-22s $color_dim# %-28s$color_reset\n" "cl"      "clear"           "Clear screen"
      printf " $color_abbr%-10s$color_reset → %-22s $color_dim# %-28s$color_reset\n" "less"    "bat"             "Better pager with syntax"
      printf " $color_abbr%-10s$color_reset → %-22s $color_dim# %-28s$color_reset\n" "man"     "batman"          "Man pages with bat"
      printf " $color_abbr%-10s$color_reset → %-22s $color_dim# %-28s$color_reset\n" "du"      "dua"             "Modern disk usage"
      printf " $color_abbr%-10s$color_reset → %-22s $color_dim# %-28s$color_reset\n" "ncdu"    "dua interactive" "Disk usage TUI"
      printf " $color_abbr%-10s$color_reset → %-22s $color_dim# %-28s$color_reset\n" "df"      "duf"             "Modern df"
      printf " $color_abbr%-10s$color_reset → %-22s $color_dim# %-28s$color_reset\n" "tree"    "erd"             "Modern tree"
      printf " $color_abbr%-10s$color_reset → %-22s $color_dim# %-28s$color_reset\n" "tmux"    "zellij"          "Modern multiplexer"
      printf " $color_abbr%-10s$color_reset → %-22s $color_dim# %-28s$color_reset\n" "dig"     "dog"             "Modern DNS lookup"
      printf " $color_abbr%-10s$color_reset → %-22s $color_dim# %-28s$color_reset\n" "diff"    "difft"           "Structural diff"
      printf " $color_abbr%-10s$color_reset → %-22s $color_dim# %-28s$color_reset\n" "ping"    "pingt"           "Timestamped ping"
      printf " $color_abbr%-10s$color_reset → %-22s $color_dim# %-28s$color_reset\n" "tar"     "ouch"            "Smart archive tool"
      printf " $color_abbr%-10s$color_reset → %-22s $color_dim# %-28s$color_reset\n" "ps"      "procs"           "Modern ps"
      printf " $color_abbr%-10s$color_reset → %-22s $color_dim# %-28s$color_reset\n" "whois"   "rdap"            "Modern whois"
      printf " $color_abbr%-10s$color_reset → %-22s $color_dim# %-28s$color_reset\n" "vim"     "hx"              "Helix editor"
      printf " $color_abbr%-10s$color_reset → %-22s $color_dim# %-28s$color_reset\n" "killall" "pkill"           "Kill by name"
      echo -e "$color_abbr└────────────────────────────────────────────────────────────────────────┘$color_reset\n"

      # ── SSH Shortcuts ──
      echo -e "$color_abbr┌─ SSH Shortcuts (with zellij session) ──────────────────────────────────┐$color_reset"
      printf " $color_abbr%-10s$color_reset → %-22s $color_dim%-28s$color_reset\n" "hsb0" "Home server 0"   "(192.168.1.99)"
      printf " $color_abbr%-10s$color_reset → %-22s $color_dim%-28s$color_reset\n" "hsb1" "Home server 1"   "(192.168.1.101)"
      printf " $color_abbr%-10s$color_reset → %-22s $color_dim%-28s$color_reset\n" "hsb8" "Home server 8"   "(192.168.1.100)"
      printf " $color_abbr%-10s$color_reset → %-22s $color_dim%-28s$color_reset\n" "gpc0" "Gaming PC"       "(192.168.1.154)"
      printf " $color_abbr%-10s$color_reset → %-22s $color_dim%-28s$color_reset\n" "csb0" "Cloud server 0"  "(cs0.barta.cm)"
      printf " $color_abbr%-10s$color_reset → %-22s $color_dim%-28s$color_reset\n" "csb1" "Cloud server 1"  "(cs1.barta.cm)"
      echo -e "$color_abbr└────────────────────────────────────────────────────────────────────────┘$color_reset\n"
    '';
  };
}
