# mbp2607 — MacBook Pro (Markus)

| Fact         | Value                                                             |
| ------------ | ----------------------------------------------------------------- |
| Commissioned | 2026-07 (first host on the YYMM scheme — see PPM KB below)        |
| Hardware     | Apple Silicon MacBook Pro (high-RAM successor to mbp0)            |
| User         | `markus` (first non-`mba` host; `mba` retired for new machines)   |
| Config       | Home Manager only: `home-manager switch --flake .#markus@mbp2607` |
| Theme        | teal (`theme-palettes.nix`)                                       |
| Network      | DHCP for now; fixed IP planned via hsb0 DHCP reservation          |

## Provenance

Fresh start by design — **no key material or config carried over from mbp0**.
Items get pulled from mbp0 individually when actually missed, never wholesale.

- Naming scheme: PPM Knowledge `NIX / guideline / host-naming-scheme`
- Commissioning ticket + provisioning log: **NIX-215** (epic NIX-214)

## State of workstation modules

`inspr.secrets.agents`, `inspr.paimos-cli`, and `inspr.git.atelier.personal`
are **on** since 2026-07-03 (host keys registered as agenix recipients,
`mbp2607-personal-userkey` minted — NIX-215). `atelier.bytepoets` stays off
permanently (former-work history). `inspr.paimos-cli` manages non-secret routing
only; authentication is an interactive OS-keyring login.

## Local coding with Pi

Run `pi-local` from the repository or subdirectory you want to work in. It starts
MTPLX when needed, waits for readiness, and runs Pi in that directory and terminal.
Pi arguments pass through, for example `pi-local --continue`. Exiting Pi leaves the
shared model server available; stop the engine in MTPLX to release its memory.

The declarative configuration is in `pi-local.nix`: Qwen 3.8 27B Optimized Speed,
native MTP D2, 262,144 context tokens and up to 32,768 output tokens. Cold starts
use Turbo, medium reasoning and Smart fans. Compatible servers already started
by the app are reused, retaining their current performance/fan settings. A wrong
model, context or MTP setting produces an error instead of restarting another
session. Set the matching values in the app, or stop its engine and retry.

Prerequisites: MTPLX's app/runtime and CLI shim at `~/.mtplx/bin/mtplx`, and the
downloaded model under `~/.mtplx/models/`. Nix does not download the 21 GB weights
or manage the app. Pi itself is installed by the shared `ai-clis-npm` module.
The [MTPLX Pi integration](https://mtplx.com/docs/pi/) uses the same localhost
endpoint and model ID. This launcher uses foreground Pi instead of MTPLX's
`start pi`, which opens another Terminal window.

Pi's local profile lives in `~/.local/share/pi-local/agent/`; ordinary Pi settings
remain independent. Nix owns `models.json`; Pi owns sessions, trust decisions and
interactive settings. Defaults are supplied by the launcher, and startup network
checks are disabled with `--offline`. Server startup logs live at
`~/.local/state/pi-local/server.log`.

Pi normally chooses one `AGENTS.md` or `CLAUDE.md` per ancestor directory. The
local extension additionally expands standalone Markdown `@imports` from the
neighboring `CLAUDE.md`, in order, with cycle/duplicate protection. Thus an OPS
checkout supplies its INSPR kernel, private operator doctrine and SYSOP pack;
another repository supplies its own context. No OPS files or private doctrine
are bundled into the Nix store or injected into unrelated repos. Imports must
stay inside their repository, including symlink targets. `AGENTS.override.md`
retains precedence. Missing or invalid imports report an error and block tools
until the referenced files are restored. This loads instructions; it does not
add the approval UI, sandbox or delegated reviewers of another coding harness.

Validation: `python3 tests/test_pi_local.py` and
`node --test tests/pi-local-context.test.mjs`, then build/switch the native
`markus@mbp2607` Home Manager configuration. To roll back, revert `pi-local.nix`
and its host import and switch again; MTPLX's app setting is separately editable.

## Keyboard & input tools (2026-07-04, NIX-215)

- **Karabiner-Elements**: app via Brewfile baseline (`just bundle`); JSON
  config Nix-managed fleet-wide (`modules/config/karabiner.json` →
  `~/.config/karabiner/`). Input Monitoring granted manually.
- **BetterTouchTool**: cask in `extraCasks`; settings + license are **not**
  Nix-managed. One-shot migration from mbp0 (2026-07-04): rsync of
  `~/Library/Application Support/BetterTouchTool/` (incl.
  `bettertouchtool.bttlicense`) + `defaults export/import` of the prefs
  domain. Changes since then live only in BTT's own data store.
- **SSH identity**: `~/.ssh/id_ed25519` (`markus@mbp2607`, in ssh-keyring
  `personalHosts`; 1Password backup "mbp2607 id_ed25519"). Distinct from the
  atelier `mbp2607-personal-userkey` (git only) — deliberate separation.
