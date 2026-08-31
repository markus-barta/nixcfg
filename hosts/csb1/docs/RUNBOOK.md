# Runbook: csb1 (Monitoring & Documentation Server)

**Host**: csb1 (cs1.barta.cm / 152.53.64.166)  
**Role**: Monitoring, Metrics & Documentation Platform  
**Criticality**: MEDIUM - Monitoring dashboards, document management  
**Provider**: Netcup VPS 1000 G11 (Vienna)

---

## Quick Connect

```bash
# Via alias
qc1

# Direct SSH
ssh mba@cs1.barta.cm -p 2222

# With IP
ssh mba@152.53.64.166 -p 2222
```

---

## Quick Reference Card

```
╔════════════════════════════════════════════════════════════╗
║ 🌀 csb1 - Monitoring & Docs Emergency Reference            ║
╠════════════════════════════════════════════════════════════╣
║ SSH:       ssh mba@cs1.barta.cm -p 2222                    ║
║ IP:        152.53.64.166                                   ║
║ Netcup:    Customer # 227044 (2FA required)                ║
║ VNC:       servercontrolpanel.de/SCP                       ║
╠════════════════════════════════════════════════════════════╣
║ 🌐 SERVICES                                                ║
║ • PAIMOS (PM): https://pm.barta.cm                         ║
║ • Paperless:   https://paperless.barta.cm                  ║
║ • Docmost:     https://docmost.barta.cm                    ║
║ • Excalidraw:  https://draw.barta.cm                       ║
╠════════════════════════════════════════════════════════════╣
║ ⚠️  CRITICAL DEPENDENCIES                                  ║
║ • Cleanup → Managed by csb0 (not here!)                    ║
╠════════════════════════════════════════════════════════════╣
║ 🚨 IF DOWN                                                 ║
║ 1. SSH check: ssh mba@cs1.barta.cm -p 2222                 ║
║ 2. VNC console via Netcup SCP (if SSH fails)               ║
║ 3. Restore from backup (< 2h)                              ║
╚════════════════════════════════════════════════════════════╝
```

---

## Health Checks

### Quick Status

```bash
# One-liner: container count, disk usage, load
ssh mba@cs1.barta.cm -p 2222 "docker ps | wc -l && df -h / | tail -1 && uptime"
# Expected: 16 containers, <50% disk, load <1.0

# Check container health
ssh mba@cs1.barta.cm -p 2222 "docker ps --filter 'status=exited'"
# Should be empty (all running)

# Check services responding
curl -I https://paperless.barta.cm  # Paperless (expect 200)
curl -I https://docmost.barta.cm  # Docmost (expect 200)
curl -I https://draw.barta.cm  # Excalidraw (expect 200)
```

---

## Common Tasks

### Update & Switch Configuration

```bash
ssh mba@cs1.barta.cm -p 2222
cd ~/nixcfg  # or ~/Code/nixcfg
git pull
just switch
```

### Rollback to Previous Generation

```bash
ssh mba@cs1.barta.cm -p 2222
sudo nixos-rebuild switch --rollback
```

---

## 🏗️ Uzumaki & Hokage Pattern

`csb1` is an **External Hokage Consumer**. It consumes the base server configuration from the global `hokage` module but applies local customizations via the `uzumaki` namespace.

- **Status**: Enabled (`uzumaki.enable = true`)
- **Role**: `server`
- **Indicator**: The `nixbit` command should be available and working.

---

## NixFleet Dashboard (DECOMMISSIONED)

NixFleet has been decommissioned (DSC26-53). Successor: **FleetCom** (DSC26-52).

The container is stopped and absent from the running stack (verified 2026-08-02).
Final teardown (residual files, `~/secrets/nixfleet.env` was removed with
NIX-118) is tracked in **OPS-61** — the compose spec
(`hosts/csb1/docker/compose-spec.nix`) is the sole source of truth; there is no
`~/docker/docker-compose.yml` anymore (OPS-127).

---

## Docker Services

### GitHub Actions Runner

csb1 runs a declarative GitHub Actions runner for `hausv-org` deployments via NixOS `services.github-runners`. The runner is configured in `hosts/csb1/hausv-github-runner.nix` and uses the existing GHCR token (`csb1-hausv-ghcr-pull`) for repo-scoped registration.

**Legacy tarball cleanup:** The previous tarball+patchelf+user-unit installation at `/home/mba/actions-runner` is leftover and should be removed after `just switch` applies the declarative configuration. The declarative runner takes over the same runner name (`csb1-hausv`) via the `replace = true` setting.

```bash
# Check runner status
systemctl status github-runner-csb1-hausv.service

# View runner logs
journalctl -u github-runner-csb1-hausv.service --since today
```

### All Containers (15 running)

| Container                   | Purpose                                                      |
| --------------------------- | ------------------------------------------------------------ |
| csb1-docmost-1              | Documentation wiki                                           |
| csb1-docmost-db-1           | PostgreSQL for Docmost                                       |
| csb1-docmost-redis-1        | Redis cache                                                  |
| csb1-paperless-1            | Document management                                          |
| csb1-paperless-db-1         | PostgreSQL for Paperless                                     |
| csb1-paperless-redis-1      | Redis                                                        |
| csb1-paperless-tika-1       | Document parsing                                             |
| csb1-paperless-gotenberg-1  | PDF conversion                                               |
| csb1-traefik-1              | Reverse proxy                                                |
| csb1-hostdash-1             | HostDash service dashboard                                   |
| csb1-docker-proxy-traefik-1 | Traefik proxy                                                |
| csb1-restic-cron-hetzner-1  | Backup (cleanup on csb0!)                                    |
| csb1-smtp-1                 | Mail relay                                                   |
| csb1-excalidraw-1           | Whiteboard (draw.barta.cm)                                   |
| ppm                         | PAIMOS PM (pm.barta.cm)                                      |
| minio                       | S3 for ppm attachments                                       |
| paimos-www                  | paimos.com static (caddy)                                    |
| inspr-www                   | inspr.at family edge (caddy: www/janus/paimos/pharos/v1)     |
| inspr-auth                  | OIDC session backend (inspr.at/{enter,login,welcome,logout}) |
| zitadel                     | 🔴 Identity provider (auth.inspr.at)                         |
| zitadel-postgres            | 🔴 IdP database (volume inspr-at_zitadel_postgres_data)      |

### Quick Commands

```bash
# View all containers
docker ps -a

# Restart a container
docker restart csb1-paperless-1

# View logs
docker logs --tail 100 <container>
```

🔴 There is NO `~/docker/docker-compose.yml` anymore (OPS-127) and there is
never a reason to `down` the whole csb1 project — that would stop every
service including Traefik, Janus and the IdP. Reconcile a single service:

```bash
sudo /nix/store/f5qch8f2b3hch9ar5nvvadxxgnssxz6c-docker-compose-5.3.1/bin/docker-compose \
  -p csb1 -f /etc/compose/csb1/docker-compose.yml \
  --project-directory /home/mba/Code/nixcfg/hosts/csb1/docker \
  up -d --no-deps <service>
```

