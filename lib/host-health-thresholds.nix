# NIX-281 — declared host health thresholds.
#
# One source of truth for "when is a host elevated / critical". StaSysMo's
# metric table (modules/uzumaki/stasysmo/config.nix) is that source: the
# status bar in Markus's terminal and the HostDash/Pharos dashboards must not
# be able to disagree about what "hot" means, so this library derives the
# declared thresholds from the very same attrset rather than restating them.
#
# Classes exist because an interactive machine and a server are not the same
# animal: a workstation spikes to 100% CPU because someone hit build, and
# macOS pre-swaps aggressively by design. StaSysMo already encodes that second
# distinction (metrics.swap.thresholds.{linux,darwin}); the workstation class
# reuses it instead of inventing a second opinion.
#
# Consumed by modules/hostdash-manifest.nix, which emits the result into the
# nixcfg-owned `inspr.hostdash.config.v1` manifest. HostDash reads that
# manifest directly; pharosd reads the same artifact via PHAROS_MANIFEST_PATHS
# (NIX-286), so both consumers see identical numbers by construction.
{
  stasysmo,
  class,
  overrides ? { },
}:

let
  fail = message: throw "NIX-281 host health thresholds: ${message}";

  metricNames = [
    "cpu"
    "ram"
    "disk"
    "load"
    "swap"
  ];

  knownClasses = [
    "server"
    "workstation"
  ];

  requireClass =
    value:
    if builtins.isString value && builtins.elem value knownClasses then
      value
    else
      fail "class must be one of ${builtins.concatStringsSep ", " knownClasses}";

  requireNumber =
    label: value:
    if (builtins.isInt value || builtins.isFloat value) && value >= 0 && value <= 1000 then
      value
    else
      fail "${label} must be a number within [0, 1000]";

  # A band is only meaningful if it is ordered. An inverted or flat pair would
  # silently paint every host critical (or never), which is exactly the kind of
  # false signal this ticket exists to remove.
  requireBand =
    label: band:
    let
      elevated = requireNumber "${label}.elevated" (band.elevated or null);
      critical = requireNumber "${label}.critical" (band.critical or null);
    in
    if elevated < critical then
      {
        inherit elevated critical;
      }
    else
      fail "${label}.elevated must be strictly below ${label}.critical";

  metricsTable = stasysmo.metrics or (fail "StaSysMo config exposes no metrics table");

  metricNode = name: metricsTable.${name} or (fail "StaSysMo metrics table has no ${name} entry");

  # swap is the one metric StaSysMo splits by platform. Servers are Linux;
  # workstations are Markus's Macs, where pre-swapping is normal and the
  # stricter Linux band would cry wolf.
  swapBandFor =
    platform:
    let
      table = (metricNode "swap").thresholds or (fail "StaSysMo swap metric has no thresholds");
    in
    table.${platform} or (fail "StaSysMo swap thresholds have no ${platform} profile");

  # Workstations tolerate transient load: a build pegs every core by design.
  # The multiplier is applied to StaSysMo's server band rather than hardcoding
  # a second set of numbers, so a future StaSysMo tune propagates to both.
  #
  # Rounding is not cosmetic. Nix multiplies in binary floating point, so
  # 90 * 1.1 evaluates to 99.00000000000001; publishing that into a manifest
  # two dashboards render would put visible float noise on screen and make
  # byte-comparison of generated artifacts useless. StaSysMo already declares
  # each metric's type, so an int metric stays an int.
  relax =
    name: factor: band:
    let
      metricType = (metricNode name).type or "int";
      round = value: if metricType == "int" then builtins.floor (value + 0.5) else value;
      scale =
        value:
        let
          scaled = value * factor;
        in
        round (if scaled > 100 then 100 else scaled);
    in
    {
      elevated = scale band.elevated;
      critical = scale band.critical;
    };

  baseBand = name: (metricNode name).thresholds;

  classMetrics =
    c:
    if c == "server" then
      {
        cpu = baseBand "cpu";
        ram = baseBand "ram";
        disk = baseBand "disk";
        load = baseBand "load";
        swap = swapBandFor "linux";
      }
    else
      {
        cpu = relax "cpu" 1.2 (baseBand "cpu");
        ram = relax "ram" 1.1 (baseBand "ram");
        # A full root filesystem is equally dangerous on a workstation. Keep
        # the StaSysMo band verbatim rather than relaxing away write safety.
        disk = baseBand "disk";
        load = baseBand "load";
        swap = swapBandFor "darwin";
      };

  requireKnownOverrides =
    value:
    let
      unknown = builtins.filter (n: !(builtins.elem n metricNames)) (builtins.attrNames value);
    in
    if !(builtins.isAttrs value) then
      fail "overrides must be an attribute set"
    else if unknown != [ ] then
      fail "overrides name unknown metrics: ${builtins.concatStringsSep ", " unknown}"
    else
      value;

  resolvedClass = requireClass class;
  checkedOverrides = requireKnownOverrides overrides;
  defaults = classMetrics resolvedClass;

  merged = builtins.listToAttrs (
    map (name: {
      inherit name;
      value = requireBand name (defaults.${name} // (checkedOverrides.${name} or { }));
    }) metricNames
  );

  result = {
    schema = "inspr.hostdash.health-thresholds.v1";
    version = 1;
    class = resolvedClass;
    source = "stasysmo";
    metrics = builtins.mapAttrs (
      name: band:
      band
      // {
        suffix = (metricNode name).suffix;
        priority = (metricNode name).priority;
      }
    ) merged;
  };
in
# Force the whole document. A malformed class, an inverted band or an unknown
# override must fail the NixOS evaluation rather than ship a half-trustworthy
# threshold set to two dashboards.
builtins.deepSeq result result
