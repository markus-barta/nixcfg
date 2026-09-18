# NIX-514 — Cursor CLI (`cursor-agent`, alias `agent`) as a hash-pinned vendor
# tarball, the same package the official `curl https://cursor.com/install`
# script unpacks into ~/.local/share/cursor-agent/versions/<release>.
#
# nixpkgs ships `cursor-cli`, but it lags the vendor by months. The pin lives in
# sources.json so `just update-ai-clis` can bump it
# (scripts/update-cursor-agent.sh) without editing Nix.
#
# Self-update: the CLI still runs its background updater, but that only writes
# into ~/.local/share/cursor-agent and ~/.local/bin, which nothing in this repo
# points at. Its in-use marker is skipped outside a `versions/` directory, so the
# read-only store path is never written.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:

let
  pin = lib.importJSON ./sources.json;
  inherit (pin) version;
  system = stdenvNoCC.hostPlatform.system;
  asset = pin.assets.${system} or (throw "cursor-agent: unsupported system ${system}");
in
stdenvNoCC.mkDerivation {
  pname = "cursor-agent";
  inherit version;

  src = fetchurl {
    url = "https://downloads.cursor.com/lab/${version}/${asset.os}/${asset.arch}/agent-cli-package.tar.gz";
    inherit (asset) hash;
  };

  dontConfigure = true;
  dontBuild = true;
  # Vendor-signed Mach-O files (node, cursorsandbox, *.node) carry hardened-runtime
  # signatures and entitlements; any rewrite invalidates them. Keep every byte
  # as shipped — the launcher's `/usr/bin/env bash` shebang is what the vendor
  # install runs too.
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    # The tarball carries AppleDouble `._*` sidecars (xattr signatures of the
    # Linux/Windows prebuilds); macOS tar folds them into xattrs, GNU tar
    # writes them out. Drop them so the tree matches the vendor install.
    find . -name '._*' -type f -delete
    mkdir -p "$out/bin" "$out/share/cursor-agent"
    cp -R . "$out/share/cursor-agent/"
    # The launcher resolves its own directory with realpath, so both names work
    # through symlinks, exactly like the vendor's ~/.local/bin links.
    ln -s "$out/share/cursor-agent/cursor-agent" "$out/bin/cursor-agent"
    ln -s "$out/share/cursor-agent/cursor-agent" "$out/bin/agent"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    version_output="$(HOME="$TMPDIR" "$out/bin/cursor-agent" --version)"
    if [ "$version_output" != "${version}" ]; then
      echo "cursor-agent: expected version ${version}, got: $version_output" >&2
      exit 1
    fi
    runHook postInstallCheck
  '';

  meta = {
    description = "Cursor CLI coding agent (cursor-agent)";
    homepage = "https://cursor.com/cli";
    license = lib.licenses.unfree;
    mainProgram = "cursor-agent";
    platforms = builtins.attrNames pin.assets;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
