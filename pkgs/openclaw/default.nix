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
#   - Uses buildNpmPackage with vendored package-lock.json
#   - To update: fetch new npm package, run npm install --package-lock-only
#   - Then update npmDepsHash (build will tell you the expected hash)
#
# Updates:
#   1. Update version below
#   2. Update src hash
#   3. Run npm install --package-lock-only in unpacked package
#   4. Copy package-lock.json here
#   5. Update npmDepsHash (build will fail with expected hash)
#
# References:
#   - https://openclaw.ai/
#   - https://docs.openclaw.ai/
#   - P9400: hsb1 OpenClaw deployment
#
{
  lib,
  buildNpmPackage,
  fetchurl,
  nodejs_22,
}:

let
  version = "2026.1.29";
in
buildNpmPackage {
  pname = "openclaw";
  inherit version;

  src = fetchurl {
    url = "https://registry.npmjs.org/openclaw/-/openclaw-${version}.tgz";
    sha256 = "sha256-5tiVpmjA86SC/4Ne3+28JgdCbsvgi2bA5HqV5f64Lmg=";
  };

  # npm package is a tarball
  unpackPhase = ''
    tar -xzf $src
    mv package openclaw-${version}
    sourceRoot=openclaw-${version}
  '';

  # Copy our vendored package-lock.json
  postUnpack = ''
    cp ${./package-lock.json} $sourceRoot/package-lock.json
  '';

  # npmDepsHash for all dependencies
  # Run: nix-prefetch-npm-deps pkgs/openclaw/package-lock.json
  # Or: let build fail and copy the expected hash
  npmDepsHash = lib.fakeSha256; # Will fail and tell us the real hash

  # Don't rebuild - dist/ already contains compiled JS
  dontNpmBuild = true;

  # Override install to create proper wrapper
  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/lib/openclaw

    # Copy all files including node_modules and dist
    cp -r . $out/lib/openclaw/

    # Create wrapper script
    makeWrapper ${nodejs_22}/bin/node $out/bin/openclaw \
      --add-flags "$out/lib/openclaw/openclaw.mjs" \
      --prefix PATH : ${nodejs_22}/bin

    runHook postInstall
  '';

  nativeBuildInputs = [ nodejs_22 ];

  meta = with lib; {
    description = "OpenClaw AI Assistant Gateway";
    longDescription = ''
      OpenClaw is a personal AI assistant with multi-channel support
      and sandboxed tool execution. Supports Telegram, WhatsApp,
      Discord, and other messaging platforms with configurable
      LLM providers including OpenAI, Anthropic, and OpenRouter.
    '';
    homepage = "https://openclaw.ai";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "openclaw";
  };
}
