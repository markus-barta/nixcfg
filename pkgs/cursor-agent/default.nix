# NIX-514 — Cursor CLI (`cursor-agent`, alias `agent`) as a hash-pinned vendor
# tarball, the same package the official `curl https://cursor.com/install`
# script unpacks into ~/.local/share/cursor-agent/versions/<release>.
#
# nixpkgs ships `cursor-cli`, but it lags the vendor by months. The pin lives in
# sources.json so `just update-ai-clis` can bump it
# (scripts/update-cursor-agent.sh) without editing Nix.
#
# Self-update (NIX-516): the vendor starts a background updater about two
# seconds into every chat run. It installs into ~/.local/share/cursor-agent and
# relinks ~/.local/bin/{agent,cursor-agent}, re-creating the imperative copy this
# package replaces. $out/bin/{cursor-agent,agent} is wrapper.sh, which passes
# the hidden root option --disable-auto-update where the bundle's raw argv
# parsers cannot see it, and check-auto-update.mjs fails the bump unless the
# updater and option code still match the reviewed baseline
# (auto-update-review.json; re-pin with review-auto-update.mjs).
{
  lib,
  stdenvNoCC,
  fetchurl,
  runtimeShell,
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
    mkdir -p "$out/bin" "$out/libexec/cursor-agent" "$out/share/cursor-agent"
    cp -R . "$out/share/cursor-agent/"
    # The launcher finds its bundle with realpath and exports CURSOR_INVOKED_AS
    # from its $0, so one link per name keeps both working.
    ln -s ../../share/cursor-agent/cursor-agent "$out/libexec/cursor-agent/cursor-agent"
    ln -s ../../share/cursor-agent/cursor-agent "$out/libexec/cursor-agent/agent"
    # Every consumer (guard shims, paimos-agentd, Pi's CURSOR_AGENT_PATH) runs
    # $out/bin. A shell script, not makeBinaryWrapper: dontFixup skips the
    # ad-hoc signing an arm64 Mach-O wrapper would need.
    substitute ${./wrapper.sh} "$out/bin/cursor-agent" \
      --subst-var-by shell ${runtimeShell} \
      --subst-var-by libexec "$out/libexec/cursor-agent"
    chmod +x "$out/bin/cursor-agent"
    ln -s cursor-agent "$out/bin/agent"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase =
    let
      # NIX-516: the check, its scanner and the reviewed baseline, side by side.
      autoUpdateCheck = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          ./auto-update-scan.mjs
          ./check-auto-update.mjs
          ./auto-update-review.json
        ];
      };
    in
    ''
      runHook preInstallCheck
      version_output="$(HOME="$TMPDIR" "$out/bin/cursor-agent" --version)"
      if [ "$version_output" != "${version}" ]; then
        echo "cursor-agent: expected version ${version}, got: $version_output" >&2
        exit 1
      fi

      # NIX-516. The CLI accepts unknown options, so a run that works proves
      # nothing about the flag: the vendor node compares the bundle's updater and
      # option code with the reviewed baseline.
      (cd "$out/share/cursor-agent" && ./node ${autoUpdateCheck}/check-auto-update.mjs)
      # These commands take the flag after their name; each must still parse.
      for command in resume ls sandbox; do
        HOME="$TMPDIR" "$out/bin/agent" "$command" --help | grep -q "^Usage: agent $command" || {
          echo "cursor-agent: '$command' no longer parses with the wrapper flag" >&2
          exit 1
        }
      done
      HOME="$TMPDIR" "$out/bin/agent" --help | grep -q '^Usage: agent \[options\]' || {
        echo "cursor-agent: the root command no longer parses with the wrapper flag" >&2
        exit 1
      }
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
