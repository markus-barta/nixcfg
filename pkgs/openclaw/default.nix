# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  openclaw - AI Assistant Gateway                                            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# OpenClaw is a personal AI assistant with multi-channel support (Telegram,
# WhatsApp, Discord) and sandboxed tool execution for secure AI automation.
#
# Features:
#   • Multi-channel chat interfaces (Telegram, WhatsApp, Discord, etc.)
#   • Sandboxed tool execution for security
#   • Local file editing and command execution
#   • Web browsing and API integrations
#   • Configurable LLM providers (OpenAI, Anthropic, OpenRouter)
#
# Usage:
#   openclaw gateway              # Start the gateway service
#   openclaw onboard              # Interactive setup wizard
#   openclaw dashboard            # Web dashboard
#
# Configuration:
#   ~/.openclaw/openclaw.json     # Main configuration file
#   ~/.openclaw/workspace/        # Workspace for file operations
#
# Build Notes:
#   - Fetches pre-built package from npm registry
#   - All dependencies already bundled (no network during build)
#   - Uses stdenv.mkDerivation for simple installation
#
# Updates:
#   nix flake update openclaw     # Update to latest
#
# References:
#   - https://openclaw.ai/
#   - https://docs.openclaw.ai/
#   - P9400: hsb1 OpenClaw deployment
#   - flake.nix: inputs.openclaw
#
{
  lib,
  stdenv,
  fetchurl,
  nodejs_22,
  makeWrapper,
}:

let
  version = "2026.1.29";
in
stdenv.mkDerivation {
  pname = "openclaw";
  inherit version;

  # Fetch pre-built package from npm (includes all deps)
  src = fetchurl {
    url = "https://registry.npmjs.org/openclaw/-/openclaw-${version}.tgz";
    # sha256 = lib.fakeSha256; # Will fail first time, get real hash from mnt/etc/nixos/hardware-configuration.nix
    sha256 = "sha256-5tiVpmjA86SC/4Ne3+28JgdCbsvgi2bA5HqV5f64Lmg=";
  };

  nativeBuildInputs = [ makeWrapper ];

  # npm packages are tar.gz
  unpackPhase = ''
    tar -xzf $src
  '';

  sourceRoot = "package";

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/lib/openclaw

    # Copy all package files
    cp -r . $out/lib/openclaw/

    # Create wrapper script (entry point is openclaw.mjs per package.json)
    makeWrapper ${nodejs_22}/bin/node $out/bin/openclaw \
      --add-flags "$out/lib/openclaw/openclaw.mjs" \
      --prefix PATH : ${nodejs_22}/bin

    runHook postInstall
  '';

  meta = with lib; {
    description = "OpenClaw AI Assistant Gateway";
    longDescription = ''
      OpenClaw is a personal AI assistant with multi-channel support
      and sandboxed tool execution. Supports Telegram, WhatsApp,
      Discord, and other messaging platforms with configurable
      LLM providers including OpenAI, Anthropic, and OpenRouter.

      Updates: nix flake update openclaw
    '';
    homepage = "https://openclaw.ai";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "openclaw";
  };
}
