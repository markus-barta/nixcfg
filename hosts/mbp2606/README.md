# mbp2606

Private Apple Silicon M5 Max MacBook Pro. Renamed from `mbp0` on 2026-08-07
(NIX-216) when it was handed to Mailina; the name follows the YYMM
commission-month scheme and is immutable thereafter.

Provisioned 2026-06-15 from the retired work host's config and key material
(June 2026 employer exit), so agenix access continues intentionally. It is not
a former-work work host.

## Users

Two Home Manager users share this machine. HM standalone is per-user, so each
account has its own `$HOME`, profile and generations, and neither can clobber
the other.

| user      | role                    | config               | flake output                                           |
| --------- | ----------------------- | -------------------- | ------------------------------------------------------ |
| `mailina` | primary (Mailina Barta) | `./home-mailina.nix` | `homeConfigurations."mailina@mbp2606"`                 |
| `mba`     | backup/admin (Markus)   | `./home.nix`         | `homeConfigurations."mba@mbp2606"` (alias `"mbp2606"`) |

`home-mailina.nix` deliberately omits `modules/shared/markus-defaults.nix` and
`ssh-fleet.nix` — Markus's identity, agent-secret roots and fleet SSH matrix
are not hers.

### One shared resource: Homebrew

`/opt/homebrew` and `/Applications` are machine-wide, not per-user, and the
prefix is owned by `mba`. `just bundle` is additive and safe from either
account. **`just bundle-cleanup` is not** — it uninstalls every cask absent
from the _invoking_ user's Brewfile, so running it from either account removes
the other user's apps. Do not run it on this host (NIX-216).

Homebrew is single-user by design: `mailina` cannot complete cask installs
(the prefix and existing Caskroom entries are `mba`-owned, mode 755). Cask
work runs from the `mba` account.

## Profile

- Architecture: `aarch64-darwin`
- Theme: `lightGray` — per-HOST, so both users see the same machine colour
  (palette entry in `modules/uzumaki/theme/theme-palettes.nix`)
- Agent secrets root: `secrets/agents/host/mbp2606`

`agent-secrets` selects host secrets with `agents/host/${hostname}/`, so this
directory MUST track the hostname. It was missed during the 2026-08-07 rename
and sat at `mbp0` for a day — nothing matched, and the next `home-manager
switch` dropped `GH_TOKEN.env`, `ONSHAPE.env` and `m5-personal-userkey.env` as
orphans, which is what broke `gh auth` on the host. Renaming the directory and
its keys in `secrets/secrets.nix` restores them; recipients are unchanged, so
no re-encryption is involved. The `m5-*` filename and the `root@mbp0` /
`mba@mbp0` key comments are retained by intent — a key comment is not key
material, and rewriting it would force a pointless rekey.

## Notes

- `inspr.git.atelier.personal` is **disabled** since NIX-216 (m5 userkey
  retired 2026-07; remotes rewritten to HTTPS).
- `inspr.git.atelier.bytepoets` (former work context) is disabled for this
  private machine.
- The `m5-*` key names are retained because the material was deliberately
  carried forward.
- Nix garbage collection (NIX-603): the store is shared by every account on
  this Mac, so exactly one account collects it. `ci` runs the weekly (Sunday
  04:00, all dead paths) and low-space (below 100 GiB free) user launchd
  agents of `uzumaki.nixGc` (`home-ci.nix`); `mba` and `mailina` deliberately
  do not. It has to be `ci`: user agents only load in a graphical session, `ci`
  owns the console session, and `mba` has none (agents installed there fail
  with `Bootstrap failed: 125`). Operate and pause as `ci` (log
  `/Users/ci/Library/Logs/nix-gc.log`); the rule for store-linked binaries is
  in `hosts/mbp2607/README.md`. If `ci` is ever logged out, no collection runs.

## CI runner pool: main ruleset pin (OPS-264)

