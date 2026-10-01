# StaSysMo v2 tests

These are real assertions using private temporary HOME, snapshot, git and proc
fixtures. They do not depend on or modify a live daemon.

From the repository root:

```sh
nix-shell tests/stasysmo-shell.nix --run 'bash modules/uzumaki/stasysmo/tests/run-all.sh'
```

The shared implementation is `tests/stasysmo_test.py`, launched by
`tests/T91-stasysmo.sh`; CI uses the pinned shell on Linux. Native macOS checks
run on a real Mac outside the agent sandbox.

| Entry               | Assertions                                                                                             |
| ------------------- | ------------------------------------------------------------------------------------------------------ |
| T00-platform.sh     | Declarative platform/service/template wiring                                                           |
| T01-daemon.sh       | Native C compilation, real Mach sample, atomic writes, mode and clamp                                  |
| T02-output-files.sh | Linux proc fixture, bounds, atomic generations, clamp, child count and failure preservation            |
| T03-reader.sh       | Valid/stale/future/malformed records; missing, symlink and FIFO; zero metric commands                  |
| T04-width.sh        | Controlling-PTY layouts at all eleven widths, monotonic removals and pyte arrow backgrounds            |
| T05-starship.sh     | Layout plus kill switch, error fallback, missing Starship, SSH, pressure, hostile PTY and glyph widths |

`run-all.sh` runs each assertion once, using unittest counters. A Darwin API
permission denial is explicitly skipped locally; an unexpected API failure fails.
Linux skips the three Darwin tests. A run outside the pinned Nix shell also skips
the generated-init gate unless `--rendered-init-json` is supplied. Missing Python dependencies
fail at startup; the pinned shell supplies pyte and wcwidth.
The layout suite also covers real Starship emacs/vi keymaps, batched widths 5–160,
zero-padding widths, non-repo paths, `//` timeouts, dumb terminals, fish escaping
and a delayed PTY prompt. Native tests cover cache deletion/replacement and
injected CPU count/load rounding bounds. OPS supplies the evaluated
`tests/stasysmo-init-eval.nix` JSON with T91's `--rendered-init-json` for the full
Nix/fish and interval validation gate; the pinned shell supplies it automatically.

`host-check.sh` is a separate read-only deployment check used by the three host
suites. It examines `/run/stasysmo/snapshot` and installed fish definitions.
The portable fixture tests never invoke it.
