# OPS evaluates with the flake's pinned nixpkgs.lib, then passes the JSON to T91.
{ lib }:
let
  evaluate =
    config:
    (lib.evalModules {
      modules = [
        {
          options.services.stasysmo = import ../modules/uzumaki/stasysmo/options.nix {
            inherit lib;
            platform = "linux";
          };
          inherit config;
        }
      ];
    }).config.services.stasysmo;
  accepts =
    interval:
    (builtins.tryEval (
      builtins.deepSeq
        (evaluate {
          services.stasysmo.daemon.interval = interval;
        }).daemon.interval
        true
    )).success;
  defaults = evaluate { };
  expected = {
    STASYSMO_SNAPSHOT = "/fixture/quote'and\\";
    STASYSMO_ICONS = [
      "trailing\\"
      "single'quote"
      "both'\\"
      "literal$(echo data)"
    ];
    STASYSMO_SPACER_ICON_VALUE = "'\\";
    STASYSMO_SPACER_METRICS = "\\";
  };
  cfg = defaults // {
    icons = {
      cpu = builtins.elemAt expected.STASYSMO_ICONS 0;
      ram = builtins.elemAt expected.STASYSMO_ICONS 1;
      swap = builtins.elemAt expected.STASYSMO_ICONS 2;
      load = builtins.elemAt expected.STASYSMO_ICONS 3;
    };
    display = {
      spacerIconValue = expected.STASYSMO_SPACER_ICON_VALUE;
      spacerMetrics = expected.STASYSMO_SPACER_METRICS;
    };
  };
in
assert defaults.daemon.interval == 2000;
assert builtins.all accepts [
  500
  2000
  60000
];
assert builtins.all (interval: !accepts interval) [
  (-1)
  0
  499
  60001
  2000.5
  "2000"
];
{
  inherit expected;
  fishInit = import ../modules/uzumaki/stasysmo/fish-init.nix {
    inherit lib cfg;
    snapshot = expected.STASYSMO_SNAPSHOT;
  };
}
