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

`inspr.secrets.agents` and `inspr.git.atelier.personal` are **on** since
2026-07-03 (host keys registered as agenix recipients,
`mbp2607-personal-userkey` minted — NIX-215). `atelier.bytepoets` stays off
permanently (former-work history). Classic `inspr.paimos-cli` was retired
(NIX-584); `paimos` is the Aeon client (`uzumaki.aeon.cli`, paimosAlias
default on). `at.inspr.aeon-agentd` is the owned-session daemon.

### Aeon agentd (NIX-583)

**Since 2026-09-30, disabled on mbp2607**: agentd runs from the Homebrew tap
(`brew install inspr-at/tap/aeon-agentd`, paired with `aeon-agentd pair`,
LaunchAgent `cm.aeon.agentd`); the Aeon CLI stays in Nix. The module below
remains available as a fallback.

`uzumaki.aeon.agentd` is a separate LaunchAgent (when enabled):
`at.inspr.aeon-agentd`, using `aeon-agentd` from the signed release asset pinned
in `pkgs/aeon-agentd-signed` (same tag as the `aeon` input, currently
`v261120104759.0.0`).
The classic package, label, registry, journal and children were retired in NIX-584.
This input also versions the Aeon CLI; its compatibility checks run during the
package build. There is no daemon `version` command: use the derivation/store
identity and locked source as provenance.

The stable opaque daemon ID is declared in `home.nix` and enrolled with the
dedicated Aeon agent principal and exact account UUID/key pairs.
The workspace is the physical `~/Code` directory. Pinned Cursor and Codex
adapters are selected initially. The daemon uses
Nixpkgs Codex 0.154.0 independently of the interactive npm CLI; both authenticate
through the existing approved vendor context, without copying authentication.
Grok and Claude enrollment is deferred to the next operator-directed rollout.
Codex requires the existing browser refusal guard. Native non-Codex launchers
use the shared NIX-578 policy.

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
allowance windows. Markus approved one short acceptance run per account on
2026-09-27: `estimates.requests = 1` reserves one request for each run. The
required one-run windows must expire after that verification; they are an
operator cap, not a claim about vendor subscription limits. Account registration
and the private registry are complete, but no allowance window has been created.
The window endpoint requires a person (`agentaccounts.Module.requirePermission`);
an agent setup key cannot create one. The daemon can publish sign-in probes
without a window, but dispatch and the acceptance runs wait for that prerequisite.

The enrollment permission matrix below was derived from that exact release's
`internal/auth/module.go`, `internal/authz/{require,route_map}.go` and
`internal/agentd/api.go`.
It is a review input, **not evidence of a live enrollment test**.

| Runtime routes                                    | Required key scope and role permission   | Additional gate                                                              |
| ------------------------------------------------- | ---------------------------------------- | ---------------------------------------------------------------------------- |
| GET `/api/me`                                     | self identity, any valid key             | self-agent route                                                             |
| GET `/api/models`, nodes and node lookup          | `models.read`, `nodes.read`              | project visibility                                                           |
| GET work order; POST evidence                     | `work_orders.read`, `work_orders.write`  | project scope / run binding                                                  |
| GET queued/run; POST claim/telemetry              | `run.read`, `run.claim`, `run.telemetry` | assigned run or live person-approved claim; reservation and exact generation |
| GET inbox; POST ack/send                          | `inbox.read`, `inbox.send`               | recipient/sender identity                                                    |
| POST harness registration                         | `harness.write`                          | project, run and worker identity binding                                     |
| POST heartbeat/yield/drain/complete-delivery/stop | `harness.worker`                         | exact worker lease and generation                                            |
| POST harness control completion                   | `harness.worker`                         | exact worker lease                                                           |
| POST account route/probe                          | `account.route`, `account.probe`         | exact owner/daemon/account                                                   |

`coreAgentScope` labels account routes `account.manage` and control completion
`harness.control`, but the middleware uses these labels only to allowlist routes
(except `/api/me`). `authz.RequirePattern` and `permitEffective` enforce the
exact route permission in **both** key scopes and role grants. Those legacy
labels are not extra key scopes to grant. Do not grant administrator/wildcard
roles, account registration/window management, `run.create`, approval grants,
or human force-stop/recovery authority.
`work_orders.write` covers creating work orders, general work-order updates,
evidence and criterion checks in both authorization layers. Resource and handler
restrictions still apply, but an evidence-only grant cannot be expressed with
that permission. Optional comments require
`comments.write`; approval requests require `approvals.request`. Neither is
needed for the minimal polling worker, and neither grants approval authority.
The person creating the key must also hold every requested permission: effective
agent grants are intersected with the key creator's grants. Re-derive this matrix
whenever the Aeon pin changes; legacy scope-label comments are not the contract.
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

