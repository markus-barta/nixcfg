# StaSysMo v2

A persistent sampler publishes a single snapshot. Fish reads it with builtins
and composes the first prompt line; Starship renders the left chain and input
character. Metrics spawn no processes. Bash and zsh get a clean left-only
Starship prompt. The feature remains opt-in through `uzumaki.stasysmo.enable`
or `services.stasysmo.enable`.

## Layout

`prompt.fish` loads after Starship, retains its original function for diagnostics,
and makes `fish_right_prompt` empty. Complete Starship profiles supply correctly
coloured powerline chains. The default profile contains no compositor delimiters,
clock, metrics or right rail.

The compositor measures `string length --visible`, including caps and separators,
and leaves one column spare. As space runs out, it removes clock, duration, load,
swap, RAM, CPU, nix-shell and sudo information, with the failure badge retained
longest. Elevated and critical metrics outlive healthy metrics. The configured
sudo symbol is empty, so there is no sudo query or visible sudo segment.

Once the rail is gone, complete profiles remove languages/docker, hash, local
user@host, jobs, git status, branch and OS icon, in that order. SSH retains
user@host. Only then does the directory lose leading components: `…/` marks a
component boundary, the repo root and final component are retained when they
fit, then the final component alone. A final name that cannot fit is ellipsised.
At an extreme SSH width where identity plus a directory cannot fit, identity
gets a separate bounded row. The directory is always present.

Profiles rerender only on overflow: the normal path makes one Starship call;
the most extreme widths can require ten. Each reduced profile has complete
caps/transitions, avoiding recolouring fragments of an already rendered chain.
`git_commit` replaces the shell-based hash, the root warning is fish-native, and
Starship's command timeout is back to 500 ms.

Disable composition for a session:

```fish
set -g STASYSMO_COMPOSER 0
```

Re-enable with `set -e STASYSMO_COMPOSER`. Runtime failures use the plain left-only
Starship prompt. An absent/failing Starship still leaves a builtin directory and
input prompt. `SYSOP_NOTE` is no longer inserted into the prompt.

## Snapshot and security

One record is published by a unique same-directory temporary file and atomic
rename, so a reader sees one complete generation:

```text
v1 <epoch_seconds> <cpu_percent> <ram_percent> <swap_percent> <loadavg1> <logical_cpus>
```

There is exactly one trailing newline. Percentages are integers 0–100; load has
two decimal places and is below 10000; CPU count is 1–9999. The reader bounds its
read to 129 characters and validates the entire record before arithmetic. It
rejects malformed records, controls, symlinks and nonregular files including
FIFOs. It never evaluates snapshot text and never writes to the sampler directory.
The reader uses Starship's existing time field for epoch/clock, avoiding a `date`
child on fish versions without `EPOCHSECONDS`. Custom icons/spacers enter the
fish configuration through shell quoting. External nix-shell text is bounded to
known states; no arbitrary note text is rendered.

| Platform | Snapshot                                 | Directory | File | Writer                       |
| -------- | ---------------------------------------- | --------- | ---- | ---------------------------- |
| macOS    | `$HOME/Library/Caches/stasysmo/snapshot` | 0700      | 0600 | That account's native helper |
| NixOS    | `/run/stasysmo/snapshot`                 | 0755      | 0644 | systemd DynamicUser service  |

Linux's record contains public host metrics and is readable by local prompt
accounts. A 0600 file owned by DynamicUser would be unreadable by those accounts.
The service directory is writable only by its owner. Darwin verifies the leaf
owner/mode with a no-follow directory descriptor and publishes with `openat` +
`renameat`. Existing unsafe directories are rejected rather than repaired.
This protects accounts from each other's snapshots; it does not treat the
owner of a fish configuration as an adversarial isolation boundary.

Missing or invalid data produces no metrics. A valid snapshot older than
`max(3 × effective interval, 15 seconds)` or in the future produces one muted `?`.
A sampler failure preserves the previous generation until it goes stale.

## Sampling and settings

