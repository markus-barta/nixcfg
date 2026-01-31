# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  openclaw - AI Assistant Gateway                                            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# OpenClaw is a personal AI assistant with multi-channel support (Telegram,
# WhatsApp, Discord) and sandboxed tool execution for secure AI automation.
#
# Build Notes:
#   - Uses buildNpmPackage with vendored package-lock.json
#   - npm tarball doesn't include lock file, so we bundle it via postFetch
#
# Updates:
#   1. Update version and src hash
#   2. Run npm install --package-lock-only in unpacked package
#   3. Update npmDepsHash (build will fail with expected hash)
#
{
  lib,
  buildNpmPackage,
  fetchurl,
  runCommand,
  nodejs_22,
}:

let
  version = "2026.1.29";

  # Fetch npm package
  npmSource = fetchurl {
    url = "https://registry.npmjs.org/openclaw/-/openclaw-${version}.tgz";
    sha256 = "sha256-5tiVpmjA86SC/4Ne3+28JgdCbsvgi2bA5HqV5f64Lmg=";
  };

  # Create source with lock file included
  src = runCommand "openclaw-${version}-source" { } ''
    mkdir -p $out
    tar -xzf ${npmSource} -C $out --strip-components=1
    cp ${./package-lock.json} $out/package-lock.json
  '';
in
buildNpmPackage {
  pname = "openclaw";
  inherit version src;

  # npmDepsHash will be provided by build failure
  npmDepsHash = "sha256-XwN7iToEgSSkhVwaPGDayHJoP7d3VG+yYz4rycioMNI=";
  # Fix npm cache ownership issues in sandbox
  makeCacheWritable = true;
  # Don't rebuild - dist/ already contains compiled JS
  dontNpmBuild = true;

  # Install phase
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
    homepage = "https://openclaw.ai";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "openclaw";
  };
}
