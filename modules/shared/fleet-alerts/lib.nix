# Build a poller from the shared engine plus a host's check set — OPS-107.
#
# The engine (engine.py) owns durability: write-ahead delivery, atomic state,
# confirm-before-alert. The check set owns what is checked and how it reads. This
# joins them into one store path so `import engine` resolves without PYTHONPATH
# games at runtime.
#
# Substitutions are applied to the check file at BUILD time, so the built script
# holds literals and no runtime data flows into a request URL (the CodeQL
# partial-SSRF finding on the first ops-alerts revision, 2026-07-30). It also
# makes target changes a rebuild, which is the correct shape for fleet config.
{ pkgs, lib }:
{
  mkPoller =
    {
      name,
      checks,
      substitutions ? { },
    }:
    let
      keys = builtins.attrNames substitutions;
      rendered = builtins.replaceStrings (map (k: "@${k}@") keys) (map (k: substitutions.${k}) keys) (
        builtins.readFile checks
      );
      checksPy = pkgs.writeText "${name}-checks.py" rendered;
      assertion = lib.assertMsg (
        !lib.hasInfix "@TARGETS_JSON@" rendered
      ) "${name}: a substitution placeholder survived into the built poller";
    in
    assert assertion;
    pkgs.runCommand name { } ''
      mkdir -p "$out"
      cp ${./engine.py} "$out/engine.py"
      cp ${checksPy} "$out/checks.py"
    '';
}
