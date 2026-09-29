# NIX-589: the Node.js and Claude Agent SDK that a paired aeon-agentd pins.
#
# `aeon-agentd setup/pair --node-path … --claude-sdk-path …` stores the
# PHYSICAL /nix/store paths behind the given links, and the daemon refuses the
# Claude harness once a stored pin no longer resolves to itself. So these two
# must not move when nixpkgs or Home Manager is updated. Both are fixed-output
# derivations: their store paths depend only on name and hash, never on the
# nixpkgs revision that builds them. Bumping either is a deliberate step that
# requires re-pairing the Claude harness until Aeon re-resolves stable links
# at start (AEON follow-up on NIX-589).
{
  stdenvNoCC,
  fetchzip,
}:

let
  nodeVersion = "24.20.0";
  sdkVersion = "0.3.251";
  nodeAssets = {
    aarch64-darwin = {
      arch = "arm64";
      hash = "sha256-F9UVZf9MU+xzeIyWekw3+nntYSfbj5phU2cQMNjBcus=";
    };
    x86_64-darwin = {
      arch = "x64";
      hash = "sha256-5Qh1inIZzCIg18ISjJXWWfc2WXp4IUEDGWQh62AuFyA=";
    };
  };
  system = stdenvNoCC.hostPlatform.system;
  nodeAsset =
    nodeAssets.${system} or (throw "aeon-agentd-claude-runtime: no pinned Node.js for ${system}");
in
{
  inherit nodeVersion sdkVersion;

  # Official nodejs.org build (checksum listed in its SHASUMS256.txt).
  node = fetchzip {
    name = "aeon-agentd-node-${nodeVersion}";
    url = "https://nodejs.org/dist/v${nodeVersion}/node-v${nodeVersion}-darwin-${nodeAsset.arch}.tar.gz";
    inherit (nodeAsset) hash;
  };

  # npm tarball laid out as lib/node_modules/@anthropic-ai/claude-agent-sdk,
  # the shape Aeon's SDK discovery requires. Same version and sdk.mjs digest
  # as pkgs/claude-agent-sdk.
  sdk = fetchzip {
    name = "aeon-agentd-claude-agent-sdk-${sdkVersion}";
    url = "https://registry.npmjs.org/@anthropic-ai/claude-agent-sdk/-/claude-agent-sdk-${sdkVersion}.tgz";
    hash = "sha256-4qXcNOmKv72eMQ5KjsKA0g1dJzQzP4llhA4BGGAn0xA=";
    postFetch = ''
      test "$(sha256sum "$out/sdk.mjs" | cut -d ' ' -f 1)" = 9235fac983c29e614d7f572a578406dc5dbda006305faa99f9447f577738eb93
      mv "$out" "$TMPDIR/package"
      mkdir -p "$out/lib/node_modules/@anthropic-ai"
      mv "$TMPDIR/package" "$out/lib/node_modules/@anthropic-ai/claude-agent-sdk"
    '';
  };
}