(While OPS-136 staging has `reconcile = false`, this scoped command is also
the ONLY sanctioned substitute for the absent reconcile unit — restart
policies survive crashes, but a REMOVED container is not recreated until
PR-2 restores reconciliation.)

### OPS-136 — who owns the 5 (zitadel, zitadel-postgres, inspr-auth, inspr-www, paimos-www)

Identify the current phase by the compose project label:

```bash
for c in zitadel zitadel-postgres inspr-auth inspr-www paimos-www; do
  printf '%s\t%s\n' "$c" "$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || echo ABSENT)"
done
```

| Observed state (per service) | Meaning                      | Recovery command                                                                                                      |
| ---------------------------- | ---------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `inspr-at` / `paimos`        | legacy phase (pre-cutover)   | `ops136/rollback.sh` semantics: legacy compose files + pinned overrides                                               |
| `csb1`                       | adopted phase (post-cutover) | scoped `up -d --no-deps <svc>` against the rendered file (above)                                                      |
| `ABSENT`                     | removed, not recreated       | start under the CURRENT owner phase only — never both                                                                 |
| mixed across the 5           | interrupted transition       | 🔴 postgres first; run `ops136/rollback.sh` OR finish the cutover — never leave two postgres candidates able to start |

🔴 Invariant: at most ONE container may ever reference volume
`inspr-at_zitadel_postgres_data` (`docker ps -a --filter volume=inspr-at_zitadel_postgres_data`).

### NIX-384 — private GHCR images (inspr-auth)

`inspr-auth` is pinned from the **private** package
`ghcr.io/inspr-at/inspr-site/inspr-auth` (INSPR-253). The root-run
`compose-csb1` and `compose-csb1-update` units log in to ghcr.io in their
`ExecStartPre` with `composeStack.registryLogins` (token: agenix
`csb1-inspr-site-ghcr-pull`, classic PAT `read:packages`, 1Password
`ghcr.pull.inspr-at/inspr-site`). The login lives in
`/run/compose-csb1[-update]-docker-auth` (tmpfs, 0700) and is removed after
the unit's work; `/root/.docker` stays untouched. `mba`'s own docker login is
irrelevant to the units. Diagnose a pull denial with
`journalctl -u compose-csb1 | grep -iE 'login|denied|unauthorized'`; a revoked
or expired token shows up as the reconcile failing, never as a silent skip.
All OPS-136 commands run as root under the campaign flock
(`/run/lock/compose-csb1.lock`); the scripts in
`hosts/csb1/docker/ops136/` take it themselves. Campaign evidence + journal:
`/root/ops136-backups/`. Disaster recovery from image archives:
`ops136/dr-image-id.override.yml` (read its STEP 0 first).

### Janus Staged Engine Smoke

The `janus-engine-staged` compose profile stays disabled and non-Traefik. Its
non-prod smoke uses the signed digest-pinned engine image, Docker-volume
non-prod age material, a non-prod metadata overlay, and a permit-bound
`janusd-use run` launched through the staged compose service; no production secret
or host SSH key is used.
The staged image pin in `hosts/csb1/docker/compose-spec.nix` is the source of
truth; do not duplicate its release or digest here. (`just janus-engine-up`
uses the rendered /etc closure file since NIX-361; NIX-338 is closed.)

```bash
cd ~/Code/nixcfg
just janus-engine-pin-check
just janus-engine-smoke
```

Expected evidence:

```text
value_returned=false output=suppressed permit_consumed=true
```

`just janus-engine-pin-check` is read-only and also runs in GitHub Actions on a
daily schedule plus relevant pin/workflow changes.

To keep a staged Rust engine instance running internally after the smoke:

```bash
just janus-engine-up
just janus-engine-status
```

The running container is profile-gated, networkless (`network_mode: none`), not
on Traefik, and still uses only the non-prod smoke volumes. It is an MCP stdio
process with a Docker healthcheck, not the public `vault.barta.cm` route. Stop
it with `just janus-engine-down`.

To prove a local MCP client path into the running staged container:

```bash
just janus-engine-mcp-smoke
```

This uses `docker exec -i janus-engine-staged janus-warden` over MCP stdio and
checks `initialize`, `tools/list`, `health`, and `list_secrets` without exposing
values or adding a network listener.

To prove the negative side of that boundary:

```bash
just janus-engine-mcp-negative-smoke
```

This uses the same local MCP stdio path and verifies that raw resolve/reveal
tools are not advertised, raw `JANUS_SMOKE` names are denied, caller-supplied
destination/executor/TTL overrides are denied, and no negative response exposes
a value or permit id.

To prove the approved-use execution boundary rejects bad permits:

```bash
just janus-engine-run-negative-smoke
```

This issues real non-prod permits through Warden, then uses `janusd-use run` to
verify malformed and unknown permit ids, consumed permit reuse, wrong executor,
wrong destination, expired permit metadata, and unreviewed command args all
fail without secret-bearing command output.

To run the current staged engine assurance gate:

```bash
just janus-engine-assurance
```

This primes the non-prod smoke state once, keeps `janus-engine-staged` running,
then runs the current value-free boundary matrix:

| Boundary                        | Evidence                                                                                                           |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Permit-bound positive execution | `janus-engine-smoke` proves one reviewed `request_use` + `janusd-use run` path, suppressed output, consumed permit |
| Local MCP client path           | `mcp-exec-smoke.sh` proves `initialize`, exact `tools/list`, `health`, and `list_secrets` stay value-free          |
| MCP default-deny boundary       | `mcp-negative-smoke.sh` proves raw resolve/reveal, raw names, and caller policy overrides are denied               |
| Approved-use execution boundary | `run-negative-smoke.sh` proves malformed, unknown, reused, wrong-bound, expired, and unreviewed permits fail       |

### Janus Production Role Authorization

The continuously running staged engine and every production Pharos credential
or lifecycle subprocess use `JANUS_ROLE_AUTHORIZATION_MODE=enforced`.
Their different scopes have separate private durable registries under
`/var/lib/janus-role-authorization-csb1/{staged,production}`. NixOS owns the
directories, binding registries, and value-free audit files at modes
`0700`/`0600`; do not edit their contents by hand. Each posture keeps role-admin
decisions in `audit.jsonl` and the potentially long-running Warden sink in
`warden-audit.jsonl`. The split preserves each hash chain's exclusive writer
while keeping status and renewal available. One-off non-production renderer
fixtures remain isolated and explicitly unsafe.

After deploying a release that adds the first-binding bootstrap, initialize an
empty production registry exactly once:

```bash
cd ~/Code/nixcfg
just janus-role-bootstrap
just janus-role-status
```

The first command bootstraps each empty scope separately. Each requires the
explicit one-shot acknowledgement internally, mints a 15-minute
`unsafe_bootstrap` `security_admin`, switches to a reviewed admin, revokes the
bootstrap grant, and proves an unbound actor is denied. Production receives
six reviewed one-year bindings under `NIX-345`; staged receives three. Expected
terminal evidence is:

```text
janus_role_bootstrap=ready posture=production source_reference=NIX-345 value_returned=false
janus_role_bootstrap=ready posture=staged source_reference=NIX-345 value_returned=false
```

