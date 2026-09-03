{
  lib,
  stdenvNoCC,
  fetchurl,
  jq,
  coreutils,
}:

let
  version = "1.1.24";
  assets = {
    "aarch64-darwin" = {
      platform = "darwin";
      arch = "arm64";
      hash = "sha256-zyNwfqj0N8kxAtiRElwQMYxYEiM/YLTDv9otHVM0/ks=";
    };
    "x86_64-darwin" = {
      platform = "darwin";
      arch = "amd64";
      hash = "sha256-wAOKh7NyvtGjj76vPoyXH86WFwyApQmOOkhNT6JPdnw=";
    };
    "aarch64-linux" = {
      platform = "linux";
      arch = "arm64";
      hash = "sha256-f1QjQ2Joi0YBIqaufUIVKxbWJ4H4Nmv4+NB4q1ZqVgQ=";
    };
    "x86_64-linux" = {
      platform = "linux";
      arch = "amd64";
      hash = "sha256-Ymzn+/7C33N+weWoZDQxR5+g0tI3bWpSt9dGcFF1SGI=";
    };
  };
  system = stdenvNoCC.hostPlatform.system;
  asset = assets.${system} or (throw "higgsfield-cli: unsupported system ${system}");
in
stdenvNoCC.mkDerivation {
  pname = "higgsfield-cli";
  inherit version;

  src = fetchurl {
    url = "https://github.com/higgsfield-ai/cli/releases/download/v${version}/hf_${version}_${asset.platform}_${asset.arch}.tar.gz";
    inherit (asset) hash;
  };

  sourceRoot = ".";
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    install -m 0755 hf "$out/bin/higgsfield"
    install -m 0755 ${./higgsfield-smoke.sh} "$out/bin/higgsfield-smoke"
    substituteInPlace "$out/bin/higgsfield-smoke" \
      --replace-fail '@higgsfield@' "$out/bin/higgsfield" \
      --replace-fail '@version@' '${version}' \
      --replace-fail '@jq@' '${jq}/bin/jq' \
      --replace-fail '@sha256sum@' '${coreutils}/bin/sha256sum'
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    version_output="$($out/bin/higgsfield --version)"
    case "$version_output" in
      "higgsfield ${version} "*) ;;
      *)
        echo "unexpected Higgsfield version output" >&2
        exit 1
        ;;
    esac
  '';

  meta = {
    description = "Official Higgsfield AI command-line client";
    homepage = "https://github.com/higgsfield-ai/cli";
    license = lib.licenses.mit;
    mainProgram = "higgsfield";
    platforms = builtins.attrNames assets;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
