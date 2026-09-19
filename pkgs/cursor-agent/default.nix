# NIX-514 — Cursor CLI (`cursor-agent`, alias `agent`) as a hash-pinned vendor
# tarball, the same package the official `curl https://cursor.com/install`
# script unpacks into ~/.local/share/cursor-agent/versions/<release>.
#
# nixpkgs ships `cursor-cli`, but it lags the vendor by months. The pin lives in
# sources.json so `just update-ai-clis` can bump it
# (scripts/update-cursor-agent.sh) without editing Nix.
#
# Self-update (NIX-516): the vendor starts a background updater about two
# seconds into every agent run. It installs into ~/.local/share/cursor-agent and
# relinks ~/.local/bin/{agent,cursor-agent}, re-creating the imperative copy this
# package replaces. $out/bin is a wrapper that always passes the hidden root
# option --disable-auto-update, and installCheck fails the bump if the vendor
# drops that option or adds an automatic update it does not gate.
{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
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

  nativeBuildInputs = [ makeWrapper ];

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
    # Every consumer (guard shims, paimos-agentd, Pi's CURSOR_AGENT_PATH) runs
    # $out/bin, so the flag goes on there. The wrapper execs the launcher by its
    # absolute path, which the launcher resolves to find its bundle. A shell
    # wrapper, not makeBinaryWrapper: dontFixup skips the ad-hoc signing an
    # arm64 Mach-O wrapper would need.
    makeWrapper "$out/share/cursor-agent/cursor-agent" "$out/bin/cursor-agent" \
      --add-flags --disable-auto-update
    ln -s cursor-agent "$out/bin/agent"
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

    # NIX-516. The CLI accepts unknown options, so a run that works proves
    # nothing about the flag: check the bundle instead. The option must still be
    # defined, and every automatic update must still be gated on it.
    bundle="$out/share/cursor-agent"
    grep -Fq -- '"--disable-auto-update"' "$bundle/index.js" || {
      echo "cursor-agent: the vendor bundle no longer defines --disable-auto-update" >&2
      exit 1
    }
    cat "$bundle"/*.js | grep -oE '.{0,300}isAutoUpdate:!0' >"$TMPDIR/auto-update-sites" || true
    if grep -v 'disableAutoUpdate' "$TMPDIR/auto-update-sites" | grep -q .; then
      echo "cursor-agent: an automatic update is no longer gated on disableAutoUpdate" >&2
      exit 1
    fi
    grep -Fq -- '--disable-auto-update' "$out/bin/cursor-agent" || {
      echo "cursor-agent: the wrapper does not pass --disable-auto-update" >&2
      exit 1
    }
    # Subcommands still parse with the flag in front of them.
    for command in update models status login; do
      HOME="$TMPDIR" "$out/bin/agent" "$command" --help | grep -q "^Usage: agent $command" || {
        echo "cursor-agent: '$command' no longer parses behind the wrapper flag" >&2
        exit 1
      }
    done
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