`just janus-role-status` must then show one revoked `unsafe_bootstrap` row in
each scope, six active production `local_reviewed` rows, and three active staged
rows. Two reviewed security-admin identities per scope let each renew the other
without bypassing the self-grant rule. The command is value-free. If bootstrap
stops after the reviewed security-admin binding was written, do not empty the
registry or rerun it blindly: use that reviewed admin identity to finish the
remaining grants, then revoke the bootstrap binding.

Rollback is the reviewed previous engine pin plus the previous explicit
`unsafe_disabled_dev` production arguments. Keep the role directory intact
during rollback so evidence and reviewed bindings survive; the old posture
ignores them. Never remove binding state merely to make authorization pass.

### Pharos Janus Generation Cutover

Deploy a new Janus producer before restarting a Pharos release that consumes a
new sidecar schema. Janus keeps its complete output private. The production
renderer validates the immutable generation, copies only that value-free
generation into the dedicated Pharos projection, and atomically advances the
projection's `current` pointer. It then proves the projection is readable as
the exact non-root identity declared by the `pharosd` Compose service. Its
success output is value-free.

After the reviewed nixcfg change is merged and `just switch` has completed on
csb1, run the cutover in this order:

```bash
cd ~/Code/nixcfg
just janus-engine-pin-check
cd hosts/csb1/docker
docker compose pull pharosd pharos-beacon
cd ../../..
just janus-pharos-production-seed-projection
cd hosts/csb1/docker
docker compose up -d --no-deps --force-recreate pharosd
cd ../../..
just janus-pharos-production-render
cd hosts/csb1/docker
docker compose ps pharosd pharos-beacon
curl -fsS http://100.64.0.4:8088/healthz
```

The seed step is the no-downtime migration from the legacy shared-volume mount:
it copies the already-reviewed current generation into the isolated projection
without changing the private producer volume. On a new installation with no
existing generation, run the production render before starting `pharosd`.

Do not recreate `pharosd` if the production render fails. The existing
consumer projection and running Pharos container remain the rollback boundary.
If a recreated container fails its health check, restore the previous reviewed
image pins in Git, merge and pull that rollback, render with the matching Janus
profile, and recreate the two Pharos services again. Never edit the compose
file, private Janus output, or projected generation directly on csb1.

### Pharos Hetzner Provider Credential Handoff

Pharos consumes the Hetzner project token only from the isolated external
volume `janus_pharos_production_provider_out`. The agenix enrollment source is
root-only and is never mounted into `pharosd`; the reviewed importer extracts
the one expected key as data, re-encrypts it into the Janus age store, consumes
one provider-only permit with networking disabled, and restores the rendered
file to the exact non-root identity declared by `pharosd` with mode `0600`.
The provider volume and value-free hash projection are mounted independently;
`pharosd` never mounts Janus's private producer volume.

Enrollment is an attended human step. From the workstation, edit
`secrets/csb1-hetzner-cloud-provider-env.age` with agenix and enter exactly one
`PHAROS_HCLOUD_API_TOKEN=...` assignment. Never paste the value into a shell
argument, agent chat, PPM, Git plaintext, or command output. After the encrypted
artifact is reviewed and deployed with `just switch`, run on csb1:

```bash
cd ~/Code/nixcfg
sudo bash hosts/csb1/docker/janus/pharos-production/import-agenix-hetzner-provider.sh
cd hosts/csb1/docker
docker compose up -d --no-deps pharosd
```

Expected value-free evidence includes `value_returned=false`,
`hash_format=none`, `mode=600`, and `permits_consumed=true`. The one-time
`pharosd` recreation installs the isolated nested volume mount; later
credential re-renders are read per operation and need no restart.

Managed creation is activated only after the dedicated executor identity is
deployed root-only, its derived public key exactly matches the
`pharos-csb1-executor` key selected in the attended Hetzner project, and the
three reviewed gates agree:

- `inspr.pharosProvisioningExecutor.enable = true`
- `PHAROS_PROVISIONING_EXECUTOR_READY=1`
- `PHAROS_HCLOUD_EXECUTE=1`

Deploy the host executor before exposing managed creation in `pharosd`. From a
clean `main` checkout at the reviewed remote revision on csb1:

```bash
bash -c '
set -euo pipefail
cd ~/Code/nixcfg
pharos_container_before=$(docker inspect --format "{{.Id}}" pharosd)
just switch
pharos_container_after=$(docker inspect --format "{{.Id}}" pharosd)
if [ "$pharos_container_before" != "$pharos_container_after" ]; then
  printf "pharosd was unexpectedly recreated during just switch; stop here\n" >&2
  exit 1
fi
systemctl is-enabled pharos-provisioning-executor.timer
systemctl is-active pharos-provisioning-executor.timer
sudo systemctl start pharos-provisioning-executor.service
systemctl show pharos-provisioning-executor.service \
  --property=ConditionResult --property=Result --property=ExecMainStatus --no-pager
cd hosts/csb1/docker
docker compose up -d --no-deps --force-recreate pharosd
curl --fail --silent --show-error http://127.0.0.1:8088/readyz >/dev/null
'
```

The container identity comparison is a mandatory guard: the NixOS switch must
not recreate `pharosd` before the executor check. Both timer checks must
succeed and the pre-activation one-shot service must report `Result=success`
and `ExecMainStatus=0`, with `ConditionResult=yes`, before recreating
`pharosd`. Because the still-running Pharos instance has managed creation
disabled, this poll cannot claim paid work; it validates the executor's local
runtime conditions and safe deferral path. The readiness request must then
return success. Do not inspect secret files, process environments, or raw
request output.

Each claimed bootstrap lease lasts two hours. The executor admits only a
bounded future lease, caps `nixos-anywhere` at 110 minutes, and shortens that
timeout when necessary so at least five minutes remain for verification and
result reporting. A lease that cannot preserve this reserve fails closed
before installation starts; do not extend a lease or replay a pending result
by hand.

After deployment, open the Pharos Hetzner connection and run **Test
connection** once. This is an authenticated read-only catalog refresh and must
show the dedicated executor key, selected firewall, and location as ready.
Opening the server assistant and reviewing a plan do not mutate the provider.
Stop before the final create confirmation: the first paid server remains a
separate attended PHAROS-146 action after its exact server type, location,
image, and displayed price are reviewed.

If the timer, readiness request, or no-job executor check fails, do not attempt
server creation. Restore all three gates to their disabled values in one
reviewed rollback, and restore the corresponding disabled-state assertions in
T06 and T28 so the rollback remains CI-green. After pulling that rollback on
csb1, recreate `pharosd` first so `PHAROS_HCLOUD_EXECUTE=0` removes the
paid-provider capability, verify its readiness, and only then run `just switch`
to disable the executor timer.

To validate Pharos credential retirement without touching production material:

```bash
just janus-pharos-retirement-smoke
```

The smoke uses one synthetic host and isolated volumes. It must report a
complete retirement, idempotent replay, renderer exclusion, unchanged provider
material, `value_returned=false`, and `provider_deleted=false`.