Default interval: 2000 ms. `services.stasysmo.daemon.interval` accepts milliseconds
and both collectors clamp it to 500–60000 ms. Fractional waits never truncate to
zero. The first CPU value uses a 100 ms warm-up delta.

Darwin's persistent C helper uses Mach CPU tick deltas; RAM is
`max(internal − purgeable, 0) + wired + compressor` pages over `hw.memsize`.
Swap uses `vm.swapusage`, load uses `getloadavg`, and CPU count uses `sysconf`.
No sampling subprocesses, `ps`, `vm_stat` or `kern.cp_time` are involved. The
launchd label remains `com.stasysmo.daemon`, with KeepAlive and RunAtLoad. Logs
are per account under `$HOME/Library/Logs/stasysmo-daemon{,.error}.log`.
The established headless mba account on mbp2606 retains its StaSysMo opt-in but
gets no unloadable GUI launchd job. Other account opt-ins are unchanged.

Linux reads `/proc/stat`, `/proc/loadavg`, and `/proc/meminfo` once per tick for
both RAM and swap. RAM uses MemAvailable. Bash handles parsing, math and time.
It needs one `mv` child per tick because Bash has no rename builtin; a private
FIFO supplies builtin `read -t` waiting. `mkfifo` and `unlink` run only at startup.
The FIFO is unlinked immediately after opening. systemd's existing hardening
remains, with `RuntimeDirectory=stasysmo` replacing unused `sysmon` and `/dev/shm`.

| Metric                   | Elevated | Critical |
| ------------------------ | -------- | -------- |
| CPU                      | 50%      | 80%      |
| RAM                      | 70%      | 90%      |
| Load / logical CPU count | 0.7      | 1.0      |
| Swap, Linux              | 33%      | 66%      |
| Swap, Darwin             | 50%      | 75%      |

`services.stasysmo.metrics.*.thresholds`, icons, colours and spacers remain
configurable. `display.maxBudget`, `display.minTerminalWidth`, `display.terminalWidth`
and `display.staleThreshold` are removed: layout follows fit and staleness follows
interval. None of the current hosts overrides them. Disk thresholds remain
metadata for the existing HostDash health library; disk is not a prompt sample.
Its historical raw-load bands remain separate from the normalized prompt bands.

`stasysmo-reader` remains a thin safe compatibility command because the existing
`stasysmod` fish debug function calls it. It launches fish once, uses the same
validator/formatter, and is outside the prompt path. `stasysmod` remains usable.
The historical template is retained only for disabled hosts, whose generated
configuration must remain identical.

## Tests

From the repository root:

```sh
nix-shell tests/stasysmo-shell.nix --run 'bash tests/T91-stasysmo.sh'
nix-shell tests/stasysmo-shell.nix --run 'bash tests/T91-stasysmo.sh --benchmark'
```

The shell uses the hosts' `flake.lock` nixpkgs revision. `tests/stasysmo_test.py`
uses private HOME/cache/git/proc fixtures. The controlling-PTY + pyte test answers
fish's terminal queries and checks widths 150, 120, 100, 80, 74, 60, 50, 46, 40, 30,
24, monotonic removals, visible directory text, width limits, arrow cell colours,
glyph widths, SSH, pressure priority, hostile snapshots, kill switch and fallback.
Daemon tests check bounds, atomic generations, permissions, interval clamp,
failed samples and one Linux child per tick. Darwin compiles the helper with `cc`
and checks real samples when the APIs are available. A sandbox denial is reported
as a skip locally and fails the Darwin CI gate.

`.github/workflows/check.yml` runs the portable suite on Linux and a native sampler
job on macOS. `modules/uzumaki/stasysmo/tests/run-all.sh` runs the same assertions
once, without the former Bash counter abort. Host tests under
`hosts/{hsb0,hsb1,hsb8}/tests` perform read-only deployed-service checks; run those
only on the intended host after deployment. No automated fixture uses live
`/tmp/stasysmo`, `/dev/shm/stasysmo`, sudo or a remote host.
