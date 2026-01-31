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

  # Convert pnpm-lock.yaml to package-lock.json for npm
  postPatch = ''
    # Generate a minimal package-lock.json from pnpm-lock.yaml
    # This allows buildNpmPackage to work with pnpm projects
    echo '{"lockfileVersion": 3, "packages": {}}' > package-lock.json
  '';

  # The npmDepsHash will be computed on first build
  # If build fails with hash mismatch, update with the expected hash from error
  npmDepsHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

  # Build steps - npm install will use the lock file
  buildPhase = ''
    runHook preBuild
    npm ci
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