Production retirement is target-local and derives its disposition from the
reviewed `retired-hosts.json` entry. The checkout must be clean `main` at the
reviewed remote revision. Reconcile first; apply only after the corresponding
host-removal proposal is merged and deployed:

```bash
just janus-pharos-retirement-reconcile <host>
just janus-pharos-retirement-apply <host>
```

In normal operation, `pharos-retirement-executor.timer` performs the apply on
csb1 after Pharos observes the reviewed declaration removal. It authenticates
with csb1's existing machine identity, rejects csb1 as a target, and persists
only a value-free result for retry if Pharos is temporarily unavailable. Check
its posture without exposing credentials:

```bash
systemctl status pharos-retirement-executor.timer
journalctl -u pharos-retirement-executor.service -n 30 --no-pager
```

Mutable lifecycle metadata, progress records, and tombstones live in dedicated
Janus Docker volumes. The encrypted provider artifact is retained. The renderer
excludes every reviewed retired host, so a later sidecar render cannot silently
recreate its runtime access.

### Managed-Service Secret CRUD Canary

The first production consumer is deliberately boring: one networkless canary,
one declared secret slot, and no reveal path. The browser can create, replace,
or remove the slot. Janus keeps central custody encrypted, delivers a
host-bound signed envelope, and the root-only host agent recreates only the
declared Compose service. The canary itself runs as uid `65534` with no
capabilities and proves that it loaded the current generation by comparing
hashes in private tmpfs; neither the hash nor the value is exposed in UI or
operator output.

Before any activation, upgrade, or recovery action:

```bash
cd ~/Code/nixcfg
just janus-managed-secret-readiness declarative
sudo just janus-managed-secret-readiness live
```

Both modes print stable reason codes and `value_returned=false`. Declarative
readiness verifies the exact release pins, catalog, declaration fingerprint,
closed host profile, Nix unit wiring, and container hardening. Live readiness
also verifies private file metadata, the admitted transaction daemon and Unix
socket, the active host restore/agent units, the Pharos host-token generation,
and the healthy canary.

Normal status checks:

```bash
systemctl status \
  janus-managed-central-seed.service \
  janus-managed-transactiond.service \
  janus-host-secret-restore.service \
  janus-managed-host-agent.service \
  janus-managed-canary.service
docker inspect --format \
  'name={{.Name}} state={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
  janus-managed-transactiond janus-managed-canary
```

Do not inspect environment variables, print `/run/agenix` files, open the host
ciphertext cache, or copy the runtime file. The UI and readiness command are
the supported operator surfaces.

#### Janus or Pharos unavailable

An already-running service continues with its installed generation. The host
cache also permits reboot restore without central Janus, but no create,
replace, or remove operation may be started or declared successful. Leave the
cache, runtime file, outbox, and transaction journal untouched. Restore the
failed control plane, then rerun live readiness; the idempotent workers resume
the exact recorded phase.

#### Fleet-secret systemd credential boundary

JANUS-446 makes the exact `managed-service-environment` capability available;
Janus still owns authorization, its reviewed host profile, and projection of
the private file. Nixcfg's `inspr.janusFleetSecrets` module owns only the
deterministic host/unit handoff. A consumer declaration is one line:

```nix
inspr.janusFleetSecrets.consumers.example-consumer = "shared-alert-url";
```

The declaration contains no slot, profile, permit, destination, runtime path,
or value. The module derives
`/run/janus-projections/managed-service-environment/<host>/shared-alert-url.env`,
requires its private projection gate before `example-consumer.service`, and
passes it as `LoadCredential=janus-shared-alert-url:...`. The named consumer
must already be a real service with an `ExecStart`; a typo cannot create an
inert unit. The gate becomes inactive after each check, so every consumer start
or restart reruns it immediately before systemd acquires the credential. It
rejects a missing, non-regular, symlinked, non-root-owned, or non-`0600` file,
as well as any symlinked, unexpectedly owned, writable, or non-private final
parent path. Existing `LoadCredential*`, `SetCredential*`, or
`ImportCredential` exact/wildcard/rename entries may not produce the derived
credential name. Every entry in all five credential directives must be a
nonempty printable-ASCII line with non-space ends; `%` specifiers and backslash
escapes are rejected. Empty resets, outer whitespace, control/non-ASCII bytes,
and unit-file line injection therefore fail before the first literal colon is
parsed. There is no agenix, environment, inline, or credstore fallback.

The application reads `$CREDENTIALS_DIRECTORY/janus-shared-alert-url`
directly, or uses `systemd-credential://janus-shared-alert-url` through
secretspec. The module does not issue a Janus permit, reveal a value, migrate
agenix data, or activate a host. A reviewed Janus profile targeting the exact
derived path and a separate host-adoption ticket are required before use.

#### Canary health failure

Do not repeatedly recreate the service by hand. A failed create stops without
claiming success. A failed replacement automatically restores the previous
encrypted generation and must prove that generation healthy. Check only the
value-free unit/container states and the Pharos operation reason code. If
automatic rollback cannot prove health, stop new operations and preserve the
transaction, host cache, and audit directories for review.

#### Stuck or interrupted operation

Stop new browser submissions. Confirm that the current catalog still contains
the exact host/service/slot/kind/source entry and that both control planes are
on the reviewed release. Never delete a `webtx_` journal or synthesize a
completion result. Restart `janus-managed-transactiond`, then the host agent,
and rerun live readiness. Startup reconciliation either resumes the exact
removal or rolls back an interrupted create/replace; an incompatible or stale
catalog fails closed.

#### Lost or retired host

Disable its agent token, mark the host retired declaratively, increase the
minimum revocation epoch, and add any known envelope reference to the revoked
set before deleting provider resources. Rotate every secret that host could
consume. Keep tombstones and audit evidence. Never reassign the old host ref,
SSH host key, cache, or agent token to a replacement host.

#### Signing key, Age identity, or agent-token compromise

Stop new operations and disable the host agent. Rotate the affected agenix
material through the normal reviewed Git flow. For a host-envelope signing-key
incident, remove the old verification key and raise the revocation epoch. For
an Age identity incident, generate a new identity/recipient and replace every
active secret through the UI. For an agent-token incident, rotate the token,
republish the Pharos Janus hash generation, and recreate Pharos before
re-enabling the agent. Rerun both readiness modes before resuming.

#### Release rollback and break glass

Rollback is a reviewed Nix generation or Git revert, never an on-host compose
edit. First confirm there is no nonterminal managed operation. Keep schema-v2
readers in place while any removal journal or tombstone exists. If a release
must be rolled back, pin its exact signed digest and matching admission receipt,
switch NixOS, recreate only `janus`, `pharosd`, and
`janus-managed-transactiond`, then run live readiness.

Break glass does not enable reveal. Its only supported outcome is restoring the
last healthy declared generation or leaving the canary stopped. Record the
reason and exact reviewed revision in PPM before resuming normal operations.

### Upgrade PAIMOS (pm.barta.cm)

Image source: `ghcr.io/inspr-at/paimos:<version>` — an explicit pin in
`hosts/csb1/docker/compose-spec.nix`. Deploys are a pin bump + PR +
`nixos-rebuild switch` on csb1 (PAI-732; `/etc/paimos-deploy.sh` was removed
in NIX-359). Full flow + rollback: `docs/PPM-RUNBOOK.md` §2/§3.