### Nix garbage collection (NIX-603)

mbp2607 is standalone Home Manager (no nix-darwin), so the daemon-side
`min-free`/`max-free` cannot be declared here, and nothing collected the store
until 2026-10-01 (362 GB on disk, 85% dead paths). `uzumaki.nixGc.enable`
(`modules/uzumaki/nix-gc.nix`, enabled in `home.nix`) installs two user launchd
agents: `nix-gc` (Sunday 04:00, all dead paths) and `nix-gc-lowspace` (every
30 min, only below 100 GiB free, capped at 60 GiB per run). Dead paths only: no
generation is deleted. Log: `~/Library/Logs/nix-gc.log`.

- Status: `launchctl list | grep nix-gc`. Run now:
  `launchctl kickstart gui/$(id -u)/org.nix-community.home.nix-gc`.
- Pause: `launchctl bootout gui/$(id -u)/org.nix-community.home.nix-gc` (and
  `...nix-gc-lowspace`). A `home-manager switch` re-loads them, so set
  `uzumaki.nixGc.enable = false` to keep them off.
- Never copy a store-linked binary out of the store: on 2026-10-01 a copied
  `aeon` CLI lost `libresolv` after a collection. Link it with
  `nix build -o <link>` (an indirect GC root) instead.
- Enable it for one user per Mac only; the store is shared by every account.

## night-levels (OPS-595)

Home Manager runs the OPS-300 `night-levels.sh` loop every 180 s as
`org.nix-community.home.night-levels`, with KeepAlive. Its two helpers come
from the Nix store. The loop writes mbp2606's remote policy and run budget;
`/Users/markus/.aeon/lead/aeon/host-level.sh`, `HOST-LEVEL` and
`HOST-LEVEL.heartbeat` belong to LEAD and stay outside nixcfg.

From OPS-602, mbp2606's policy is maxload 28 every day and blocks only on RED.
The `WEEKEND-MODE` file is no longer read; MAC-LEAD retires it after the switch.

Logs and state are under `~/.local/share/ops-qa/state/`: the loop keeps using
`brake-night-levels.log`, and the five-minute
`night-levels-stale` agent uses `night-levels-stale.log` and
`night-levels-stale.state` (`ok` or `stale`). It sends mac-lead one alert when
the heartbeat is missing, malformed or over 900 s old, and one on recovery.
On the transition to stale it logs the alert, attempts one launchd kickstart,
logs its exit code and includes the attempt in the alert. It does not retry
while still stale. mbp2606's guard fallback on a stale policy is **maxload 12,
maxruns 1, level UNKNOWN**.

Cut over in this order on mbp2607:

1. Before switching, find any old loop with these read-only checks; do not
   trust the pidfile:

   ```sh
   pgrep -fl '[o]ps-qa/night-levels.sh'
   ps -p "$(cat ~/.local/share/ops-qa/state/brake-night-levels.pid 2>/dev/null)" -o command= 2>/dev/null
   ```

   Retire the old start paths before the switch. This is MAC-LEAD's or OPS's
   step outside nixcfg, tracked on OPS-595: rename
   `~/.local/share/ops-qa/night-levels.sh` to `night-levels.sh.retired-ops595`,
   and remove `night-levels` from `brake-mode.sh`'s default `names=`. A running
   old loop keeps its open file, so renaming is safe while it runs. After the
   rename, `brake-mode.sh on night-levels` still prints "started pid N", but
   the job exits 127; the error goes to `brake-night-levels.log`, and the
   pidfile then holds a dead PID. Never use it.

2. Inspect each candidate with `ps -p <pid> -o pid=,ppid=,command=`. Stop only
   a PID whose full command line is exactly
   `/bin/bash /Users/markus/.local/share/ops-qa/night-levels.sh` (or
   `bash /Users/markus/.local/share/ops-qa/night-levels.sh`) **and whose PPID
   is 1**: the nohup loop was reparented. Use `kill <pid>` only after both
   checks. Never stop editors, pagers, grep, or a shell that merely mentions
   the path. The bash loop has no children worth keeping. Never run
   `brake-mode.sh off night-levels` against a stale pidfile: on 2026-11-16 it
   still held a PID from 2026-11-03, and a reused PID would be killed.
