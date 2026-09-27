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

The Home Manager `paimos-agentd` service passes `--codex-accounts` to
`${config.home.homeDirectory}/Library/Application Support/paimos/agentd/codex-accounts.json`
on this host (PAI-955 / NIX-437). The file stays owner-only outside the Nix
store; do not copy registry homes or emails into Nix.

### Cursor agentd (NIX-439 — config candidate, review pending)

Home Manager also declares `--cursor-path` and `--cursor-accounts` for the
pinned native CLI — since NIX-514 the Nix package `pkgs/cursor-agent` (bumped by
`just update-ai-clis`), the same store path the `cursor-agent`/`agent` guard
shims and Pi's `CURSOR_AGENT_PATH` run — and the owner-only registry at
`~/Library/Application Support/paimos/agentd/cursor-accounts.json`. Nix carries
paths only — no email, userid, or registry contents.

Composer and Grok are selected through owned account/profile choices in that
registry, not through Nix. Cursor same-turn text steer remains unsupported;
inbox `nextturn`, `cancel`, and `stop` are available. Authentication stays in
the vendor store; agentd does not wrap or copy auth directories.

The flake now pins `v26.09.08`, whose agentd accepts `--cursor-path` /
`--cursor-accounts`. **This slice is a config candidate only — not live on the
host yet.** Root still creates the actual owner-only registry mapping separately
before review, merge, switch, and enrollment.

### Aeon agentd (NIX-583 — enrollment and activation pending)

`uzumaki.aeon.agentd` is a separate, **disabled** LaunchAgent candidate:
`at.inspr.aeon-agentd`, using `aeon-agentd` from the reviewed
`v260927120613.0.0` source `28fe3d3c5d4cc1f3e0da2e311a7a15fc505a7eff`.
The classic package, label, registry, journal and children remain independent.
This input also versions the Aeon CLI; its compatibility checks run during the
package build. There is no daemon `version` command: use the derivation/store
identity and locked source as provenance.

The proposed opaque daemon ID is declared in `home.nix`; it must be bound
explicitly to the dedicated Aeon agent principal and approved account UUID/key.
The proposed workspace is the physical `~/Code` directory. Only the pinned
Cursor adapter is selected initially; other vendor adapters require explicit
Nix store paths and enrollment. Codex additionally requires the existing browser
refusal guard. Native non-Codex launchers use the shared NIX-578 policy.

Enrollment files live in `~/Library/Application Support/aeon/agentd/`:
`agent.key` (raw dedicated Aeon agent key) and `accounts.json` (Aeon's registry,
with `accounts` entries containing `harness`, `key`, `account_id` and the
approved vendor `home` or `identity` as applicable). The directory must be
owner-owned mode 0700; both files must be regular, owner-owned, single-link
mode 0600. Keep all contents outside Nix, the store and tickets. Do not reuse
classic registries or the shared CLI consumer key; do not copy vendor auth.
The generic consumer-key materializer writes 0400 and is intentionally unused.

State and logs use only `~/Library/Application Support/aeon/agentd/state`
(0700, logs 0600), outside the OS cache-cleanup area. The workspace cannot
contain enrollment files or daemon state.
Activation checks metadata before the Home Manager write boundary, without
reading either enrollment file. It rejects symlinks, unsafe owners/modes and
classic paths, and never repairs an unsafe existing file. The daemon validates
registry/key contents itself. At least one explicitly reviewed
`estimates.requests`, `estimates.tokens` or `estimates.cost-micros` must be
positive before enabling. These are per-run reservation estimates, not account
allowance windows; the candidate intentionally leaves all three at zero.

The enrollment permission matrix below was derived from that exact release's
`internal/auth/module.go`, `internal/authz/route_map.go` and `internal/agentd/api.go`.
It is a review input, **not evidence of a live enrollment test**.

