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
  stdenvNoCC,
  makeWrapper,
  iputils ? null, # Linux ping (null on Darwin)
}:

stdenvNoCC.mkDerivation rec {
  pname = "pingt";
  version = "1.0.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];

  # No build phase needed - it's a shell script
  dontBuild = true;

  installPhase =
    let
      # On Linux, use iputils; on Darwin, ping is in system PATH (/sbin/ping)
      pingPath =
        if stdenvNoCC.isDarwin then
          "/sbin" # macOS system ping
        else
          lib.makeBinPath [ iputils ]; # Linux iputils
    in
    ''
      runHook preInstall

      # Install the script
      install -Dm755 pingt.sh $out/bin/pingt

      # Wrap to ensure ping is in PATH
      wrapProgram $out/bin/pingt \
        --prefix PATH : ${pingPath}

      runHook postInstall
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
    platforms = platforms.unix;
    mainProgram = "pingt";
  };
}
