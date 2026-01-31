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
  buildNpmPackage,
  nodejs_22,
  # Provided via flake input (see flake.nix inputs.openclaw)
  src,
}:

buildNpmPackage {
  pname = "openclaw";
  # Use version from package.json
  version = (builtins.fromJSON (builtins.readFile (src + "/package.json"))).version;

  inherit src;

  # Use Node.js 22 as required by OpenClaw
  nodejs = nodejs_22;

  # The npmDepsHash will be computed on first build
  # If build fails with hash mismatch, update with:
  #   nix-prefetch-npm ./pkgs/openclaw/src
  npmDepsHash = lib.fakeSha256;

  # Build steps from OpenClaw docs (using npm, not pnpm)
  buildPhase = ''
    runHook preBuild
    npm run ui:build
    npm run build
    runHook postBuild
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
