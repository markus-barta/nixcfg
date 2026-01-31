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
#   - Uses pnpm (OpenClaw's native package manager)
#   - Built from GitHub source via flake input
#   - Uses stdenv.mkDerivation (not buildNpmPackage) for pnpm support
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
  nodejs_22,
  pnpm,
  makeWrapper,
  # Provided via flake input (see flake.nix inputs.openclaw)
  src,
}:

stdenv.mkDerivation {
  pname = "openclaw";
  version = (builtins.fromJSON (builtins.readFile (src + "/package.json"))).version;
  inherit src;

  # Patch package.json to remove packageManager field (prevents corepack from downloading pnpm)
  postPatch = ''
    ${nodejs_22}/bin/node -e "
      const fs = require('fs');
      const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
      delete pkg.packageManager;
      fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
    "
  '';

  nativeBuildInputs = [
    nodejs_22
    pnpm
    makeWrapper
  ];

  buildPhase = ''
    runHook preBuild

    # Disable corepack to prevent pnpm self-download
    export COREPACK_ENABLE_AUTO_PIN=0
    export COREPACK_ENABLE_STRICT=0
    export PNPM_IGNORE_PACKAGE_MANAGER_VERSION=1

    # Use system pnpm directly
    export PNPM_HOME=$TMPDIR/pnpm
    mkdir -p $PNPM_HOME

    # Install dependencies using system pnpm
    pnpm install --frozen-lockfile
    pnpm ui:build
    pnpm build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/lib/openclaw
    cp -r dist node_modules package.json $out/lib/openclaw/
    makeWrapper ${nodejs_22}/bin/node $out/bin/openclaw \
      --add-flags "$out/lib/openclaw/dist/index.js"
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
