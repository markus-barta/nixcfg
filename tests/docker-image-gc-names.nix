# T115: compare guard 7's calculation with actual toplevel derivation names.
# Evaluate only; no Linux system build is required.
{ config }:
let
  rows =
    cfg:
    [
      {
        computed =
          (
            {
              name = "nixos-system-${cfg.system.name}-${cfg.system.nixos.label}";
            }
            // cfg.system.systemBuilderArgs
          ).name;
        actual = cfg.system.build.toplevel.name;
      }
    ]
    ++ builtins.concatLists (map (s: rows s.configuration) (builtins.attrValues cfg.specialisation));
  systems = rows config;
in
{
  inherit systems;
  namesHold = builtins.all (
    row: row.computed == row.actual && builtins.match "nixos-system-[^/]+" row.actual != null
  ) systems;
}