```bash
# Optional safety backup before a risky bump (data volume snapshot):
ssh mba@cs1.barta.cm -p 2222
TS=$(date +%Y-%m-%d-%H%M)
mkdir -p ~/backups/paimos-$TS
docker run --rm -v ppm_data:/data -v ~/backups/paimos-$TS:/backup alpine \
  tar czf /backup/ppm_data.tar.gz -C /data .

# Verify after the switch:
docker ps --filter name=ppm --format '{{.Image}} {{.Status}}'
curl -fsSI https://pm.barta.cm/ | head -1
docker logs ppm --tail 50
```

Rollback on failure: set the pin in `compose-spec.nix` back to the previous
version and switch again (PPM-RUNBOOK §3 — mind DB migrations).

Data rollback (only on migration corruption — additive-only schema, very rare):
`docker compose stop ppm && docker run --rm -v ppm_data:/data -v ~/backups/paimos-<TS>:/backup alpine sh -c "rm -rf /data/* && tar xzf /backup/ppm_data.tar.gz -C /data" && docker compose up -d ppm`.

---

## Paimos external-stage activation (NIX-381 / PAI-810)

The Pharos owner adapter (PHAROS-206) and the Janus dependency reporter
(JANUS-441) are wired declaratively and land **inert**. Everything below is the
activation procedure. Do one step at a time.

### Why this is not just a rebuild

`pharosd` **panics at startup** when `PHAROS_PAIMOS_DELIVERY_CONFIG_FILE` is set
but the config, the API key or any 32-byte handoff secret is missing, malformed,
or not owned by uid 10001 with mode `0400`. Activating before the credentials
exist does not degrade the dashboard — it crash-loops it. That is why one
boolean, `active` in `hosts/csb1/paimos-delivery-stage.nix`, gates both the
compose environment and the module wiring, and why `tests/T48` fails the build if
the two ever disagree.

### Prerequisites, in order

1. **Mint in Paimos** (not on this host): the owner API key, the Janus machine
   API key, one deployment handoff, one verification handoff, one Janus
   dependency handoff. Each handoff mint returns its 32 raw bytes **once**. A
   lost response requires a rotation, not a retry.

2. **Enrol five agenix secrets.** Add to `secrets/secrets.nix` (recipients
   `markus ++ csb1`), then `agenix -e secrets/<name>.age` for each:

   | Secret                                               | Content                          | Owner / mode     |
   | ---------------------------------------------------- | -------------------------------- | ---------------- |
   | `csb1-paimos-pharos-owner-api-key.age`               | API key, **no trailing newline** | `10001` / `0400` |
   | `csb1-paimos-pharos-deployment-handoff-secret.age`   | exactly 32 raw bytes             | `10001` / `0400` |
   | `csb1-paimos-pharos-verification-handoff-secret.age` | exactly 32 raw bytes             | `10001` / `0400` |
   | `csb1-paimos-janus-dependency-api-key.age`           | API key, **no trailing newline** | `root` / `0400`  |
   | `csb1-paimos-janus-dependency-handoff-secret.age`    | exactly 32 raw bytes             | `root` / `0400`  |

   🔴 The trailing-newline rule is not cosmetic: pharosd requires every API-key
   byte in `0x21..0x7e`, and `0x0a` is not. A handoff secret file whose size is
   not exactly 32 is refused outright.

   Then add the five `age.secrets.<name>` blocks to
   `hosts/csb1/configuration.nix` with the owner and mode from the table.
   `tests/T47` requires the ciphertext to exist before the declaration, so the
   `.age` files and their declarations land in the same change.

3. **Fill in the intents.** In `hosts/csb1/configuration.nix`, set
   `inspr.pharosPaimosDelivery.intents` (one `deployment`, one `verification`)
   and the `inspr.janusPaimosDependencyReporter` `handoffId` / `expected` /
   `evidence` from exactly what Paimos returned. The modules reject any other
   shape at eval time — handoff ids must be Paimos-minted 26-character Crockford
   base32, digests must be `sha256:` plus 64 lowercase hex, and a verification
   intent must pair with a distinct deployment intent for the same host,
   environment and artifact.

4. **Preflight on the host, before flipping the switch.** Sizes and modes only —
   never print a value:

   ```bash
   # Present, correct owner, mode 0400, exactly one link, and the right size.
   # %u is the numeric uid pharosd actually compares against its own euid; %U
   # is only its name, and a missing user would silently print a bare number.
   stat -c '%n %u %U %a %h %s' /run/agenix/csb1-paimos-*
   ```

   Expect uid `10001` (`pharos-container`) on the three pharos files, `0`
   (`root`) on the two janus files, `0400` and link count `1` everywhere, and
   size `32` on every `*-handoff-secret`.

5. **Flip one boolean.** Set `active = true;` in
   `hosts/csb1/paimos-delivery-stage.nix`, open a PR, let protected CI run, merge,
   then `just switch` on csb1 followed by the compose reconcile.

### After activation

```bash
# Adapter came up (the log line is value-free: release, commit, schema, digest).
docker logs pharosd --tail 50 | grep -i 'paimos reporter-only'
# The reporter is a one-shot; before activation it is SKIPPED, not failed.
systemctl status janus-paimos-dependency-reporter.service
systemctl list-timers janus-paimos-dependency-reporter.timer
```

Journals: pharosd derives its exact-replay journal beside `PHAROS_DB` as
`/data/pharos.json.paimos-delivery-journal.json` inside the `csb1_pharos_data`
volume; the reporter writes to `/var/lib/janus-paimos-dependency-reporter/journal`
(root, exactly `0700`). PAI-810 acceptance criterion 7 retains both until the
evidence is accepted — revoke the handoffs, registrations and dedicated API keys
first, delete journals only afterwards.

### What activation deliberately does not grant

The deployment intent names an **existing** Pharos `UpdateRestart` job and the
adapter only observes it. It refuses to report success unless that job already
carries an operator confirmation, so the consequential restart stays an attended
decision in the Pharos UI. Deployment alone reaches `deployed_unverified`;
`verified` needs a separate, later, fresh beacon for the exact artifact.

### Contract pin — no foreign-repo change needed

Pharos v0.1.83 and Janus v0.1.33 record Paimos `v5.11.0` / `e5f4c86…` as
provenance, while production runs `v5.12.0` / `ee669d0`. This is **not** drift.
Both adapters compare only `contract_major` and `fixture_digest` taken from the
wire, and v5.12.0 still serves the same digest,
`sha256:0318f4025902c9d5dd790384950cc9daebb16e02e79a4a90ce7dddc673e68bed`.
Paimos states the reason in `backend/contracts/external_stage.go`: _"The manifest
is deliberately excluded so release-pin metadata can change without changing the
adapter contract."_ The release strings are logged, never compared. If a future
Paimos release does change the fixture bytes, both adapters fail closed
(`contract_refused` / a `paimos_reporter_*` reason code) rather than misreport.

---

## Troubleshooting

### Decision Tree