3. Remove the stale pidfile with
   `trash ~/.local/share/ops-qa/state/brake-night-levels.pid`. A bare
   `brake-mode.sh off` is safe only after this step. MAC-LEAD or OPS must also
   switch `brake-mode.sh`'s `status`/`wake` liveness check to the launchd label.
   `~/.local/share/ops-qa/host-health.sh` around line 62 reads the pidfile and
   must switch to the launchd label too. These changes are outside nixcfg,
   tracked on OPS-595.
4. Run the Home Manager switch.
5. Verify all three conditions:

   ```sh
   ps -axo pid,ppid,command | awk '$2==1 && /[n]ight-levels.sh/'
   launchctl print gui/$(id -u)/org.nix-community.home.night-levels
   ```

   Count only loop processes with PPID 1: the first command must show exactly
   one, with the `/nix/store` script path. Its PID must equal the `pid =` line
   of `launchctl print`, which must show the job running. Command-substitution
   subshells briefly show extra PIDs with the same command line; they are not
   additional loops and must not be killed. Finally, the `epoch=` value in
   `~/.aeon/lead/aeon/HOST-LEVEL.heartbeat` must change within 4 minutes
   (one cycle is 180 s plus ssh time).

`brake-mode.sh status`, `wake` and the pidfile no longer reflect this loop.
The only liveness signals are the launchd job and the heartbeat epoch.
`brake-mode.sh on night-levels` must no longer be used. A duplicate loop is
harmful: it shares tmp files, halves the swapout delta and causes HOST-LEVEL
flapping. Its heartbeat also hides the launchd agent's death from the watcher.

Stop the loop with
`launchctl bootout gui/$(id -u)/org.nix-community.home.night-levels`.
To stop its watcher too, use
`launchctl bootout gui/$(id -u)/org.nix-community.home.night-levels-stale`.
`launchctl bootout` stops an agent only until the next Home Manager switch or
login. Logout, or a reboot without login, stops both agents; mbp2606's guard
fallback is the only protection then.

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

## On-demand Linux CI VM (OPS-669)

`ci-vm.nix` declares `services.ciVm`, enabled here for `inspr-at/hausnetz`.
Each `repositories.<id>` has `repository`, `runnerName` and `labels` options;
it gets Unix user `ci-<id>` and systemd unit `ci-runner-<id>.service` in the VM.
Changing an existing enrollment's repository, name or labels requires
coordinator-led re-enrollment; already configured runners skip the token read.
The hausnetz identity is `mbp2607-hausnetz`. Its workflow selector is:

```yaml
runs-on: [self-hosted, Linux, ARM64, mbp2607, hausnetz, kvm]
```

The hausnetz owner must also change explicitly selected `checks.x86_64-linux.*`
to `checks.aarch64-linux.*`. That repository's workflows are maintained there.

Only Colima profile `ci` is managed. It uses VZ, nested virtualization,
**6 vCPUs, 16 GiB RAM and one 150 GiB disk** (`runtime: none`, no container
engine). Nix stores and runner workspaces live inside that disk. The only
host mount is `~/.local/state/ci-vm/secrets`, mode 0700, mounted read-only at
`/etc/ci-vm-secrets`; `/Users/markus` is not shared. SSH-agent forwarding,
Docker/Kubernetes context activation, Rosetta and application port forwarding
are disabled. The starter copies the declared config into
`~/.config/colima/ci/colima.yaml` before each stopped start; Colima may rewrite this
regular writable file. An existing profile without `.nixcfg-ci-vm` is refused.
The module explicitly sets `COLIMA_HOME` to `${config.xdg.configHome}/colima`
and `LIMA_HOME` to `$COLIMA_HOME/_lima` for the command, dispatcher and QoS
helper. With this host's XDG configuration, `ci` lives alongside the other
profiles in `~/.config/colima`; the dispatcher refuses missing or mismatched
homes before calling Colima or creating directories. The QoS pidfile is
`$COLIMA_HOME/_lima/colima-ci/ha.pid`.

Every boot verifies the pinned Nix 2.31.2 installer archive and Actions runner
2.338.2 archive against the SHA256 literals in `ci-vm.nix`. Nix enables flakes
and `nixos-test benchmark big-parallel kvm`, with two build jobs and three
cores per build. `/dev/kvm` is 0666, as on NixOS, so sandboxed `nixbld*`
users can open it without supplementary groups. Nix starts garbage collection
below 5 GiB free and targets 10 GiB free (`min-free`/`max-free`).
The runner has automatic updates disabled so upgrades require a reviewed pin
and digest update. Keep that pin current with GitHub's runner update deadlines.

