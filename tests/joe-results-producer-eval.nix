# JOED-20: evaluate enabled/disabled service wiring with inert packages only.
{
  enable ? true,
  endpoint ? "https://ingress.example.invalid/joe/inbox/results",
  ingressHost ? "ingress.example.invalid",
  ingressAddress ? "192.0.2.10",
  keepSymbols ? [
    "SXR8"
    "TSLA"
  ],
}:
let
  lib = import <nixpkgs/lib>;
  evaluated = lib.evalModules {
    specialArgs.pkgs = {
      runCommand =
        name: _: _:
        "/fixture/${name}";
      writeText = name: _: "/fixture/${name}";
      nodejs = "/fixture/nodejs";
      util-linux = "/fixture/util-linux";
    };
    modules = [
      ../modules/joe-results-producer/default.nix
      {
        options = {
          assertions = lib.mkOption {
            type = lib.types.listOf lib.types.attrs;
            default = [ ];
          };
          systemd.services = lib.mkOption {
            type = lib.types.attrs;
            default = { };
          };
          age.secrets = lib.mkOption {
            type = lib.types.attrs;
            default.joe-board-push-token.path = "/run/agenix/joe-board-push-token";
          };
          nixcfg.paperDeskExecutor = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            resultsCaptureEnabled = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
            resultsKeepSymbols = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
          };
        };
        config.nixcfg.joeResultsProducer = {
          inherit
            enable
            endpoint
            ingressHost
            ingressAddress
            keepSymbols
            ;
        };
      }
    ];
  };
  cfg = evaluated.config;
  failures = builtins.filter (item: !item.assertion) cfg.assertions;
in
assert lib.assertMsg (failures == [ ]) (lib.concatMapStringsSep "; " (item: item.message) failures);
{
  capture = cfg.nixcfg.paperDeskExecutor.resultsCaptureEnabled;
  captureKeep = cfg.nixcfg.paperDeskExecutor.resultsKeepSymbols;
  services = cfg.systemd.services;
}
