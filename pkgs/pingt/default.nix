# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  pingt - Timestamped ping with color-coded output                           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# A wrapper around ping that adds timestamps and color-coded output for
# easier network monitoring and diagnostics.
#
# Features:
#   • Timestamp prefix (HH:MM:SS) on every line
#   • Yellow highlighting for timeout messages
#   • Red highlighting for error messages
#   • Respects NO_COLOR environment variable
#   • Works in any POSIX-compatible shell
#
# Usage:
#   pingt google.com           # Basic usage
#   pingt -c 5 192.168.1.1     # 5 pings with timestamps
#   pingt --help               # Show help
#
{
  lib,
  writeShellApplication,
  iputils ? null, # Linux ping (null on Darwin)
  stdenvNoCC,
}:

let
  version = "1.0.0";

  # On Linux, use iputils; on Darwin, ping is in system PATH (/sbin/ping)
  pingDeps = if stdenvNoCC.isDarwin then [ ] else [ iputils ];
in
writeShellApplication {
  name = "pingt";

  runtimeInputs = pingDeps;

  text = ''
    # ╔══════════════════════════════════════════════════════════════════════════════╗
    # ║  pingt - Timestamped ping with color-coded output                            ║
    # ╠══════════════════════════════════════════════════════════════════════════════╣
    # ║  Version: ${version}                                                              ║
    # ║  License: MIT                                                                ║
    # ║  Author:  Markus Barta <markus@barta.com>                                    ║
    # ║  Source:  https://github.com/markus-barta/nixcfg                             ║
    # ╠══════════════════════════════════════════════════════════════════════════════╣
    # ║  A wrapper around ping that adds timestamps and color-coded output:          ║
    # ║    • Gray timestamp prefix on every line                                     ║
    # ║    • Yellow highlighting for timeout messages                                ║
    # ║    • Red highlighting for error messages                                     ║
    # ║    • Normal output for successful responses                                  ║
    # ╚══════════════════════════════════════════════════════════════════════════════╝

    # ════════════════════════════════════════════════════════════════════════════════
    # Constants
    # ════════════════════════════════════════════════════════════════════════════════

    readonly VERSION="${version}"
    readonly SCRIPT_NAME="pingt"

    # ════════════════════════════════════════════════════════════════════════════════
    # Color Definitions
    # ════════════════════════════════════════════════════════════════════════════════
    # Use colors only if:
    #   1. stdout is a terminal (not piped)
    #   2. TERM is set and not "dumb"
    #   3. NO_COLOR environment variable is not set
    # ════════════════════════════════════════════════════════════════════════════════

    setup_colors() {
      if [[ -t 1 ]] && [[ "''${TERM:-dumb}" != "dumb" ]] && [[ -z "''${NO_COLOR:-}" ]]; then
        COLOR_GRAY=$'\033[90m'   # Bright black (gray)
        COLOR_YELLOW=$'\033[33m' # Yellow for timeouts
        COLOR_RED=$'\033[31m'    # Red for errors
        COLOR_RESET=$'\033[0m'   # Reset to default
      else
        COLOR_GRAY=""
        COLOR_YELLOW=""
        COLOR_RED=""
        COLOR_RESET=""
      fi
    }

    # ════════════════════════════════════════════════════════════════════════════════
    # Usage & Help
    # ════════════════════════════════════════════════════════════════════════════════

    show_help() {
      cat <<EOF
    ''${SCRIPT_NAME} - Timestamped ping with color-coded output

    USAGE:
        ''${SCRIPT_NAME} [OPTIONS] <destination>
        ''${SCRIPT_NAME} [PING_OPTIONS] <destination>

    DESCRIPTION:
        A wrapper around ping that adds timestamps and color-coded output for
        easier monitoring and diagnostics.

        Output colors:
          • Gray     - Timestamp prefix (HH:MM:SS)
          • Yellow   - Timeout messages
          • Red      - Error messages (no route, host down, etc.)
          • Normal   - Successful ping responses

    OPTIONS:
        -h, --help      Show this help message and exit
        -V, --version   Show version information and exit

        All other options are passed directly to ping(1).

    EXAMPLES:
        ''${SCRIPT_NAME} google.com              # Ping with timestamps
        ''${SCRIPT_NAME} -c 5 192.168.1.1        # 5 pings with timestamps
        ''${SCRIPT_NAME} -i 0.5 -c 10 8.8.8.8    # Fast pings

    ENVIRONMENT:
        NO_COLOR    If set, disables colored output
        TERM        Colors disabled if set to "dumb"

    SEE ALSO:
        ping(1)

    VERSION:
        ''${VERSION}
    EOF
    }

    show_version() {
      echo "''${SCRIPT_NAME} ''${VERSION}"
    }

    # ════════════════════════════════════════════════════════════════════════════════
    # Core Logic
    # ════════════════════════════════════════════════════════════════════════════════

    # Classify a line and return appropriate color
    # Returns: color code via stdout
    get_line_color() {
      local line="$1"

      # Timeout patterns (yellow)
      # Note: *timeout* catches both "timeout" and "Request timeout"
      case "$line" in
      *timeout* | *Zeitüberschreitung*)
        echo "$COLOR_YELLOW"
        return
        ;;
      esac

      # Error patterns (red)
      case "$line" in
      *"sendto:"* | *"No route to host"* | *"Host is down"* | \
        *"Destination Host Unreachable"* | *"Network is unreachable"* | \
        *"Name or service not known"* | *"Temporary failure"* | \
        *"unknown host"* | *"nicht erreichbar"*)
        echo "$COLOR_RED"
        return
        ;;
      esac

      # Normal output (no color change)
      echo ""
    }

    # Format and print a single line with timestamp
    print_line() {
      local line="$1"
      local timestamp
      local color

      timestamp=$(date '+%H:%M:%S')
      color=$(get_line_color "$line")

      if [[ -n "$color" ]]; then
        printf '%s%s ·%s %s%s%s\n' \
          "$COLOR_GRAY" "$timestamp" "$COLOR_RESET" \
          "$color" "$line" "$COLOR_RESET"
      else
        printf '%s%s ·%s %s\n' \
          "$COLOR_GRAY" "$timestamp" "$COLOR_RESET" \
          "$line"
      fi
    }

    # Main ping wrapper
    run_pingt() {
      local args=("$@")

      # Execute ping and process each line
      # The 2>&1 captures both stdout and stderr for unified processing
      ping "''${args[@]}" 2>&1 | while IFS= read -r line; do
        print_line "$line"
      done

      # Preserve ping's exit code through the pipe
      return "''${PIPESTATUS[0]}"
    }

    # ════════════════════════════════════════════════════════════════════════════════
    # Main Entry Point
    # ════════════════════════════════════════════════════════════════════════════════

    # Parse our own options first
    case "''${1:-}" in
    -h | --help)
      show_help
      exit 0
      ;;
    -V | --version)
      show_version
      exit 0
      ;;
    esac

    # Require at least one argument (the destination)
    if [[ $# -eq 0 ]]; then
      echo "''${SCRIPT_NAME}: missing destination operand" >&2
      echo "Try '${""}''${SCRIPT_NAME} --help' for more information." >&2
      exit 1
    fi

    # Initialize colors
    setup_colors

    # Run the ping wrapper
    run_pingt "$@"
  '';

  meta = with lib; {
    description = "Timestamped ping with color-coded output";
    longDescription = ''
      pingt is a wrapper around ping that enhances output with:
      - Timestamp prefix (HH:MM:SS) on every line for easy log correlation
      - Color-coded output: yellow for timeouts, red for errors
      - Full pass-through of ping options
      - Respects NO_COLOR for accessibility

      Ideal for network diagnostics, monitoring, and troubleshooting.
    '';
    homepage = "https://github.com/markus-barta/nixcfg";
    license = licenses.mit;
    maintainers = [ ];
    # maintainers = with lib.maintainers; [ markus-barta ];
    platforms = platforms.unix;
    mainProgram = "pingt";
  };
}
