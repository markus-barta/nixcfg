{
  description = "Local stub for pbek/nixhostforge — INSPR / FleetCom already cover this; we don't want the upstream pulled into the closure.";
  outputs = _: {
    # Declares services.nixhostforge as a free-form attrset option so pbek's
    # hokage module (modules/hokage/nixhostforge.nix) can still reference it
    # inside its `config = lib.mkIf cfg.enable { services.nixhostforge = {...}; }`
    # without the module system throwing "option does not exist". The mkIf
    # condition is false by default — nothing ever reads this attrset, so the
    # actual upstream service code never enters the closure.
    nixosModules.default =
      { lib, ... }:
      {
        options.services.nixhostforge = lib.mkOption {
          type = lib.types.attrs;
          default = { };
          description = "Stub — accepts any attrs, no consumer.";
        };
      };
  };
}
