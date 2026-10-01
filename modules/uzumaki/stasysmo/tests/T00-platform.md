# T00: StaSysMo platform wiring

Run the adjacent shell test using `nix-shell tests/stasysmo-shell.nix` from the
repository root. It checks systemd's owned `/run/stasysmo` runtime directory,
Darwin's per-user logs, launchd label/domain gate, compositor init order and
Starship's built-in git hash. It does not inspect a live daemon.

Real collector output is covered by T01/T02. See the existing tests README
for the portable, private-fixture runner and native API limitations.
