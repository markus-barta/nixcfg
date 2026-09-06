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

## Coding with Pi

Run `pi-local` from the repository or subdirectory you want to work in. Pi stays
in that directory and terminal; arguments such as `--continue` pass through.
The launcher connects to the **MTPLX app-owned engine**, discovering its current
port, model and context. It never starts `mtplx serve`, downloads a model, changes
fan settings or stops another process. App and Pi requests therefore appear in
one app dashboard. Exiting Pi leaves the app engine running.

When the app is closed, `pi-local` opens it and waits for its engine. Enable
**Start MTPLX when opening the app** in MTPLX for this one-command cold start.
If you explicitly stopped the engine while keeping the app open, press Start in
MTPLX; the launcher waits for readiness and reports a clear timeout after 120 s.
The installed app currently has no external start-engine command, so this case
requires its Start button. A separately launched CLI engine is rejected instead
of creating a second copy. The selected API must be localhost without API auth.

The app owns MTP/depth, profile, context, sampler, reasoning and thermal controls.
**Standard** uses Apple's automatic fan curve; no launcher code selects Smart or
Max. Current workstation setup: Qwen 3.8 27B Optimized Speed, MTP D2, 262,144
context, Standard fans. Pi's provider extension omits sampler/reasoning overrides,
so changes in the app apply on the next request. Use the app for those controls,
including reasoning; Pi's thinking selector is not an override in this profile.
Pi keeps a 16,384-token output budget for context management. Restart Pi after
changing the model, port or context so it discovers their new metadata.

The terminal footer shows **MTPLX · TPS · RAM** right-aligned above the model.
It polls the same app engine every two seconds, only in interactive Pi. TPS is
the current decode rate across the engine; prefill shows progress instead. Idle
and unreachable states never reuse a completed request's TPS. RAM is active MLX
allocation in GiB (weights, KV/session caches and working buffers), excluding
unused allocator cache and other Mac processes. Memory-pressure warnings use
the app's macOS pressure signal. No prompts or telemetry are logged or added to
the model context. Restart with `pi-local --continue` after installing this
extension; `/reload` refreshes it in sessions already launched with it.

`pi-local.nix` owns the launcher/extensions. MTPLX owns its app, runtime, settings
and downloaded weights. Pi itself comes from `ai-clis-npm`; its local sessions,
settings and trust decisions live in `~/.local/share/pi-local/agent/`. Ordinary Pi
configuration is separate. Startup network checks are disabled with `--offline`.
The old fixed `models.json` is removed by Home Manager: provider registration now
uses the app's actual endpoint and model instead of hardcoded port 8000.

For cloud coding through a **ChatGPT subscription**, run `pi-chatgpt` or
`pi-chatgpt --continue` from the same repository. It shares the Pi profile,
sessions and doctrine loader with `pi-local`, but does not start or query MTPLX.
Its default is `openai-codex/gpt-5.6-terra` with low reasoning effort; additional
CLI options pass through, so `--model gpt-5.6-sol --thinking medium` overrides
those defaults. ChatGPT owns model availability and subscription limits.

First-time authentication is Pi's `/login openai-codex` browser OAuth flow.
Credentials are stored and refreshed by Pi in its mutable profile `auth.json`,
never in Nix, Git, shell arguments or environment variables. No API key is
configured. To switch an existing local conversation to the cloud, use
`/model openai-codex/gpt-5.6-terra`; `/model mtplx/<app-model-id>` switches back
when that session was launched with `pi-local`. From a cloud-only launch,
resume with `pi-local --continue` to return to the app engine. Both launchers
preserve the calling directory. The cloud-only launch uses Pi's native footer.

The context extension expands standalone Markdown `@imports` from the selected
repository's neighboring `CLAUDE.md`. This loads the INSPR kernel and the repo's
own operator/domain packs, including SYSOP in OPS, with order, duplicate and
cycle protection. Imports must stay within their repository, including symlink
targets; `AGENTS.override.md` retains precedence. Missing/invalid imports block
tools. Private doctrine is read at runtime and never copied into the Nix store.
This loads instructions; it does not add another harness's sandbox or approval UI.

Validation: `python3 tests/test_pi_local.py` and
`node --test tests/pi-local-*.test.mjs`,
then build/switch the native `markus@mbp2607` Home Manager configuration. Verify
only one engine PID, app ownership, Apple fan mode and the app's counters/TPS
while Pi generates. To roll back, revert the launcher module and host import and
switch again; app preferences remain managed in MTPLX.

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