```
Service Not Responding?
├─ Can SSH?
│  ├─ YES: Docker/service issue
│  │  ├─ docker ps → container running?
│  │  │  ├─ YES: Check logs: docker logs <container>
│  │  │  └─ NO: Start it: cd ~/docker && docker-compose up -d
│  │  └─ Docker down? systemctl status docker
│  └─ NO: Server/network issue
│     ├─ Try password SSH (see SECRETS.md)
│     ├─ Can ping 152.53.64.166?
│     │  ├─ YES: SSH service down → Use VNC console
│     │  └─ NO: Server down → Check Netcup panel
│     └─ Last resort: VNC console (Netcup SCP)

```

### Common Issues & Quick Fixes

```
Paperless down → docker restart csb1-paperless-1
Backup failed → docker logs csb1-restic-cron-hetzner-1
High load → Check docker stats (find heavy container)
SSL Error 526 (Cloudflare) → CF API token expired; see below
```

### SSL / TLS Certificate Renewal (Cloudflare DNS-01)

Traefik uses `secrets/traefik-variables.age` (shared with csb0) for ACME DNS-01 via Cloudflare API.

**Symptom:** Cloudflare Error 526 on all `*.barta.cm` services; Traefik logs show:
`status code 403 — 9109: Invalid access token`

**Token rotation (last done: 2026-03-06, stored in 1Password as "dns-token-2026-03-06"):**

1. Cloudflare Dashboard → Profile → API Tokens → Create Token
   - Permission: `Zone / DNS / Edit` scoped to `barta.cm` (no TTL, no IP filter)
2. Save new token to 1Password; name entry with date
3. Re-encrypt: `cd ~/Code/nixcfg && agenix -e secrets/traefik-variables.age`
4. Commit + push; deploy both csb0 and csb1
5. `docker restart csb1-traefik-1` to trigger immediate cert renewal
6. Verify: `docker logs csb1-traefik-1 --tail 50 2>&1 | grep -i acme`

---

## Emergency Recovery

### Access Priority

1. **Primary**: SSH with key (`~/.ssh/id_rsa`)
2. **Backup**: SSH with mba password (see 1Password: "csb0 csb1 recovery")
3. **Emergency**: Netcup VNC console + mba password
4. **Recovery**: Netcup control panel access (with 2FA)

### Recovery Password

The `mba` user has a `hashedPassword` set in `configuration.nix` for emergency
VNC console access. Password stored in 1Password under "csb0 csb1 recovery".

### Network Configuration

Static IP `152.53.64.166/24` is configured declaratively in NixOS.
Gateway: `152.53.64.1` | DNS: `8.8.8.8`, `8.8.4.4`

### 🚨 Historical Incident: 2025-12-05 Network Loss

**Symptom:** Server became unreachable immediately after `nixos-rebuild switch`.
**Root Cause:** The configuration used NetworkManager (`networking.networkmanager.enable = true`) but did not define a static IP declaratively. On a fresh generation switch, the imperative connection profile was lost, and NetworkManager didn't know how to bring up the interface.
**Recovery:** Had to boot with `init=/bin/sh`, manually bring up `ens3` with `ip addr add` and `ip link set`, and then start `sshd -o UsePAM=no` to regain access and fix the configuration.
**Fix:** Always define static networking declaratively for servers (`networking.interfaces.ens3...`) and set a `hashedPassword` for the `mba` user for VNC console recovery.

### If SSH Fails

