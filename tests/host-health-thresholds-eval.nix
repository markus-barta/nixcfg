# NIX-281 — pure evaluation harness for lib/host-health-thresholds.nix.
#
# Pure on purpose: nixosConfigurations cannot be evaluated from a dirty tree
# (NIX-348's evidence refuses a revisionless source), so the threshold library
# is proven here against synthetic inputs and the real StaSysMo table, while
# CI's clean-tree "Eval flake — all hosts" job covers the module integration.
let
  stasysmo = import ../modules/uzumaki/stasysmo/config.nix;
  mk = import ../lib/host-health-thresholds.nix;

  fails = value: !(builtins.tryEval (builtins.deepSeq value true)).success;

  server = mk {
    inherit stasysmo;
    class = "server";
  };
  workstation = mk {
    inherit stasysmo;
    class = "workstation";
  };
  overridden = mk {
    inherit stasysmo;
    class = "server";
    overrides = {
      cpu.critical = 95;
      ram = {
        elevated = 60;
        critical = 88;
      };
    };
  };

  isWholeNumber = value: builtins.isInt value;

  # The point of the library: the status bar and the dashboards must not be
  # able to disagree. Server bands are StaSysMo's numbers verbatim.
  serverMatchesStasysmo =
    server.metrics.cpu.elevated == stasysmo.metrics.cpu.thresholds.elevated
    && server.metrics.cpu.critical == stasysmo.metrics.cpu.thresholds.critical
    && server.metrics.ram.elevated == stasysmo.metrics.ram.thresholds.elevated
    && server.metrics.ram.critical == stasysmo.metrics.ram.thresholds.critical
    && server.metrics.load.elevated == stasysmo.metrics.load.thresholds.elevated
    && server.metrics.load.critical == stasysmo.metrics.load.thresholds.critical
    && server.metrics.swap.elevated == stasysmo.metrics.swap.thresholds.linux.elevated
    && server.metrics.swap.critical == stasysmo.metrics.swap.thresholds.linux.critical;

  workstationUsesDarwinSwap =
    workstation.metrics.swap.elevated == stasysmo.metrics.swap.thresholds.darwin.elevated
    && workstation.metrics.swap.critical == stasysmo.metrics.swap.thresholds.darwin.critical;

  workstationIsMoreTolerant =
    workstation.metrics.cpu.critical > server.metrics.cpu.critical
    && workstation.metrics.ram.critical > server.metrics.ram.critical;

  # Regression guard: 90 * 1.1 is 99.00000000000001 in binary floating point.
  # Int-typed metrics must stay whole numbers or the manifest ships float noise
  # to two dashboards and generated artifacts stop comparing byte-for-byte.
  intMetricsStayWhole =
    isWholeNumber workstation.metrics.cpu.elevated
    && isWholeNumber workstation.metrics.cpu.critical
    && isWholeNumber workstation.metrics.ram.elevated
    && isWholeNumber workstation.metrics.ram.critical
    && isWholeNumber workstation.metrics.swap.elevated
    && isWholeNumber workstation.metrics.swap.critical;

  everyBandOrdered =
    doc:
    builtins.all (name: doc.metrics.${name}.elevated < doc.metrics.${name}.critical) (
      builtins.attrNames doc.metrics
    );

  overridesApplyNarrowly =
    overridden.metrics.cpu.critical == 95
    # untouched bound keeps the class default
    && overridden.metrics.cpu.elevated == server.metrics.cpu.elevated
    && overridden.metrics.ram.elevated == 60
    && overridden.metrics.ram.critical == 88
    # untouched metric is entirely unaffected
    && overridden.metrics.load.critical == server.metrics.load.critical;
in
{
  inherit server workstation overridden;

  checks = {
    inherit
      serverMatchesStasysmo
      workstationUsesDarwinSwap
      workstationIsMoreTolerant
      intMetricsStayWhole
      overridesApplyNarrowly
      ;

    serverBandsOrdered = everyBandOrdered server;
    workstationBandsOrdered = everyBandOrdered workstation;
    overriddenBandsOrdered = everyBandOrdered overridden;

    rejectsUnknownClass = fails (mk {
      inherit stasysmo;
      class = "toaster";
    });
    rejectsUnknownMetric = fails (mk {
      inherit stasysmo;
      class = "server";
      overrides.disk.elevated = 10;
    });
    rejectsInvertedBand = fails (mk {
      inherit stasysmo;
      class = "server";
      overrides.cpu = {
        elevated = 90;
        critical = 10;
      };
    });
    rejectsEqualBand = fails (mk {
      inherit stasysmo;
      class = "server";
      overrides.cpu = {
        elevated = 80;
        critical = 80;
      };
    });
    rejectsOutOfRange = fails (mk {
      inherit stasysmo;
      class = "server";
      overrides.cpu.critical = 5000;
    });
    rejectsNegative = fails (mk {
      inherit stasysmo;
      class = "server";
      overrides.cpu.elevated = -1;
    });
    rejectsNonNumeric = fails (mk {
      inherit stasysmo;
      class = "server";
      overrides.ram.critical = "hot";
    });
    rejectsMissingMetricsTable = fails (mk {
      stasysmo = { };
      class = "server";
    });
  };
}
