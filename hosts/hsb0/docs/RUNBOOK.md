# Runbook: hsb0 (DNS/DHCP Server)

**Host**: hsb0 (192.168.1.99)  
**Role**: Primary DNS and DHCP server running AdGuard Home  
**Criticality**: HIGH - Network infrastructure depends on this

---

## Quick Connect

```bash
ssh mba@192.168.1.99
# or
ssh mba@hsb0.lan
```

---

## HostDash

**URL**: http://hsb0/ or http://hsb0.lan/
**Container**: `hsb0-home` | **Unit**: `hsb0-home-dashboard` | **Source**: `github.com/markus-barta/hostdash`

The dashboard is mounted from `/etc/hostdash/hsb0/share/hostdash-hsb0` and
reconciled by NixOS. Restart it without touching the rest of the compose stack:

```bash
sudo systemctl restart hsb0-home-dashboard
```

### hausnetz (OPS-207)

After activation, hausnetz is served at `http://192.168.1.99/ops/` through
`hsb0-home`. Its `/ops` redirect keeps relative UI, API and SSE requests under
`/ops/`; nginx strips that prefix and disables buffering for the event stream.
The container resolves `host.docker.internal` through Docker's `host-gateway`.
Both `/ops` and `/ops/` allow only IPv4 LAN sources in `192.168.1.0/24`;
tailnet, IPv6 and same-host/bridge clients receive **403 by design**. The
slashless redirect runs after the access check. `/ops/` permits bodies up to
13 MiB for the app's 12 MiB floor-plan uploads. nginx hides upstream
Cache-Control and sends a single `no-store` policy.

The native `hausnetz.service` listens on `0.0.0.0:8377`, with TCP 8377 opened
only on `br-+` and `docker0`, never the LAN interface. mDNS discovery opens
UDP 5353 only on `enp2s0f0`. State starts empty in `/var/lib/hausnetz`, with
no seed or DHCP leases integration. Limits: 512M memory, 50% CPU quota, nice 10.
The `br-+` iptables wildcard intentionally covers every user-defined Docker
bridge, not only hsb0-home's bridge; this round leaves that rule unchanged.

The private flake input is pinned to `1f876f1d28d74d5931f4f3628a90de112a43506c`.
Root's SSH client selects `/root/.ssh/hausnetz_deploy` for `github.com`. This
hand-provisioned private file is a **read-only deploy key registered on
markus-barta/hausnetz**, not a Nix-managed secret. On a reinstall/recovery,
generate a new ed25519 key as root on hsb0 (0600), register only its public
half as a read-only deploy key on markus-barta/hausnetz, and remove the old
deploy key there; do not add it to Git, copy it to other hosts or grant `mba`
access.

**Who fetches the input.** `just switch` runs `nh os switch` as **mba**: the
flake evaluation (and any `git+ssh` fetch of hausnetz) happens as mba, and nh
uses sudo only for activation. The root SSH declaration therefore does **not**
serve `just switch`; it serves root evaluations only (`just nix-build`,
`just nix-switch`, `sudo nixos-rebuild`). `just switch` works because the
locked hausnetz source is already in `/nix/store` (Nix reuses a locked input
by its hash). Consequence: **after every hausnetz revision change (each pin
bump) or on a fresh store, run `just nix-build` (root) first, then `just
switch`**; if that fails, use `just nix-switch`. The
declarative known-host entry uses GitHub's published Ed25519 key. CI uses its
own read-only deploy key, repository secret `HAUSNETZ_DEPLOY_KEY`, scoped to
jobs that can evaluate hsb0, with a 0600 runner-temp key file, `IdentitiesOnly`
and pinned known_hosts. `GH_TOKEN_FOR_UPDATES` only manages existing update
PRs; it cannot read hausnetz. Both automated lock-update jobs still exclude
hausnetz from their input selection.

For OPS's first attended switch, start from the reviewed, merged clean `main`
checkout on **hsb0**, with the root deploy key present (0600). The first root
build needs an explicit key and the literal published host key because root's
SSH declaration only arrives with this switch. Run in `bash` (the operator
shell is fish); `sudo env` preserves the command for root:

```bash
known_hosts=$(mktemp)
printf '%s\n' 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' > "$known_hosts"
sudo env GIT_SSH_COMMAND="ssh -F /dev/null -i /root/.ssh/hausnetz_deploy -o IdentitiesOnly=yes -o UserKnownHostsFile=$known_hosts -o StrictHostKeyChecking=yes" \
  nixos-rebuild build --flake .#hsb0
```

