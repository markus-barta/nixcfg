{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchPnpmDeps,
  pnpmConfigHook,
  pnpm_10,
  nodejs_22,
  makeWrapper,
  jq,
  cmake,
  python3,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "openclaw";
  version = "2026.2.3";

  src = fetchFromGitHub {
    owner = "openclaw";
    repo = "openclaw";
    tag = "v${finalAttrs.version}";
    hash = "sha256-gQwwra9c9ID3O+W/fRNgSXHvjTASYV/lng7d+f1+XT4=";
  };

  # pnpm deps differ by platform (optional deps / native bindings)
  pnpmDepsHash =
    if stdenvNoCC.hostPlatform.isDarwin then
      "sha256-PCzuuPWqJW7FfGOTcFi0TKFV6TlPcwjyIQz88tsBgtM="
    else
      "sha256-uOhFo64Y0JmgY4JFjoX6z7M/Vg9mnjBa/oOPWmXz2IU=";

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    pnpm = pnpm_10;
    fetcherVersion = 3;
    hash = finalAttrs.pnpmDepsHash;
  };

  nativeBuildInputs = [
    pnpmConfigHook
    pnpm_10
    nodejs_22
    makeWrapper
    jq
    cmake
    python3
  ];

  # Force node-llama-cpp to build from source instead of downloading binaries
  # and prevent it from trying to access the internet during the build phase.
  # Reference: https://node-llama-cpp.com/guide/installation#environment-variables
  NODE_LLAMA_CPP_SKIP_BINARY_DOWNLOAD = "1";
  NODE_LLAMA_CPP_LOCAL_BUILD = "1";

  preConfigure = ''
    export HOME="$TMPDIR"
    export XDG_DATA_HOME="$TMPDIR/.local/share"
    export XDG_CACHE_HOME="$TMPDIR/.cache"
    export PNPM_HOME="$TMPDIR/.local/share/pnpm"
    mkdir -p "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$PNPM_HOME"
    export NODE_OPTIONS="--dns-result-order=ipv4first ''${NODE_OPTIONS-}"
  '';

  # Patch ALL package.json files in the monorepo to fix version 0.0.0 display
  postPatch = ''
    find . -name "package.json" -type f | while read -r f; do
      jq '.version = "${finalAttrs.version}"' "$f" > "$f.tmp"
      mv "$f.tmp" "$f"
    done
  '';

  buildPhase = ''
    runHook preBuild

    pnpm rebuild
    pnpm build
    pnpm ui:build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    libdir=$out/lib/openclaw
    mkdir -p $libdir $out/bin


    cp --reflink=auto -r dist node_modules $libdir/
    cp --reflink=auto -r assets docs skills patches extensions $libdir/ 2>/dev/null || true

    rm -f $libdir/node_modules/.pnpm/node_modules/clawdbot \
      $libdir/node_modules/.pnpm/node_modules/moltbot \
      $libdir/node_modules/.pnpm/node_modules/openclaw-control-ui

    makeWrapper ${lib.getExe nodejs_22} $out/bin/openclaw \
      --add-flags "$libdir/dist/index.js" \
      --set NODE_PATH "$libdir/node_modules" \
      --set OPENCLAW_BUNDLED_VERSION "${finalAttrs.version}"
    ln -s $out/bin/openclaw $out/bin/moltbot
    ln -s $out/bin/openclaw $out/bin/clawdbot

    runHook postInstall
  '';

  meta = {
    description = "Self-hosted, open-source AI assistant/agent";
    longDescription = ''
      Self-hosted AI assistant/agent connected to all your apps on your Linux
      or macOS machine and controlled via your choice of chat app.

      Note: Project is in early development and uses LLMs to parse untrusted
      content while having full access to system by default.

      (Originally known as Moltbot and ClawdBot)
    '';
    homepage = "https://openclaw.ai";
    changelog = "https://github.com/openclaw/openclaw/releases/tag/${finalAttrs.src.tag}";
    license = lib.licenses.mit;
    mainProgram = "openclaw";
    maintainers = with lib.maintainers; [ chrisportela ];
    platforms = with lib.platforms; linux ++ darwin;
  };
})