The pool serves `push`, `workflow_dispatch`, same-repository `pull_request`,
and `merge_group` runs of the allowlisted workflows in `inspr-at/paimos`.
Push and dispatch still require `main` and a SHA reachable from it; PR and
merge-queue runs may use their own branches and SHAs. Forks remain rejected.
Jobs request `[self-hosted, Linux, ARM64, mbp2606, <class>]`, with exactly one
class: `mbp2606-push`, `mbp2606-dispatch`, `mbp2606-pr`, or `mbp2606-mq`,
respectively. Only pushes write the persistent cache; other events use a
disposable clone. The pool has four slots of four CPUs and 6 GiB each, leaving
host RAM for remote-test.

The `ci` user's `aeon-builder` pool deliberately fails closed when paimos's
main ruleset differs from `modules/aeon-builder/paimos-main-ruleset.json`,
including tightenings and merge-queue tuning. CI falls back to hosted runners
automatically while the pool is unavailable.

After an intentional ruleset change, regenerate the five pinned keys from the
live ruleset, from the nixcfg checkout (Bash):

```bash
set -o pipefail
gh api repos/inspr-at/paimos/rulesets/24240960 \
  | jq -S '{enforcement, target, conditions, bypass_actors, rules}' \
  > modules/aeon-builder/paimos-main-ruleset.json
```

Review the diff for weakening, run `python3 tests/test_aeon_builder.py -v`,
and ship the pin through nixcfg's normal review path. Deploy the `ci@mbp2606`
Home Manager generation, then run `aeon-builder on --resume` as `ci`.
The regression tests require the five checks (`go`, `web`, `release-check`,
`e2e`, `migration-compat`), PR protection, active enforcement and a merge queue.
The supplied live policy retains the existing role-5 PR-only bypass; tests
permit its removal but reject additional actors or broader bypass permissions.

## Inbound SSH (declarative)

Since 2026-07-04 (NIX-215) `~/.ssh/authorized_keys` is managed by
`inspr.ssh.authorized` (marker-block render; lines outside the block are
preserved but unmanaged — audit ticket exists for those). Trust preset:
`personalHosts` from `modules/shared/ssh-keyring.nix`. Admits
`markus@mbp2607` for the mbp2607 → mbp2606 workflow.

Applies to the `mba` account only.

## Apply

```bash
# Markus's account
nix run home-manager -- switch --flake ".#mba@mbp2606"

# Mailina's account
nix run home-manager -- switch --flake ".#mailina@mbp2606"
```

### First activation from a shared checkout (NIX-216)

The command above **fails on a first activation** when the flake checkout is
owned by another user — e.g. the shared `/Users/Shared/nixcfg`, owned by `mba`:

```
error: … while fetching the input 'git+file:///Users/Shared/nixcfg'
       repository path '…' is not owned by current user (libgit2 error code = 7)
```

`programs.git.extraConfig.safe.directory` in `home-mailina.nix` exists to fix
exactly this — but it is _delivered by_ the activation, so the activation
cannot read the flake in order to deliver it. Nix uses libgit2, which ignores
`GIT_CONFIG_GLOBAL` and reads global config from XDG. Break the loop by
building the activation package under a scoped `XDG_CONFIG_HOME`, then
activating with the real environment:

```bash
scratch=$(mktemp -d) && mkdir -p "$scratch/git"
printf '[safe]\n\tdirectory = /Users/Shared/nixcfg\n' > "$scratch/git/config"
out=$(XDG_CONFIG_HOME="$scratch" nix build --no-link --print-out-paths \
  '/Users/Shared/nixcfg#homeConfigurations."mailina@mbp2606".activationPackage')
"$out/activate"
```

One-time per user. Once the generation is live, `safe.directory` is in
`~/.config/git/config` and the plain `nix run home-manager` command works.

## Shared checkout permissions

`/Users/Shared/nixcfg` is owned by `mba` but used by both accounts. It is
group-`staff` and group-writable, with setgid on directories so new files
inherit the group, and `core.sharedRepository = group` so git itself creates
group-writable objects and refs. Without that last part, `.git/index` and
`.git/FETCH_HEAD` stay mode 644 and the non-owning user cannot commit, fetch
or pull — only read.
