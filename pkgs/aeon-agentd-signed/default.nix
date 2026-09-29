# NIX-588 / AEON-285: Aeon's darwin agentd as the released, Developer ID
# signed and notarized binary instead of a source build.
#
# Nix-built Go binaries are ad-hoc signed without a team identifier, and the
# daemon's Mac confirmation (Touch ID before a session is watched) fails closed
# unless its own signature carries the expected Developer ID team. So on
# macOS we install the release asset byte for byte:
#   - fetched by fixed hash from the same tag as the `aeon` flake input;
#   - installed as bin/aeon-agentd (a name the daemon's gate accepts);
#   - dontFixup: no strip and no ad-hoc re-signing, which would drop the
#     team signature.
# installCheck verifies the signature offline with /usr/bin/codesign (the
# darwin build here runs without the Nix sandbox): strict validity, team
# P66J39QV6V and the hardened runtime. A pin bump that brings an unsigned
# asset fails the build instead of silently disabling Touch ID.
#
# Bumping: set `version` to the aeon input's tag (without the leading `v`)
# and take both hashes from that release's SHA256SUMS
# (nix hash convert --hash-algo sha256 --to sri <hex>).
{
  lib,
  stdenvNoCC,
  fetchurl,
}:

let
  version = "260929113854.0.0";
  teamID = "P66J39QV6V";
  assets = {
    aarch64-darwin = {
      arch = "arm64";
      hash = "sha256-oe+lYucU071Ai0Hz+j/q6OBqRPX41AAneF6W36667eY=";
    };
    x86_64-darwin = {
      arch = "amd64";
      hash = "sha256-s7CEgzFbZ98llXJ3HBnj/zqEgrior0I5Vms4mcZo4g8=";
    };
  };
  system = stdenvNoCC.hostPlatform.system;
  asset = assets.${system} or (throw "aeon-agentd-signed: no signed release asset for ${system}");
in
stdenvNoCC.mkDerivation {
  pname = "aeon-agentd";
  inherit version;

  src = fetchurl {
    url = "https://github.com/inspr-at/paimos/releases/download/v${version}/paimos-agentd-darwin-${asset.arch}";
    inherit (asset) hash;
  };

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  # Keep the release bytes: fixup would strip and ad-hoc re-sign on darwin.
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/aeon-agentd"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    bin="$out/bin/aeon-agentd"
    if [ ! -x /usr/bin/codesign ]; then
      echo "aeon-agentd-signed: /usr/bin/codesign unavailable; cannot verify the Developer ID signature" >&2
      exit 1
    fi
    /usr/bin/codesign --verify --strict "$bin"
    info="$(/usr/bin/codesign -dv "$bin" 2>&1)"
    printf '%s\n' "$info" | grep -qx "TeamIdentifier=${teamID}" || {
      echo "aeon-agentd-signed: expected team ${teamID}, got:" >&2; printf '%s\n' "$info" >&2; exit 1; }
    printf '%s\n' "$info" | grep -q 'flags=.*runtime' || {
      echo "aeon-agentd-signed: hardened runtime flag missing" >&2; exit 1; }
    runHook postInstallCheck
  '';

  passthru = { inherit teamID; };

  meta = {
    description = "Aeon agent daemon, Developer ID signed and notarized release build";
    homepage = "https://github.com/inspr-at/paimos";
    license = lib.licenses.agpl3Only;
    mainProgram = "aeon-agentd";
    platforms = builtins.attrNames assets;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