Only after that build succeeds, switch (`just switch` now works as mba
because the source is in the store; OPS's first switch used `sudo nixos-rebuild
switch` with the same explicit key). The build also verifies the Go/npm
fixed-output hashes under nixcfg's followed nixpkgs pin. After switch, test the
declarative root SSH path (used by later root builds) without that temporary
override:

```bash
sudo ssh -G github.com | grep -iE '^identit'
sudo ssh -T git@github.com
```

Expect the hausnetz deploy-key greeting (`Hi markus-barta/hausnetz!`); GitHub
returns status 1 even on successful authentication because it offers no shell.
Check resolved identities because root's personal SSH config is read first.

hsb8 has no hausnetz access. Guarded system updates declare hsb0 in
`inspr.pharosGuardedDeploy.privateInputHosts` and log
`hsb0 skipped: private input, covered by CI` during the on-host fleet check.
Every other host is still evaluated. A credentialed evaluator sets
`canEvaluatePrivateInputs`; the deployment target itself is never skipped.
CI's full fleet evaluation remains mandatory and includes hsb0.

`ncps-warmer` runs as `mba`, which has **no hausnetz access**. Warming hsb0 can
work only while the pinned private source is already available to that user;
a root pre-fetch does not grant access or guarantee a cache hit for `mba`.
After cache eviction, its evaluation/dry-run may fail. The unit logs that
failure, continues warming the other LAN targets, and exits non-zero rather
than claiming hsb0 is already cached. Inspect `journalctl -u ncps-warmer`;
do not distribute the root deploy key to make this optional warm succeed.

Local contracts: `bash tests/T99-hausnetz-hsb0.sh` and, under Bash 5,
`bash tests/T14-pharos-system-update.sh`. OPS runs this exact CI command from
the clean committed checkout, with network/private-input access (root on hsb0
after activation, or the CI-specific key and pinned known_hosts above):

```bash
nix eval --impure --no-update-lock-file --json .#nixosConfigurations.hsb0 \
  --apply 'system: import ./tests/hausnetz-hsb0-eval.nix { inherit (system) config lib; }' \
  | python3 -c 'import json, sys; checks = json.load(sys.stdin); failed = [k for k, v in checks.items() if v is not True]; assert not failed, failed; print("OPS-207 full hsb0 evaluation: OK")'
```

The source-path contract uses `lib.hasSuffix` so checkout/store roots may
differ. Before accepting a deployment,
verify `/ops/` and its event stream from the LAN, that `/ops` answers 301 to
`/ops/` from the LAN, and that direct LAN connections to port 8377 fail. Roll back the OPS-207 commit and rebuild
through the normal attended deployment workflow to remove this integration;
existing state is retained. Preparing this configuration does not deploy it.

### In-flight page (OPS-353)

**URL**: http://100.64.0.6/inflight/ (tailnet) or http://hsb0.lan/inflight/ (home). Never public: hsb0 has no port forward.

AEON-LEAD's progress overview for Markus, served by `hsb0-home` from `/var/lib/inflight`
(mba, 0755, tmpfiles), mounted read-only at `/srv/inflight`. The location comes from
`docker/hsb0-home-inflight.conf`, included through the HostDash nginx include point
`/etc/nginx/hostdash-extra/*.conf`. Headers: `Cache-Control: no-store`,
`X-Robots-Tag: noindex, nofollow`, `Referrer-Policy: no-referrer`; dotfiles return 404.

Push atomically (the temp dotfile is never served):

```bash
scp -q aeon-progress.html mba@100.64.0.6:/var/lib/inflight/.index.html.tmp && ssh mba@100.64.0.6 'mv -f /var/lib/inflight/.index.html.tmp /var/lib/inflight/index.html'
```

---

## IB Gateway (paper) — enabled

**Status (2026-09-09)**: Compose service `ib-gateway` is **enabled** (paper) on default compose. Credentials via agenix. Full notes: **[IB-GATEWAY.md](./IB-GATEWAY.md)**.

**Container**: `ib-gateway` | **API**: `100.64.0.6:4002` (Tailscale only) | **Data**: `/var/lib/ib-gateway/tws_settings` (uid/gid 1000)

Mac must **not** run Gateway or an SSH `-L` tunnel. Desks connect directly over Tailscale to `100.64.0.6:4002`. The live account (port 4001) stays OFF.

## OpenClaw Gateway (Merlin + Nimue)

**Status (2026-09-09)**: gateway parked behind inactive Compose profile `openclaw` (default `compose up` does not start it). Data remains under `/var/lib/openclaw-gateway`. Reactivate by removing the `profiles` line (or activating profile `openclaw`) in `compose-spec.nix` and switching.

**Container**: `openclaw-gateway` | **Port**: 18789 | **Data**: `/var/lib/openclaw-gateway/data`
**Telegram**: @merlin_oc_bot (Merlin), Nimue's bot (Nimue)

Full operational runbook: **[OPENCLAW-RUNBOOK.md](./OPENCLAW-RUNBOOK.md)**

### Top 3

```bash
# 1. UPDATE to latest version (rebuilds container, pulls openclaw@latest from npm)
just oc-rebuild

# 2. CHECK STATUS + recent logs
just oc-status

# 3. HEALTH CHECK
curl http://192.168.1.99:18789/health
```

### Top 4-10

```bash
# 4. VIEW LIVE LOGS (follow mode)
ssh mba@hsb0.lan "docker logs -f openclaw-gateway"

# 5. RESTART (no rebuild, keeps current version)
just oc-stop && just oc-start

# 6. FULL DEPLOY (git pull + NixOS switch + container rebuild)
#    Run on hsb0 or via SSH:
ssh mba@hsb0.lan "cd ~/Code/nixcfg && gitpl && just switch && just oc-rebuild"

# 7. VIEW LIVE CONFIG (what's running vs what's in git)
docker exec openclaw-gateway cat /home/node/.openclaw/openclaw.json | jq

# 8. PULL AGENT WORKSPACE (sync workspace repo into container)
# Merlin temporarily disabled until replacement GitHub PAT is configured
just merlin-pull-workspace
just nimue-pull-workspace

# 9. TELEGRAM PAIRING (list pending, then approve)
docker exec -it openclaw-gateway sh -c \
  '. /home/node/.env && openclaw pairing list telegram --account merlin'
docker exec -it openclaw-gateway sh -c \
  '. /home/node/.env && openclaw pairing approve telegram <CODE> --account merlin'
# Replace "merlin" with "nimue" for Nimue

# 10. LIST AGENT SKILLS
docker exec openclaw-gateway sh -c \
  '. /home/node/.env && openclaw skills list --agent merlin'
docker exec openclaw-gateway sh -c \
  '. /home/node/.env && openclaw skills list --agent nimue'
```

### All Just Recipes

| Recipe                       | What                                                           |
| ---------------------------- | -------------------------------------------------------------- |
| `just oc-rebuild`            | Update + rebuild container (--no-cache, pulls latest openclaw) |
| `just oc-status`             | Container status + last 30 log lines                           |
| `just oc-stop`               | Stop container                                                 |
| `just oc-start`              | Start container                                                |
| `just merlin-pull-workspace` | Pull Merlin's workspace repo in container (currently disabled) |
| `just nimue-pull-workspace`  | Pull Nimue's workspace repo in container                       |

---

## Docker / Secrets

### Add a New Secret to a Container

Use this pattern whenever a Docker container on hsb0 needs a new API key or token.

**Four files + one human step:**

| File                                   | What to add                                                    |
| -------------------------------------- | -------------------------------------------------------------- |
| `secrets/secrets.nix`                  | `.age` entry with `publicKeys = markus ++ hsb0`                |
| `hosts/hsb0/configuration.nix`         | `age.secrets.hsb0-<name>` block (`mode = "444"`)               |
| `hosts/hsb0/docker/docker-compose.yml` | Volume mount: `/run/agenix/hsb0-<name>:/run/secrets/<name>:ro` |
| Container entrypoint                   | Read secret into var + export to `.env`                        |

**1. Register in `secrets/secrets.nix`:**

```nix
# <Description> — Format: Plain text token
# Edit: agenix -e secrets/hsb0-<name>.age
"hsb0-<name>.age".publicKeys = markus ++ hsb0;
```

**2. Declare in `hosts/hsb0/configuration.nix`:**

```nix
age.secrets.hsb0-<name> = {
  file = ../../secrets/hsb0-<name>.age;
  mode = "444";
};
```

**3. Mount in `hosts/hsb0/docker/docker-compose.yml`** (under the relevant service volumes):

```yaml
- /run/agenix/hsb0-<name>:/run/secrets/<name>:ro
```

**4. Read in the container entrypoint** (or env block if no entrypoint):

```sh
MY_KEY=$(cat /run/secrets/<name>)
# then export / write to .env as needed
```

**5. Encrypt (you do this on mbp0):**

```bash
agenix -e secrets/hsb0-<name>.age
```

**6. Deploy:**

```bash
# Commit + push, then on hsb0:
gitpl && just switch && just <container>-rebuild
# 'just switch' is required — agenix only decrypts on NixOS switch, not docker rebuild
```

---

## Common Tasks

### Update & Switch Configuration

```bash
ssh mba@192.168.1.99
cd ~/Code/nixcfg
git pull
just switch
```

### Fix Git Issues & Update

If git has merge conflicts or local changes blocking pull:

```bash
ssh mba@192.168.1.99
cd ~/Code/nixcfg
git status                           # Check what's wrong
git checkout -- .                    # Discard all local changes
# OR for specific file:
git checkout -- path/to/file
git pull
just switch
```

### Rollback to Previous Generation

**Paper gateway rollback floor (NIX-461 / HOSTD-38):** generation **204**,
activated from commit `1842c3ba901bc6202c502b01033fad8a66958814` on
2026-09-10, preserves the running gateway's `READ_ONLY_API=no` setting and the
previous Joe board producer. Its retained system is
`/nix/store/n4c8ym7m2vhdpqjqp8cg5gv92acqpmbm-nixos-system-hsb0-26.11.20260718.61b7c44`.
For the J-family producer rollout, select this verified checkpoint rather than
blindly assuming the previous generation is suitable. Do not roll back below
204 without a separate gateway plan: older declarations can recreate the paper
gateway in read-only mode and leave API clients waiting for write-access dialogs.
Keep the checkpoint and previous producer image until live acceptance is complete;
never overwrite the current trading journals or JoeDesk history during rollback.

```bash
ssh mba@192.168.1.99
sudo nixos-rebuild switch --rollback
```

---

## Health Checks

### Quick Status

```bash
ssh mba@192.168.1.99 "systemctl status adguardhome && zpool status | head -10"
```

### DNS Check

```bash
# External Resolution
dig @192.168.1.99 google.com

# Internal (.lan) Resolution
dig @192.168.1.99 hsb1.lan

# DNS Rewrites (Internal Overrides)
dig @192.168.1.99 csb0  # Should return cs0.barta.cm
```

### DHCP Verification

```bash
# Check if service is managing DHCP
systemctl status adguardhome | grep -i "dhcp"

# Check for new lease assignments in logs
sudo journalctl -u adguardhome | grep -i "dhcp"
```

### DHCP Leases

```bash
ssh mba@192.168.1.99 "sudo cat /var/lib/private/AdGuardHome/data/leases.json | jq"
```

### Search Static Leases (Encrypted Source)

```bash
# Find a host by name
agenix -d secrets/static-leases-hsb0.age | jq 'map(select(.hostname == "mbp0"))'

# Find a host by IP
agenix -d secrets/static-leases-hsb0.age | jq 'map(select(.ip == "192.168.1.197"))'

# Count total static leases
agenix -d secrets/static-leases-hsb0.age | jq 'length'
```

### ZFS Pool Status

```bash
ssh mba@192.168.1.99 "zpool status"
```

---

## AdGuard Home DNS Management

### Web Interface

Access at: http://192.168.1.99:3000

### View Query Logs

Query logs are stored at `/var/lib/private/AdGuardHome/data/querylog.json`

```bash
# Find all domains a device requested (replace IP with target device)
ssh mba@192.168.1.99 "sudo grep '192.168.1.235' /var/lib/private/AdGuardHome/data/querylog.json | jq -r '.QH' | sort -u"

# Recent queries from a device
ssh mba@192.168.1.99 "sudo grep '192.168.1.235' /var/lib/private/AdGuardHome/data/querylog.json | tail -20 | jq '{time: .T, domain: .QH, result: .Result.Reason}'"

# Find blocked queries for a device
ssh mba@192.168.1.99 "sudo grep '192.168.1.235' /var/lib/private/AdGuardHome/data/querylog.json | jq 'select(.Result.IsFiltered == true) | .QH' | sort -u"
```

### Add Domains to Allowlist (Whitelist)

Allowlist rules bypass ad-blocking for specific domains. Managed declaratively in NixOS config.

**1. Find domains to whitelist:**

```bash
# Get all unique domains a device is trying to access
ssh mba@192.168.1.99 "sudo grep 'DEVICE_IP' /var/lib/private/AdGuardHome/data/querylog.json | jq -r '.QH' | sort -u"
```

**2. Add to configuration:**

Edit `hosts/hsb0/configuration.nix` and add to `services.adguardhome.settings.user_rules`:

```nix
user_rules = [
  # Existing rules...
  # Device Name (IP / hostname)
  "@@||domain.example.com^"  # Purpose of this domain
];
```

For hsb8 (ww87), add to the `dnsAllowlist` variable at the top of `hosts/hsb8/configuration.nix`.

**Format:** `@@||domain^`

- `@@` = allowlist rule (exception)
- `||` = match domain start
- `^` = domain separator/end

**3. Deploy:**

```bash
# For hsb0
ssh mba@192.168.1.99 "cd ~/Code/nixcfg && git pull && just switch"

# For hsb8 (from any machine)
nixos-rebuild switch --flake .#hsb8 --target-host hsb8 --use-remote-sudo
```

### Query Log Field Reference

| Field                | Description                                          |
| -------------------- | ---------------------------------------------------- |
| `.T`                 | Timestamp                                            |
| `.QH`                | Queried hostname (domain)                            |
| `.IP`                | Client IP address                                    |
| `.Result.Reason`     | Why processed (Filtered, NotFilteredAllowList, etc.) |
| `.Result.IsFiltered` | true if blocked                                      |
| `.Elapsed`           | Response time in nanoseconds                         |

---

## Maintenance

### LG beamer Developer Mode (OPS-309)

`lg-devmode-renew` renews the webOS Developer Mode session daily with up to one
hour of jitter and catches up after downtime; the beamer can be off. It retries
three times after 1, 5 and 15 minutes, logs HTTP/LG status and validated remaining
time, and keeps the last success and failed calendar-day streak in
`/var/lib/lg-devmode-renew/state.json`. Run manually with
`sudo systemctl start lg-devmode-renew`; inspect `journalctl -u lg-devmode-renew`.
Two consecutive failed days send one notice per streak through the existing
encrypted Gateway email destination (Amy) and managed mail relay. Alerts go by
email only; Telegram is deferred until hsb0 has a declared Telegram target.
A delivered failure notice is followed by one recovery notice. Failed recovery
delivery gets one initial attempt and at most three retries on later runs, then
is dropped with a journal entry; channels without a sender are dropped immediately.
At most one queued recovery is processed per run. A refused or corrupt state file
is quarantined as `state.json.corrupt-<timestamp>` with a `state-reset` journal
entry, and renewal continues with fresh state; this can repeat a previous alert.
Missing configured credential files are checked by the script, logged as
`credential-missing`, and exit with status 3. The unit is never silently skipped.
The renewal start timeout is 30 minutes, covering the 1400-second bounded work
plus 400 seconds of margin with hsb0's email transport.

Credential and notification paths, the state directory, and curl/Docker/sendmail
commands are fixed by Nix at build time. Environment variables such as
`CREDENTIALS_DIRECTORY`, `STATE_DIRECTORY`, and `LG_DEVMODE_*` cannot override
them; path changes require a reviewed rebuild. File reads reject relative and
traversal paths and require regular files; token and email config custody checks
remain in place. Optional transports are enabled only by declared Nix paths.

After the approved deployment, run `sudo systemctl start lg-devmode-notify-test`
once and inspect `journalctl -u lg-devmode-notify-test`. This invokes
`--test-notify` with the same protected paths, mail relay and sandbox, sending one
`[TEST] LG Developer Mode renew alert path check` email without reading the LG
token, touching renewal state or calling LG. Status 0 means relay acceptance;
status 2 means failure or no transport. Confirm receipt in Amy's inbox as well.

Replace the token using `just edit-secret secrets/hsb0-lg-devmode-token.age`
(agenix), preserving one line `LG_DEVMODE_TOKEN=<64 hex characters>`; apply it in
the normal approved hsb0 deployment. Developer Mode reinstallation changes the
token. Never send it by message, print it, or put it in a command argument.

### Clean Up Disk Space

```bash
ssh mba@192.168.1.99 "cd ~/Code/nixcfg && just cleanup"
```

### ZFS Scrub (Manual)

```bash
ssh mba@192.168.1.99 "sudo zpool scrub zroot"
```

### View Logs

```bash
# Current boot
ssh mba@192.168.1.99 "journalctl -b -e"

# Previous boot
ssh mba@192.168.1.99 "journalctl -b-1"

# Follow logs
ssh mba@192.168.1.99 "journalctl -f"
```

---

## Troubleshooting

### AdGuard Home Not Responding

```bash
ssh mba@192.168.1.99
systemctl status adguardhome
journalctl -u adguardhome -n 50 --no-pager
sudo systemctl restart adguardhome
```

### DNS Not Resolving

1. Check if AdGuard Home is running
2. Check upstream DNS: `dig @1.1.1.1 google.com`
3. Check AdGuard config: `sudo cat /var/lib/AdGuardHome/AdGuardHome.yaml`

### DHCP Not Assigning IPs

1. Check AdGuard Home status
2. Verify DHCP is enabled in config
3. Check static leases file: `/run/agenix/static-leases-hsb0`

---

## Security Policy (SSH Hardening)

### The Markus-Only Rule

As a personal infrastructure server, `hsb0` allows SSH access **ONLY** for the `mba` user using Markus' authorized keys.

**Hokage Override:**
The `hokage` module (role `server-home`) automatically injects external developer keys (omega@\*). To prevent this, we use `lib.mkForce` in the NixOS configuration:

```nix
users.users.mba.openssh.authorizedKeys.keys = lib.mkForce [
  "ssh-rsa AAAAB3..." # mba@markus
];
```

**Verification:**

```bash
ssh mba@192.168.1.99 'cat ~/.ssh/authorized_keys'
# Should show ONLY mba@markus
```

---

## Emergency Recovery

### If SSH Fails

1. Physical access to Mac mini required
2. Connect keyboard and monitor
3. Login as `mba` or `root`

### Network Fallback

If hsb0 is completely down:

- Devices will use fallback DNS (1.1.1.1) if configured.
- Static IPs continue working.
- DHCP renewals will fail (24-hour lease).

### Recovery Scenarios

| Scenario               | Impact                     | Action                                                                                      |
| ---------------------- | -------------------------- | ------------------------------------------------------------------------------------------- |
| **AdGuard Home Stops** | CRITICAL - No DNS/DHCP     | `sudo nixos-rebuild switch --rollback` or `sudo systemctl restart adguardhome`              |
| **DNS Broken**         | HIGH - No internet by name | `nslookup google.com 127.0.0.1`. If fails, check upstream DNS in AdGuard Web UI.            |
| **DHCP Broken**        | MEDIUM - New devices fail  | Verify `/run/agenix/static-leases-hsb0` exists and is valid JSON.                           |
| **SSH Lockout**        | MEDIUM - No remote access  | Connect monitor/keyboard, login as `mba`, and rollback. Check for `omega@*` keys in config. |

### Restore from Generation

```bash
# List available generations
sudo nix-env --list-generations -p /nix/var/nix/profiles/system

# Switch to specific generation
sudo nix-env --switch-generation N -p /nix/var/nix/profiles/system
sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
```

### Restore from Backup

**Restore static leases from git history:**

```bash
# Find the commit with the desired version
git log secrets/static-leases-hsb0.age

# Extract the file from a specific commit
git show COMMIT:secrets/static-leases-hsb0.age > secrets/static-leases-hsb0.age

# Verify and redeploy
agenix -d secrets/static-leases-hsb0.age | jq empty
just switch
```

**Restore from ZFS snapshot:**

```bash
# List available snapshots
zfs list -t snapshot | grep zroot

# Rollback to a snapshot (destroys newer data!)
sudo zfs rollback zroot/root@SNAPSHOT_NAME
```

**Emergency: Recover from Time Machine (on Mac):**

1. Navigate to `~/Code/nixcfg` in Time Machine
2. Restore desired files
3. Commit and push: `git add . && git commit -m "restore: from Time Machine backup"`
4. Deploy to hsb0: `ssh mba@hsb0 "cd ~/Code/nixcfg && git pull && just switch"`

### Backup Frequency

| Backup Type        | Frequency                 | Location               |
| ------------------ | ------------------------- | ---------------------- |
| Git repository     | On each commit/push       | GitHub (remote origin) |
| ZFS auto-snapshots | Hourly/Daily (if enabled) | Local zroot pool       |
| Time Machine       | Automatic (on Mac)        | External drive / NAS   |

**Last Verified:** TODO - Set date after verification

**Note:** Check if ZFS auto-snapshots are enabled in configuration:

```bash
ssh mba@hsb0 "grep -A5 'autoSnapshot' ~/Code/nixcfg/hosts/hsb0/configuration.nix"
```

---

## Related Documentation

- [OPENCLAW-RUNBOOK.md](./OPENCLAW-RUNBOOK.md) - Full OpenClaw operational runbook
- [Static Leases](../README.md#static-dhcp-leases) - Managing DHCP leases

## JoeDesk Results producer (JOED-20, disabled)

`nixcfg.joeResultsProducer.enable = false` is intentional. This local delivery
does not change the board deployment pin or enable a writer. The module requires
a separately reviewed ingress endpoint, pinned ingress IP/TLS hostname, and an
authoritative **v2** household producer snapshot at `householdPath`. It rejects
legacy JSON. No fixtures are selected by the service. No LIVE mode or Gateway
client exists in the producer.

When separately enabled, the executor's optional capture writes
`/var/lib/paper-desk-executor/results-input.jsonl` before admission pruning,
recon compaction and ordinary saves. Each hash-chained, fsynced line is a whole
capture cut, containing only owned Stage-0 fills, commissions, close FX and
reconciliation evidence with hashed identifiers. Legacy, unowned and external
activity and policy KEEP symbols do not enter FIFO. The producer opens that
input read-only and keeps
its own append-only `/var/lib/joe-results-producer/results.jsonl`; retain and
back up **both** files. Never reconstruct them from the bounded executor ledger,
rotate them as ordinary logs, truncate a damaged tail, or reset sequence state
to satisfy the board. A damaged journal holds output for operator recovery.

FIFO uses independent `j`, `joe`, `joel` books and emits each closed portion.
Recorded opening and closing commissions remain rational through allocation
and conversion using that close's FX, then their sum must be exactly
representable at contract precision. Gross uses the exact quantity × price move
× close rate product. A gross or fee that cannot be represented in the
contract's eight fractional digits holds the whole snapshot; nothing rounds.
Source quantities, prices, commissions and broker-position evidence must be
decimal strings; numeric financial inputs are refused rather than stringifying
an already rounded binary value. Missing fees/close FX also hold the entire
snapshot. USD close FX
must have been observed within 60 seconds of the execution; old fills never
receive today's rate. EUR uses identity FX. Existing open lots can seed the
book, but round trips closing before capture began are omitted. `trackingStart`
is the Vienna date capture began; display earlier coverage as **since that
date**, never as a complete lifetime result.

Daily equity comes only from fresh per-desk `moneyEvidence` and `historyBasis`
in validated household v2 input. The last observation on each Vienna date wins;
dates without observations are omitted. Day realised net, fees and trade counts
sum every included closed portion on that Vienna date across **all** desks,
including trades later than an equity observation. A traded desk without an
equity observation has `equityClose: null`, never invented equity. The vendored
revision-3 validator rejects missing traded desks, wrong counts and inexact net/fee sums
on full-coverage days. Both legs' fees are charged to the closed portion.
Basis IDs and original observation times remain in the accumulated journal.
**Pinned Results at JoeDesk
`b323c0a57c1440690f85ae35e4e53ade25739b74` (manifest revision 3) forbids
a basis field in `days[]`.**
The board cannot compare those bases over Results until JoeDesk approves a
contract-set revision; do not add an unversioned extension locally.

KEEP fills are excluded at capture and again at FIFO, including pre-existing
captured fills. They contribute nothing to trades, day counts, realised net or
fees. The protected SXR8/TSLA floor cannot be removed.
Results never contains account/order IDs, receipts or broker account equity.
The pre-masked hint `DU…0597` is recorded only in the local household handoff;
raw health account values are discarded before any producer write.

`safety.executor` in the **household** contract is the home of executor status,
halt, brakes and gateway reachability. The producer validates that exact fragment
and journals it for the household owner; it does not publish a second household
snapshot. Concrete owned-fill quantity vs complete broker-position evidence can
produce `executor_broker_disagreement` there and in Results' permitted `reason`.
Foreign/netted residuals and incomplete broker cuts do not prove disagreement;
gateway reachability changes alone never do. The optional executor listener on
`127.0.0.1:8471` serves only `GET /v1/health`; no intent/admin/halt route is exposed.

The Results runner posts one `results.v2` snapshot to the configurable board
origin at **`POST /joe/inbox/results`**, with `Content-Type: application/json`
and the contracts package's 8 MiB limit. Authentication uses the **same** raw
machine token as the household pusher: systemd `LoadCredential` copies
`config.age.secrets.joe-board-push-token.path` into a private credential
directory. The runtime reads only that copy and sends `Authorization: Bearer …`.
There is no new secret or token value in Nix, Git or logs.

It attempts a fresh, strictly increasing producer sequence every 25 seconds,
reserving it durably before sending. Failed or ambiguous sends burn the
sequence, including across restart. Generated time comes from the system clock;
an explicitly requested future instant is clamped to now. A clock rollback
holds output until time catches up, without stamping ahead. The unit orders
after `time-sync.target`; verify hsb0 NTP is synchronized before enablement.
Board receipt rejects generation more than 5 seconds ahead with `clock_ahead`.
Retries use 1/2/4/8/16/25-second bounded backoff, capped by the original 25-second
cycle deadline so request time does not extend the cadence. Every retry builds
a new snapshot and sequence. It never sends `receivedAt` or `X-Joe-Received-At`;
ingress stamps receipt time and uses `acceptSnapshot('results')`. HTTP redirects
are refused. A 200 updates the last-good snapshot; 422 retains it and logs only
an allowlisted reason and up to 20 safe `{path, rule}` pairs. 400/401/413/503
and network failures also back off with value-free diagnostics. The board is
stale after 60 seconds without an accepted push; retries do not fake freshness.

JOED-27 is merged at `b323c0a57c1440690f85ae35e4e53ade25739b74`.
The complete self-contained `contracts/` directory (manifest revision 3,
including `vienna-date.mjs`) is vendored byte-for-byte. `contracts.lock.json`
pins its source revision, each file's byte count and SHA-256, and set digest
`2c85a6efca259e352b879f4d6efd514755ab1d99a0b15149fb1a155b77c1aa7d`.
`verify-contracts.mjs` checks the complete file set and reproduces JoeDesk's
`scripts/check-release.mjs` set hash: SHA-256 of the UTF-8 compact JSON array
of sorted `{path,size,sha256}` entries with `contracts/`-prefixed paths.
Build/CI checks reject changed, missing, extra or symlinked contract files,
including a changed closure with a rewritten per-file lock.
CI also runs `scripts/test-joe-results-contracts-pin.py`: it fetches the exact
lock revision via the existing private Nix GitHub transport and recreates the
closure in a temporary directory, checking bytes and both digest layers. Fetch
failure is fatal in GitHub Actions; unavailable local/offline sources explicitly
print SKIP. `--source <checkout>` proves a clean local checkout at the exact pin.
The deterministic CPU test covers 4,320 synthetic fills across three desks over
60 Vienna days in each DST season, including KEEP, with a 10,000 ms CPU bound
for snapshot build plus shared validation. It checks the 8 MiB served-size limit
including the board's `receivedAt` overhead; no broker or account data is used.

Coverage uses the executor history's explicit `fromInclusive`/`toExclusive`
bounds minus gaps, persisted with capture cuts even when fills do not change.
The producer unions proven intervals across restart, using the vendored Vienna
date helper for 23/25-hour DST days. Missing/unknown bounds, any uncovered part
of a closed day, a mid-day window start, and the current day emit
`"coverage":"partial"`; a stale capture never extends proof to generation time.
Full days omit `coverage`, using the README's documented default of `"full"`.
The producer and fixture ingress call the vendored validator directly: partial
days skip day/trade reconciliation while schema and trade checks still apply;
full days reconcile every trading desk with exact counts and decimal sums.
KEEP contributes nothing to either array, including partial-day totals.
The revision-3 closed reason enum no longer permits `results_not_wired`.
The module remains disabled; paper rehearsal and coordinator sign-off are
still required before a separately approved enablement/cutover.
The systemd sandbox uses executor uid/gid 1000 with read-only input mounts,
one writable state directory, empty capabilities, no added groups/Docker socket, and
IP egress limited to loopback and the pinned ingress address. The private hosts
file resolves the TLS hostname without DNS egress. Endpoint and health paths
are fixed by configuration/code; systemd's IP filter operates at address scope.

Paper proof, for the operator **after** separate enablement approval:

1. On the workstation/CI, run `bash tests/T100-joe-results-producer.sh` and
   `bash tests/T93-paper-desk-executor.sh`. Confirm the vendored bytes against
   `contracts.lock.json`. Keep synthetic compaction, torn-write and gateway-flap
   simulations in this lab; hsb0 remains a production paper host.
2. Before the approved hsb0 switch, retain its previous generation and compatible
   board/pusher/executor pins plus private backups of both Results journals (if
   present). Record the rollback path on JOED-20/OPS. Configure the board
   endpoint, household v2 evidence path, complete KEEP policy and IP/TLS pin in
   the reviewed Nix change. Verify the revision-3 contract pin and resolve the
   basis wire gap, exact decimal source evidence and household fragment consumption with
   JoeDesk/Amy first. Follow the normal remote NixOS build and
   human-controlled switch procedure; no local NixOS build on macOS.
   csb0 edge needs an exact-path token-only router for `POST /joe/inbox/results` (JoeDesk README:425–429; OPS-354, PR #1007), live before producer enablement.
3. On hsb0, inspect `systemctl status joe-results-producer` and the unit sandbox.
   Read `http://127.0.0.1:8471/v1/health` privately and verify paper Gateway
   configuration, halt and brakes. Do not copy its raw body/account into tickets,
   Git, public logs or fixtures. Verify non-GET/other paths return 404 and the
   optional listener is bound only to loopback. The producer never submits an
   intent to perform this check.
4. Observe an **already authorized paper** desk open/partial close/full close
   through the normal desk workflow. Compare private broker fill/commission/FX
   evidence to every Results portion and Vienna close; check original basis IDs
   in the journal. Verify KEEP holdings are untouched. Observe two accepted
   Results generations within 30 seconds, strictly increasing sequence and
   server-stamped receipt; board freshness must remain below 60 seconds. Do not
   create trades or force a gateway outage solely for this proof.
5. Restart only the producer through the approved procedure and confirm its
   sequence advances and accumulated history is unchanged. Verify production
   evidence contains no fabricated pre-tracking days. Use the offline fixtures
   for a true disagreement and a clean gateway flap; do not tamper with the
   production ledger. Record value-free counts/digests and Amy's explicit sign-off
   on JOED-20. If proof fails, disable the producer through the reviewed config,
   retain both journals and the prior pins, and keep Results explicitly unwired.

Open ingress gates: exact route/auth and credential handoff; response receipt
contract; household health/account fragment consumption; a versioned per-desk
close-basis field; authoritative household evidence availability and close-FX
sampling cadence; immutable deployment pins and Amy's paper reconciliation
approval. Local fixture ingress is a test adapter, not an installed service.