The runner executes the archive's `bin/runsvc.sh` with `Type=exec`. Its unit
uses `NoNewPrivileges`, a read-only system with its runner directory writable,
`ProtectHome`, `PrivateTmp`, `RestrictSUIDSGID`, and limits of 4 GiB / 2048 tasks.
The Nix daemon and its builds have separate limits of 10 GiB / 4096 tasks and
low CPU/I/O weights, leaving room for sshd and the guest agent. Guest nftables
blocks the `ci-*` and `nixbld*` UIDs from Lima's Mac-localhost alias
`192.168.5.2` (`host.lima.internal`); the DNS forwarder at `.3` remains usable.
Provisioning waits for Ubuntu DNS and bounds apt operations with retries.

The launchd agent `org.nix-community.home.ci-vm-dispatcher` polls every 60 s.
It sources the workstation agent token **only in a request subshell**, removes
its export attribute, and passes the curl authorization header on stdin; curl
never inherits `GH_TOKEN`. The scan has a 45-second API budget. Queued jobs
must match every offered label (case-insensitive); in-progress jobs count only
when `runner_name` is this runner. Matching demand starts `ci`. Idle shutdown
requires 20 minutes without demand or a local `Runner.Worker`. Before stopping,
the guest freezes listeners, checks again for a worker, and drains idle units.

API/auth/response failures and a missing token use a bounded, API-free guest
worker check. They stop `ci` after 20 minutes without a verified worker, with
an absolute 60-minute cap on continuous unknown state even if a worker remains.
Queued-only demand that picks up no job for 10 minutes stops `ci`, logs
`UNSERVABLE` and backs off. Startup, provisioning and readiness failures persist
exponential backoff in `~/.local/state/ci-vm/backoff` (60 seconds to one hour);
unservable queues start at five minutes. An existing `.runner` whose name has
disappeared from GitHub requires coordinator-led re-enrollment and backs off
for one hour. Known demand in another repo can still be served when an API
fails. Backward clocks and missing/corrupt timestamps begin a new grace period.
Colima status/start/SSH/stop and QoS checks all have process-group deadlines.
The dispatcher lock remains in a parent process so detached Lima daemons cannot
inherit it. Logs: `~/.local/share/ops-qa/state/ci-vm-dispatcher.log`.

The agent uses `ProcessType=Background`, low-priority I/O, and
`taskpolicy -b -c background` for the starter. `host.py` verifies the ci
hostagent's PID, owner and executable, finds its Virtualization XPC service
in **that PID's launchd domain**, and requires that service to hold **that
instance's disk** open. It applies `taskpolicy -b -p` only to those two PIDs
and verifies Darwin's background flags with `proc_pidinfo`. Failure stops
`ci`. Background QoS lets macOS favor efficiency cores; it is a scheduler
policy, not a hard CPU-affinity mask. Runner services also use `Nice=10`,
`CPUWeight=10` and `IOWeight=10` inside the VM.

Colima can say READY after a failed provision, so a successful provision must
write the current Linux boot ID to `/var/lib/ci-vm/ready`. After verifying QoS,
the host calls the declared `host-ready` helper, which checks that boot ID,
opens a gate in `/run`, and starts the repo services. Registration and jobs
cannot start before that gate. Each service must pass `systemctl is-active`;
a condition-skipped or failed service is not ready. The helper reports known
deleted-registration diagnostics as "needs re-enrollment". Activation installs the agent and directories;
it never starts a VM directly. Login with an empty queue leaves `ci` stopped.

### Coordinator-only enrollment

The builder never mints a token or registers a runner. After review, activate
the Home Manager generation through the normal operator path. With `ci`
stopped, run this **once** in Bash. It makes one POST, saves the complete JSON
response outside the mount as a 0600 file, prints only its expiry and filename,
and atomically publishes the one-shot token as `secrets/hausnetz.token` (0600).
No token goes into argv or the Nix store. If a token file already exists, this
command refuses to replace it; retire an expired token explicitly first.

