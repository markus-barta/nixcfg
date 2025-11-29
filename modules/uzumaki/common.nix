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
}
