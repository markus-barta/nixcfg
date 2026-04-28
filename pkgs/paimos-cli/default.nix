# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  paimos-cli — Agent-facing CLI for PAIMOS                                   ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Thin Go CLI wrapper over the PAIMOS HTTP API. Pure stdlib + cobra, no CGO —
# cross-compiles cleanly for darwin/linux on any host.
#
# Upstream: https://github.com/markus-barta/paimos
# Binary:   paimos (installed from backend/cmd/paimos)
#
# ── Bumping the pinned rev ────────────────────────────────────────────────────
#  1. Set `rev` to the new commit SHA.
#  2. Refresh `hash` (src):
#        nix store prefetch-file --unpack --hash-type sha256 \
#          https://github.com/markus-barta/paimos/archive/<rev>.tar.gz
#     …or set `hash = lib.fakeHash;`, run `nix build`, copy "got:" back.
#  3. Refresh `vendorHash` (go deps): only buildGoModule can compute this —
#     set `vendorHash = lib.fakeHash;`, run `nix build`, copy "got:" back.
#  4. Bump `version` to match the new VERSION + short sha.
#
{
  lib,
  buildGoModule,
  fetchFromGitHub,
  installShellFiles,
}:

buildGoModule rec {
  pname = "paimos-cli";
  # VERSION file at pinned rev + short sha so `paimos --version` is unambiguous
  # for unreleased builds.
  version = "2.1.22";

  src = fetchFromGitHub {
    owner = "markus-barta";
    repo = "paimos";
    rev = "a1423f33016b55232b7e8ee630ce0f6181fed9e3";
    hash = "sha256-MGZMXqkjlEH9QL85c8NH7+GKMyPuCjbUnH60tsr90gQ=";
  };

  # The repo is a polyglot monorepo; the Go module lives under backend/,
  # and we only want the CLI, not the server or paimos-mcp.
  modRoot = "backend";
  subPackages = [ "cmd/paimos" ];

  # tree-sitter (cgo) deps ship C sources (parser.c, api.h) that `go mod vendor`
  # strips from the vendor tree — proxyVendor preserves the full module zips
  # from the Go proxy, so cgo can find the headers.
  proxyVendor = true;
  vendorHash = "sha256-KLvqgjf/GVHV8Ysb/kQkv+P3kDkyrzD8q/+N2hwWjbc=";

  # Upstream CI runs `go test ./...` on every push; re-running inside the
  # Nix sandbox adds latency without catching anything new, and some tests
  # may assume a writable HOME / loopback network. Keep the package build
  # fast and hermetic.
  doCheck = false;

  ldflags = [
    "-s"
    "-w"
    "-X main.Version=${version}"
  ];

  nativeBuildInputs = [ installShellFiles ];

  # Cobra ships a `completion` subcommand automatically. The root has no
  # PersistentPreRun, so `paimos completion <shell>` runs without touching
  # the filesystem or network — safe in the sandbox.
  postInstall = ''
    installShellCompletion --cmd paimos \
      --bash <($out/bin/paimos completion bash) \
      --fish <($out/bin/paimos completion fish) \
      --zsh  <($out/bin/paimos completion zsh)
  '';

  meta = {
    description = "Agent-facing CLI for PAIMOS (Professional & Personal AI Project OS)";
    homepage = "https://github.com/markus-barta/paimos";
    changelog = "https://github.com/markus-barta/paimos/blob/main/docs/CHANGELOG.md";
    license = lib.licenses.agpl3Plus;
    mainProgram = "paimos";
    platforms = lib.platforms.unix;
  };
}