```bash
(
  set +x
  set -euo pipefail
  umask 077
  set +a
  unset GH_TOKEN
  source "$HOME/.inspr/secrets/agents/GH_TOKEN.env"
  [ -n "${GH_TOKEN:-}" ]
  set +a
  export -n GH_TOKEN
  ci_state="$HOME/.local/state/ci-vm"
  install -d -m 0700 "$ci_state" "$ci_state/secrets"
  [ ! -e "$ci_state/secrets/hausnetz.token" ]
  [ ! -L "$ci_state/secrets/hausnetz.token" ]
  ci_response=$(mktemp "$ci_state/hausnetz-registration.XXXXXXXX")
  chmod 0600 "$ci_response"
  printf 'header = "Authorization: Bearer %s"\n' "$GH_TOKEN" |
    curl -q --config - --request POST --fail --silent --show-error \
      --max-time 30 --proto '=https' \
      --header 'Accept: application/vnd.github+json' \
      --header 'X-GitHub-Api-Version: 2022-11-28' \
      --output "$ci_response" \
      https://api.github.com/repos/inspr-at/hausnetz/actions/runners/registration-token
  unset GH_TOKEN
  jq -er '.expires_at | select(type == "string" and length > 0)' "$ci_response"
  ci_token_stage=$(mktemp "$ci_state/secrets/.hausnetz.token.XXXXXXXX")
  jq -er '.token | select(type == "string" and length > 0)' "$ci_response" >"$ci_token_stage"
  chmod 0600 "$ci_token_stage"
  mv "$ci_token_stage" "$ci_state/secrets/hausnetz.token"
  printf 'registration response retained at %s\n' "$ci_response"
)
```

Then run `ci-vm start` before the printed expiry. The root pre-start helper
reads that token only if `.runner` is absent, then runs `config.sh` as the
dedicated user with `ACTIONS_RUNNER_INPUT_URL`, `_TOKEN`, `_NAME`, `_LABELS`,
`_UNATTENDED`, `_REPLACE` and `_DISABLEUPDATE`. This mechanism was checked
against [the pinned runner's CommandSettings.cs](https://github.com/actions/runner/blob/v2.338.2/src/Runner.Listener/CommandSettings.cs)
(constructor, `GetArg`, `TestFlag`); the constructor registers TOKEN with its
secret masker and removes the input environment variables. The exchanged
runner credentials remain in the guest's private runner directory; the
registration token is never copied there.
Enrollment also refuses to proceed if a negative read test shows that the
runner user can read the mounted token.
The pinned runner's `env.sh` persists PATH and an explicit build-environment
allowlist; it does not persist any `ACTIONS_RUNNER_INPUT_*` variable.

Verify without printing credentials:

```bash
colima --profile ci ssh -- sudo systemctl is-active ci-runner-hausnetz.service
colima --profile ci ssh -- sudo -u ci-hausnetz test -f /var/lib/ci-runners/hausnetz/.runner
```

The host automatically uses `trash` on the mounted one-shot token once `.runner`
exists, including when a later service start fails. Confirm the runner name and
six labels in GitHub, then use `trash` on the retained response file. Enrollment persists across
boots; an already configured runner never rereads the registration token.
Switch hausnetz workflows in its owning repository, verify a green Mac run,
and retire the old agm2 runner in that repository's separate lane.

Operation: `ci-vm`/`ci-vm tick` performs one poll; `ci-vm start` and `ci-vm stop`
are explicit operator overrides. `ci-vm start --provision-only` boots and checks
provisioning/QoS/firewall without opening the runner activation gate, for
pre-enrollment inspection. `ci-vm prepare` only refreshes a stopped profile's
config. To disable automatic dispatch, set `services.ciVm.enable =
false` through the reviewed Home Manager path and stop `ci` when its jobs
finish. Keep the VM disk/enrollment for rollback. No other profile is managed.

Offline tests (Bash 5 is required by the test's false-pass guard):

```bash
nix-shell -p bash jq python3 coreutils --run 'bash tests/ci-vm-dispatcher-test.sh'
```

The test evaluates the actual module, executes guest helpers and the rendered
service start path in filesystem fixtures, and checks demand, pagination,
uptime caps, backoff, token retirement, deadlines and daemon-lock isolation.
Mutants cover labels, timing, the runner path, nixbld KVM access, token isolation,
archive verification and the Colima home. CI runs it in
`.github/workflows/check.yml`. Live proof additionally requires the real cached
archive, `systemd-analyze verify`/`security`, a sandboxed KVM derivation, and a
Mac-loopback positive control alongside denied CI/nixbld connections and working
guest DNS. It does not require a registration token.
