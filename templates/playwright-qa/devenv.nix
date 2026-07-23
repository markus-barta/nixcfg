# ─────────────────────────────────────────────────────────────────────────
# Reusable devenv snippet: declarative headless-browser QA (Playwright)
# Origin: nixcfg NIX-288. Copy this entire directory into any repo whose agents
# need headless browser screenshots / Playwright smoke tests across macOS AND
# Linux shells.
#
# WHY THIS SHAPE: nixpkgs#chromium is Linux-only — it fails to *evaluate* on
# aarch64-darwin. So on macOS we drive native Google Chrome (installed
# declaratively via the `google-chrome` Homebrew cask — see nixcfg
# macos-common.nix → chromiumAppPath) through Playwright's `executablePath`.
# (Chrome is signed+notarized so it passes macOS Gatekeeper; the unsigned FOSS
# `chromium` cask does NOT — it's flagged "damaged" and won't launch.) On Linux
# we use pkgs.chromium directly. Either way PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
# stops `npm i playwright` from fetching a ~150 MB browser bundle — the system
# browser is the single source of truth.
#
# AUTOMATION LAYER: the npm `playwright` package (pinned in package.json) is
# the stable API. We deliberately do NOT add pkgs.playwright-driver here: it
# would only version-skew against the npm package, and the browser it manages
# is exactly the system Chromium we already point at. `npm install` is cheap
# because the skip-download flag means no browser bytes are fetched.
#
# APPLY:  direnv allow            # loads this devenv
#         npm install            # installs playwright JS API (no browser dl)
#         node screenshot.mjs https://www.hausv.org/ out.png
#
# TARGET POLICY: screenshot.mjs accepts only http(s) origins listed in the
# source-controlled target-policy.mjs allowlist. Update that allowlist when
# copying the template for another service; never make it a CLI/env override.
# ─────────────────────────────────────────────────────────────────────────
{ pkgs, lib, ... }:

let
  isDarwin = pkgs.stdenv.isDarwin;

  # macOS: binary inside the `google-chrome` cask. Keep in sync with
  # nixcfg → modules/uzumaki/macos-common.nix → chromiumAppPath.
  darwinChromium = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  # Linux: nixpkgs chromium (evaluates fine off-Darwin).
  linuxChromium = lib.getExe pkgs.chromium;
in
{
  packages = [
    pkgs.nodejs
  ]
  # Linux ships the browser via Nix; Darwin gets it from the cask (above).
  ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.chromium ];

  env = {
    # Never let `npm i playwright` download bundled browsers — use the system one.
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
    # Stable, declarative browser path the screenshot script reads.
    PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH = if isDarwin then darwinChromium else linuxChromium;
  };

  enterShell = ''
    echo "🎭 playwright-qa · PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=$PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH"
  '';
}
