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
# ── How the pin works ────────────────────────────────────────────────────────
# `src` is injected by flake.nix from `inputs.paimos` (a `flake = false` GitHub
# input tracking `main`). `nix flake update paimos` — or the scheduled
# `update-flake-lock` GitHub Action — bumps the rev+hash automatically.
#
# `vendorHash` still has to be refreshed manually when Go deps change, since
# buildGoModule can't infer it from flake.lock:
#   1. set `vendorHash = lib.fakeHash;`
#   2. `nix build .#paimos-cli`
#   3. copy the "got:" value back into `vendorHash`
#
{
  lib,
  buildGoModule,
  fetchurl,
  go_1_26,
  installShellFiles,
  src,
}:

let
  versionFromFile = lib.removeSuffix "\n" (builtins.readFile "${src}/VERSION");
  shortRev = src.shortRev or "dirty";
  # Paimos 5.20.1 requires Go 1.26.6 or newer. The repository's currently
  # pinned nixpkgs still carries 1.26.4, so keep the CLI package on the latest
  # 1.26 patch without moving the workstation's system-wide nixpkgs input.
  go1267 = go_1_26.overrideAttrs (_old: {
    version = "1.26.7";
    src = fetchurl {
      url = "https://go.dev/dl/go1.26.7.src.tar.gz";
      hash = "sha256-DtJOrHVRBQhbif6cq8J0K5GgrXuUtZ0602SRjryJVq0=";
    };
  });
  buildGo1267Module = buildGoModule.override { go = go1267; };
in
buildGo1267Module {
  pname = "paimos-cli";
  # VERSION file at pinned rev + short sha so `paimos --version` is unambiguous
  # for unreleased builds.
  version = "${versionFromFile}-${shortRev}";

  inherit src;

  # The repo is a polyglot monorepo; the Go module lives under backend/,
  # and we only want the CLI, not the server or paimos-mcp.
  modRoot = "backend";
  subPackages = [ "cmd/paimos" ];

  # tree-sitter (cgo) deps ship C sources (parser.c, api.h) that `go mod vendor`
  # strips from the vendor tree — proxyVendor preserves the full module zips
  # from the Go proxy, so cgo can find the headers.
  proxyVendor = true;
  vendorHash = "sha256-g7Q6pfUPXoZ3THZsQhnAA+F7JCR6T7rCwQBmXhXZzWc=";

  # Upstream CI runs `go test ./...` on every push; re-running inside the
  # Nix sandbox adds latency without catching anything new, and some tests
  # may assume a writable HOME / loopback network. Keep the package build
  # fast and hermetic.
  doCheck = false;

  ldflags = [
    "-s"
    "-w"
    "-X main.Version=${versionFromFile}-${shortRev}"
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