1. Login to Netcup SCP (https://www.servercontrolpanel.de/SCP)
2. Navigate to server, open VNC console
3. Login as `mba` with recovery password (see 1Password)

### VNC Console Recovery (Netcup)

⚠️ **Netcup VNC has German keyboard layout issues!**

**Keys that WORK:**

- Letters (a-z, A-Z), Numbers (0-9)
- Forward slash `/`, Period `.`, Spaces
- Dollar `$`, Parentheses `()`, Equals `=`, Underscore `_`
- Arrow keys, Tab completion (in bash, NOT busybox)

**Keys that DO NOT WORK:**

- Hyphen `-` (critical for commands!)
- Backslash `\`, Colon `:`, Pipe `|`

**If login prompt works** → Use mba password from 1Password

**If login broken** → Use `init=/bin/sh` recovery:

1. Reboot via Netcup panel
2. At GRUB, press `e` to edit boot entry
3. Add `init=/bin/sh` to end of linux line
4. Press Ctrl+X to boot
5. In minimal shell (`sh-5.3#`), find tools with glob:

```bash
# Find password tool
echo /nix/store/*shadow*/bin/passwd
# Example: /nix/store/117zjnjzaw0n22z0xinp17qpbdv3wsra-shadow-4.18.0/bin/passwd

# Set password (use Tab completion after partial path)
/nix/store/117z[Tab]/bin/passwd mba

# Find network tools
echo /nix/store/*iproute*/bin/ip

# Configure network (adjust path with Tab)
/nix/store/m1b[Tab]/bin/ip addr add 152.53.64.166/24 dev ens3
/nix/store/m1b[Tab]/bin/ip link set ens3 up
/nix/store/m1b[Tab]/bin/ip route add default via 152.53.64.1

# Continue normal boot
exec /nix/var/nix/profiles/system/init
```

**Note:** Busybox ash shell is worse than bash (no arrow-up, no Tab). If you accidentally enter it, type `exit` to return to bash.

### Netcup API Emergency Restart

```bash
# Get token and restart (see SECRETS.md for refresh token location)
TOKEN=$(curl -s 'https://servercontrolpanel.de/realms/scp/protocol/openid-connect/token' \
  -d 'client_id=scp' -d "refresh_token=$(cat ~/Code/nixcfg/hosts/csb1/secrets/netcup-api-refresh-token.txt)" \
  -d 'grant_type=refresh_token' | jq -r '.access_token') && \
curl -X POST "https://servercontrolpanel.de/scp-core/api/v1/servers/646294/reset" \
  -H "Authorization: Bearer $TOKEN"
```

### Single Service Restore (Example: Docmost)

```bash
docker-compose down docmost
docker exec csb1-restic-cron-hetzner-1 restic restore latest \
  --target /tmp/restore --path /backup/var/lib/docker/volumes/csb1_docmost_data
sudo cp -a /tmp/restore/backup/var/lib/docker/volumes/csb1_docmost_data/* \
  /var/lib/docker/volumes/csb1_docmost_data/
docker-compose up -d docmost
```

---

## Backup System

### ⚠️ Shared Repository with csb0

- Both servers backup to the same Hetzner repository
- Snapshots identified by hostname (csb0 vs csb1)
- **Cleanup managed by csb0** (runs at 03:15 AM daily)

### Schedule

| Task                      | Time                   | Container                              |
| ------------------------- | ---------------------- | -------------------------------------- |
| HAUSV PostgreSQL dump     | 01:10 AM daily         | `hausv-postgres-backup-snapshot.timer` |
| HAUSV consistent snapshot | 01:20 AM daily         | `hausv-backup-snapshot.timer`          |
| Backup                    | 01:30 AM daily         | csb1-restic-cron-hetzner-1             |
| Cleanup                   | N/A (done on csb0)     | -                                      |
| Check                     | 05:30 AM monthly (1st) | csb1-restic-cron-hetzner-1             |

### What Gets Backed Up

```
✅ /var/lib/docker/volumes - ALL Docker volumes
   └─ Docmost, Paperless data
✅ /home - All user home directories
✅ /root - Root user data
✅ /etc - System configuration
✅ /var/lib/csb1-docker/hausv-org-backup-snapshot
   └─ Quiesced SQLite + blob recovery point; use this for HAUSV restores
✅ /var/lib/csb1-docker/hausv-postgres-backup-snapshot
   └─ Atomic, validated logical dump of the unused Phase-0 PostgreSQL database
❌ /var/lib/csb1-docker/hausv-org live directory
   └─ Deliberately excluded to avoid a mixed SQLite/blob recovery point
❌ Exclusions: */cache/*, *.log*
```

### Check Backup Status

```bash
# View logs
docker logs csb1-restic-cron-hetzner-1 | tail -50

# List snapshots
docker exec csb1-restic-cron-hetzner-1 restic snapshots
```

### HAUSV Tailnet Preview Slot

From a clean `hausv-org` worktree on an operator machine with repository access,
stream the selected tree to the isolated fixture-only preview slot:

```bash
git archive --format=tar <ref> | ssh csb1 sudo hausv-next deploy <ref>
```

The final argument is only the displayed release label; csb1 never fetches it.
The slot is tailnet-only at `http://100.64.0.4:8099` and has no production data,
volume, secret, network, or Traefik route. To discard its fixture data while
keeping the same archived release, run `ssh csb1 sudo hausv-next reset`.

### HAUSV Snapshot And Restore

The host timer stops only `hausv-org` through the private
`~/Code/hausv-jhw22/compose.yml` project, copies the complete data directory,
checks `hausv.db`, atomically publishes the snapshot, and starts the service
again. A failed copy or integrity check leaves the previous snapshot intact.

```bash
# Create and verify a fresh local recovery point.
sudo systemctl start hausv-backup-snapshot.service
systemctl status hausv-backup-snapshot.service --no-pager
sudo /run/current-system/sw/bin/python3 - \
  /var/lib/csb1-docker/hausv-org-backup-snapshot/hausv.db <<'PY'
import sqlite3
import sys

try:
    database = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
    result = database.execute("PRAGMA integrity_check").fetchone()
except sqlite3.Error:
    print("integrity check failed", file=sys.stderr)
    raise SystemExit(1)
if result != ("ok",):
    print("integrity check failed", file=sys.stderr)
    raise SystemExit(1)
print("ok")
PY

# Restore drill into the restic container; never overwrite production directly.
docker exec csb1-restic-cron-hetzner-1 sh -c \
  'restic restore latest --target /tmp/hausv-restore-test \
   --include /backup/var/lib/csb1-docker/hausv-org-backup-snapshot'
docker cp \
  csb1-restic-cron-hetzner-1:/tmp/hausv-restore-test/backup/var/lib/csb1-docker/hausv-org-backup-snapshot/hausv.db \
  /tmp/hausv-restore-test.db
/run/current-system/sw/bin/python3 - /tmp/hausv-restore-test.db <<'PY'
import sqlite3
import sys

try:
    database = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
    result = database.execute("PRAGMA integrity_check").fetchone()
except sqlite3.Error:
    print("integrity check failed", file=sys.stderr)
    raise SystemExit(1)
if result != ("ok",):
    print("integrity check failed", file=sys.stderr)
    raise SystemExit(1)
print("ok")
PY
```

Both integrity checks must print only `ok` and exit successfully. Any other
output or a non-zero exit stops the drill or restore; do not touch the live
data directory.

For a real restore, run the following stop and start commands from the private
instance checkout, preserve the current data directory, copy the _contents_ of
the restored `hausv-org-backup-snapshot` directory to
`/var/lib/csb1-docker/hausv-org`, restore ownership `65532:65532`, then require
a healthy `https://hausv.org/healthz` before removing the preserved directory.

```bash
cd ~/Code/hausv-jhw22
docker compose -p hausv-jhw22 -f compose.yml stop -t 30 hausv-org
# Restore the reviewed snapshot contents and ownership here.
docker compose -p hausv-jhw22 -f compose.yml start hausv-org
curl --fail --silent --show-error https://hausv.org/healthz
```

### HAUSV PostgreSQL Phase-0 Recovery Point

`hausv-postgres` is an unused Phase-0 service. It has its own
`hausv_postgres_data` volume, publishes no host port, and shares only the
existing `csb1_hausv-egress` network with the application. HAUSV has no
dependency, backend selector, DSN, password mount or other runtime reference to
it; SQLite remains the only source of truth.

The PostgreSQL bootstrap administrator and `hausv_app` passwords are separate
agenix files. The application role is created with `NOSUPERUSER NOBYPASSRLS`,
and the container health check fails unless both flags remain false. Never give
the application the bootstrap administrator credential: PostgreSQL superusers
silently bypass Row Level Security.

At 01:10 the host runs `pg_dump --format=custom` as `hausv_backup`
(`BYPASSRLS`, not superuser; HAUSV-559) against a transactionally
consistent PostgreSQL snapshot, validates the archive catalog with
`pg_restore --list`, and atomically publishes `hausv.dump` plus
`SNAPSHOT-CREATED-UTC`. Failure preserves the preceding recovery point. The
existing Restic job includes this directory through its existing
`/var/lib/csb1-docker` mount; its command and the live-HAUSV exclusion are
unchanged.

Create and test a recovery point without exposing any credential:

```bash
sudo systemctl start hausv-postgres-backup-snapshot.service
systemctl status hausv-postgres-backup-snapshot.service --no-pager
sudo hosts/csb1/scripts/hausv-postgres-restore-drill.sh
```

The drill creates a uniquely named isolated database in the same container,
restores with `--exit-on-error --single-transaction --role=hausv_app`, verifies
that every restored application relation is owned by that non-superuser,
confirms it is not `BYPASSRLS`, connects as the role, and always drops the drill
database. It never replaces `hausv` and never touches SQLite or the blob tree.
Record the Restic snapshot ID and drill date in PPM Knowledge
`persistence-store-pattern`; do not put secret values or tenant data there.

#### Phase-2 migration gate — CLOSED

The Phase-0 logical dump is a database recovery proof, not yet a PostgreSQL +
blob recovery proof. Before PostgreSQL may become a production source of truth,
the established HAUSV snapshot service must be extended in one quiesced window:

1. Take the same compose lock used by deploys and stop only `hausv-org` with
   the reviewed 30-second budget.
2. Run a custom-format `pg_dump` and copy the complete blob/audit/parking tree
   into one staging directory while application writes are stopped.
3. Validate the dump catalog, restore it as `hausv_app` into an isolated
   database, run the application schema/RLS checks, and validate the copied
   files.
4. Atomically publish the combined directory, restart HAUSV, and require a
   healthy exact `/healthz` response. Any failure keeps the preceding recovery
   point and restarts the application.
5. Let the unchanged Restic job carry that combined recovery point off site,
   restore the exact new Restic snapshot into isolation, and repeat the
   database, RLS, file and application-health checks.

Migration remains forbidden until that combined off-site drill is recorded in
PPM Knowledge. Do not remove the SQLite quiesce path or its live-path exclusion
before the migrated service has passed the combined drill and its rollback
window has explicitly closed.

### HAUSV Snapshot, Health And Application Alerts

`hausv-alerts.timer` checks every five minutes that the snapshot timer is
enabled and active, its last service result succeeded, and both the coherent
local snapshot marker and the existing sanitized Restic success are no more
than 30 hours old. It also checks the container, the exact public `/healthz`
contract, unexpected restarts, and privacy-safe categories of new critical
structured logs. Container and public-health failures need two consecutive
checks; snapshot-chain and critical-log failures alert immediately.

The monitor consumes existing signals only. It neither creates another backup
nor duplicates HAUSV retention. It reads only `WATCHTOWER_NOTIFICATION_URL`
from the existing `csb1-watchtower-env` agenix file and never writes raw logs,
URLs, recipient identifiers, object data, or secret values to its state,
journal, or alert. A transition is persisted before delivery; a failed
delivery is retried, and one recovery is sent when the signal becomes healthy.

```bash
# Timer and last monitor result.
systemctl status hausv-alerts.timer --no-pager
sudo systemctl start hausv-alerts.service
systemctl status hausv-alerts.service --no-pager
journalctl -u hausv-alerts.service --since "1 hour ago" --no-pager

# Manual end-to-end delivery proof. This sends one clearly labelled test alarm
# and one test recovery; it does not change production or monitor state.
sudo systemctl start hausv-alerts-delivery-probe.service
systemctl status hausv-alerts-delivery-probe.service --no-pager
```

Successful monitor output contains counters only. Diagnose a named category
with the relevant service/container journal; never print the notification env
file. Restore capability itself is already proven by the isolated
26 July 2026 drill of Restic snapshot `05bafbd5`, including SQLite
`PRAGMA integrity_check = ok`. The canonical evidence is PPM Knowledge
`persistence-store-pattern`; do not repeat that restore drill merely to accept
an alerting change.

### Tailnet Witness (tailnet-watch, OPS-181)

`tailnet-watch.timer` runs every ten minutes and reads **this host's** view of
the mesh: `tailscale status --json` (must parse, `BackendState` = `Running`,
every `.Health` entry is a problem of its own) and `tailscale debug derp-map`
(zero regions = the 2026-08-21 empty-DERP-map outage, which went unpaged for
~57 minutes). Same OPS-107 engine as peer-watch: a problem must be seen on two
consecutive runs before it pages, recovery announces a clear, and delivery
reuses `csb1-watchtower-env` — no new secret. Scope is csb1's view, not the
fleet; csb1 shares the netcup failure domain with headscale, so it catches the
post-outage poisoned map, not the site outage itself.

```bash
systemctl status tailnet-watch.timer --no-pager
sudo systemctl start tailnet-watch.service
journalctl -u tailnet-watch.service --since "1 hour ago" --no-pager
sudo cat /var/lib/tailnet-watch/state.json   # counters + pending only, never secrets
```

Intentional baseline advisories go into `SUPPRESSED_HEALTH` in the shared
`modules/shared/fleet-alerts/tailnet-watch-checks.py` (also used by hsb1,
OPS-185) with a comment and a pinned test; the baseline on 2026-08-21 was empty.

### Fleet Drift Watch (fleet-drift, OPS-187)

`fleet-drift.timer` runs hourly and reads pharosd's persisted store on this host
(`/var/lib/docker/volumes/csb1_pharos_data/_data/pharos.json`, root read-only —
`/hosts.json` needs an OIDC session even on localhost). It pages when a fleet
host's beacon says its deployed nixcfg is `behind` main and the deployed commit
is ≥ 7 days old (commit date from `~mba/Code/nixcfg`, best effort) or ≥ 25
commits behind; `diverged`/`ahead` page as their own problem; hosts silent for

> 30 min are skipped (Pharos HostDown owns silence). Same OPS-107 engine: two
> consecutive runs before paging, recovery clears, `csb1-watchtower-env` target.
> Truthful only with OPS-186 in place (beacons must see the current evidence).

```bash
systemctl status fleet-drift.timer --no-pager
sudo systemctl start fleet-drift.service
journalctl -u fleet-drift.service --since "1 day ago" --no-pager
```

### HAUSV Graceful Stop Budget

The private `hausv-jhw22` Compose service declares `stop_grace_period: 30s`.
This covers the
application's 15-second HTTP shutdown, the five-second login-mail queue drain,
one second for canceling an in-flight SMTP transport, and nine seconds of host
margin. The snapshot service's explicit
`docker compose -p hausv-jhw22 stop -t 30 hausv-org` uses the same budget. Do
not reduce either boundary without first reducing and testing the application
limits.

After a recreate, verify only the non-secret lifecycle field and the
application journal:

```bash
docker inspect --format '{{.Config.StopTimeout}}' hausv-org
journalctl --since "10 minutes ago" --no-pager \
  | grep -E 'shutting down|magic link delivery shutdown|hausv-org'
```

The expected stop timeout is `30`. A normal restart may log `shutting down`;
it must not log `magic link delivery shutdown deadline reached`, a forced
termination, or an unhealthy replacement.

---

## Service Dependencies

```
(influx/grafana retired 2026-06-12, NIX-193 — archive on hsb1)
```

---

## Maintenance

### Clean Up Disk Space

```bash
ssh mba@cs1.barta.cm -p 2222 "docker system prune -f"
```

### View Logs

```bash
# Current boot
ssh mba@cs1.barta.cm -p 2222 "journalctl -b -e"

# Follow logs
ssh mba@cs1.barta.cm -p 2222 "journalctl -f"
```

---

## Web Interfaces

| Service    | URL                        | Auth                          |
| ---------- | -------------------------- | ----------------------------- |
| Paperless  | https://paperless.barta.cm | Paperless login               |
| Docmost    | https://docmost.barta.cm   | Docmost login                 |
| Excalidraw | https://draw.barta.cm      | Cloudflare Access (email OTP) |

### Excalidraw Access Management

Protected via **Cloudflare Zero Trust** → Access → Applications → `Excalidraw`.

- Auth method: One-time PIN (email)
- Policy: email allowlist (family + friends)
- To add/remove users: Cloudflare Zero Trust dashboard → Access → Applications → Excalidraw → Edit policy

---

## Services to Archive Post-Migration

### Hedgedoc ❌ DECOMMISSIONED

- **Status**: Will not be migrated
- **Volumes to archive**: `csb1_hedgedoc-app-uploads`, `csb1_hedgedoc-db-data`

---

## Related Documentation

- [csb1 README](../README.md) - Full server documentation
- [SECRETS.md](../secrets/SECRETS.md) - All credentials (gitignored)
- [DEPRECATED-RUNBOOK.md](../secrets/DEPRECATED-RUNBOOK.md) - Old runbook with inline secrets
- [csb0 Runbook](../../csb0/docs/RUNBOOK.md) - Smart home hub (dependency)
