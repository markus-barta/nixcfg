{
  description = "Local stub for pbek/nixhostforge — INSPR / FleetCom already cover this; we don't want the upstream pulled into the closure.";
  outputs = _: {
    nixosModules.default = { };
  };
}
