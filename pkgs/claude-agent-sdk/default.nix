{
  lib,
  stdenvNoCC,
  fetchurl,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "claude-agent-sdk";
  version = "0.3.251";

  src = fetchurl {
    url = "https://registry.npmjs.org/@anthropic-ai/claude-agent-sdk/-/claude-agent-sdk-${finalAttrs.version}.tgz";
    hash = "sha512-DqSi8mH2tQYRlVV0G+lJnQ/WbjJZ/a+8cJ3vPuYoqh8esIIvXHm1ZOXV1UPGsFYRnbBytEoiSGitguEXd+sQ+Q==";
  };

  sourceRoot = "package";
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    sdk_hash=$(sha256sum sdk.mjs | cut -d ' ' -f 1)
    test "$sdk_hash" = 9235fac983c29e614d7f572a578406dc5dbda006305faa99f9447f577738eb93

    destination=$out/lib/node_modules/@anthropic-ai/claude-agent-sdk
    mkdir -p "$destination"
    cp -R . "$destination"

    runHook postInstall
  '';

  passthru.sdkPath = "${placeholder "out"}/lib/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs";

  meta = {
    description = "Exact operator-installed Claude Agent SDK for PAIMOS owned sessions";
    homepage = "https://platform.claude.com/docs/en/agent-sdk/overview";
    license = lib.licenses.unfree;
    platforms = lib.platforms.unix;
  };
})