| Runtime routes                                    | Outer key ceiling                        | Narrow role permission / additional gate                                     |
| ------------------------------------------------- | ---------------------------------------- | ---------------------------------------------------------------------------- |
| GET `/api/me`                                     | self identity, any valid key             | self-agent route                                                             |
| GET `/api/models`, nodes and node lookup          | `models.read`, `nodes.read`              | corresponding read permissions and project visibility                        |
| GET work order; POST evidence                     | `work_orders.read`, `work_orders.write`  | scoped work-order permissions / run binding                                  |
| GET queued/run; POST claim/telemetry              | `run.read`, `run.claim`, `run.telemetry` | assigned run or live person-approved claim; reservation and exact generation |
| GET inbox; POST ack/send                          | `inbox.read`, `inbox.send`               | recipient/sender identity                                                    |
| POST harness registration                         | `harness.write`                          | project, run and worker identity binding                                     |
| POST heartbeat/yield/drain/complete-delivery/stop | `harness.worker`                         | exact worker lease and generation                                            |
| POST harness control completion                   | `harness.control`                        | **only `harness.worker` RBAC**, exact worker lease                           |
| POST account route/probe                          | `account.manage`                         | **only `account.route` / `account.probe` RBAC**, exact owner/daemon/account  |

`account.manage` and `harness.control` in the last two rows are release-specific
outer-key ceiling names. They do not justify management/control RBAC. Do not
grant administrator/wildcard roles, account registration/window management,
`run.create`, approval grants, or human force-stop/recovery authority. Optional
tools (comments, criterion changes, approval requests) need separate approval.
The key ceiling `work_orders.write` covers evidence, status updates and criterion
checks together; only scoped role RBAC can further restrict those operations.
Comments additionally need the outer `nodes.write` ceiling and `comments.write`
RBAC; approval requests need `approvals.request`, never approval-grant authority.
Before activation, exercise allowed and denied routes with the actual enrolled
principal. If the narrow combination fails, record an AEON prerequisite; never
broaden roles to make polling work.

Activation remains a separate supervised gate: retain the current HM generation
and classic executable/PID/label baseline, review the generated activation diff,
and enable only this new label after enrollment review. Use a newly approved
disposable managed session to verify its run binding, ownership age below 45 s,
daemon generation and root process/group identity. An authorized person must
see `force_stop_available` in recovery preview; the agent must receive 403 for
force/recovery. Let the session exit naturally. Do not force-stop an existing
worker or claim ownership of classic/unmanaged registrations.

Rollback after owned work drains disables only the Aeon service (or restores
its reviewed package/config); preserve its audit/state and the previous HM
generation. Never blanket-kill process names, stop classic, revoke its key, or
wipe state. Active runs require a supervised handoff before rollback.
AEON-228/231 retain final runtime recovery acceptance; OPS-231 retains classic
retirement. NIX-528 remains the pending configuration-version adoption proposal;
this candidate retains Git/HM generation identity and the dependency's calendar
version.

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
Home Manager owns `models.json` for cloud model overrides only. The MTPLX
provider discovers the app's actual endpoint and model instead of hardcoded
port 8000.

For cloud coding through a **ChatGPT subscription**, run `pi-chatgpt` or
`pi-chatgpt --continue` from the same repository. It shares the Pi profile,
sessions and doctrine loader with `pi-local`, but does not start or query MTPLX.
Its default is `openai-codex/gpt-5.6-terra` with low reasoning effort; additional
CLI options pass through, so `--model gpt-5.6-sol --thinking medium` overrides
those defaults. ChatGPT owns model availability and subscription limits.

GPT-6 Astra has a declarative **750,000-token context budget** in this shared
profile, overriding Pi's built-in 272,000-token default only for
`openai-codex/gpt-6-astra`. Automatic compaction remains enabled by Pi's default;
its standard 16,384-token reserve triggers compaction around 733,616 tokens.
Other models and the app's local context setting are unchanged. This is Pi's
client budget, not a change to the provider's server limit. After installing an
override, restart the conversation with
`pi-chatgpt --continue --model gpt-6-astra` to pick up the new model metadata.
To roll back this budget, remove the Astra override and switch Home Manager.

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
