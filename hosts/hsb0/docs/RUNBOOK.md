# Runbook: hsb0 (DNS/DHCP Server)

**Host**: hsb0 (192.168.1.99)  
**Role**: Primary DNS and DHCP server running AdGuard Home  
**Criticality**: HIGH - Network infrastructure depends on this

---

## AdGuard admin rotation (OPS-372)

Desk decision `aafbeaa2` is answered (option 1). OPS runs this procedure under that decision. Keep
both hosts in one reviewed PR; merge only with all three ciphertexts provisioned,
T105/T47 green, and independent approval recorded. Missing either host's users
ciphertext fails evaluation on both hosts. Never switch a preparation branch,
print credentials or verifiers, globally rekey, or rewrite Git history.

### Back up both hosts before generation or switching

Keep a live root session to each host open **by IP or tailnet IP** throughout
cutover. DNS names may stop resolving if AdGuard fails. On each host, from the
repo root, run as root:

```bash
sudo nix-shell -p python3 --run 'python3 -' <<'PYBACKUP'
import datetime, os, pathlib, shutil, subprocess, sys
os.umask(0o077)
try:
    backup = pathlib.Path('/var/backups/ops372') / datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    backup.mkdir(parents=True, mode=0o700)
    backup.parent.chmod(0o700)
    (backup / 'generation').write_text(os.readlink('/run/current-system') + '\n')
    generations = subprocess.run(['nix-env', '--list-generations', '--profile', '/nix/var/nix/profiles/system'], check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
    (backup / 'generations').write_bytes(generations)
    for name in ('AdGuardHome.yaml', 'data/leases.json'):
        target = backup / pathlib.Path(name).name
        shutil.copyfile(pathlib.Path('/var/lib/private/AdGuardHome') / name, target)
        target.chmod(0o600)
    for name in ('generation', 'generations'):
        (backup / name).chmod(0o600)
except Exception:
    sys.exit('Backup failed; do not proceed.')
print('backup complete')
PYBACKUP
```

Do not display backup contents: they include runtime verifiers and lease data.
Keep the previous three encrypted files and their reviewed Git revision for
later rotations. Record backup paths and generation references on OPS-372.
`/var/backups/ops372` holds lease data and the old verifier (root 0700); trash it after the cutover is verified and one clean day has passed, and record that on OPS-372.

### Generate once on hsb0, encrypt three times

Run the following **only on hsb0**, as one root Python process from the reviewed
repo root. It creates a new candidate directory under root-only tmpfs, refuses to
overwrite an earlier attempt, derives recipients from the plain declarations,
and sends encryption input only through stdin. `markus` means the existing
Markus key set; no host receives the plaintext. The hsb8 users declaration
intentionally excludes `gb`. Record that recipient boundary on OPS-372.

```bash
sudo nix-shell -p age 'python3.withPackages (p: [ p.bcrypt ])' --run 'python3 -' <<'PYROTATE'
import bcrypt, json, os, pathlib, secrets, subprocess, sys
os.umask(0o077)
try:
    if os.geteuid() != 0:
        raise ValueError()
    fs = subprocess.run(['findmnt', '-n', '-o', 'FSTYPE', '-T', '/run'], check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.strip()
    if fs != b'tmpfs':
        raise ValueError()
    work = pathlib.Path('/run/ops372')
    work.mkdir(mode=0o700)  # Existing attempt: stop, inspect status, do not overwrite.
    output = work / 'ciphertexts'
    output.mkdir(mode=0o700)
    password = secrets.token_urlsafe(24).encode()
    verifiers = [bcrypt.hashpw(password, bcrypt.gensalt(rounds=12)).decode() for _ in range(2)]
    names = ('adguard-admin-password.age', 'hsb0-adguard-users.age', 'hsb8-adguard-users.age')
    payloads = [password] + [json.dumps([{'name': 'admin', 'password': value}]).encode() for value in verifiers]
    for name, payload in zip(names, payloads):
        recipients = json.loads(subprocess.run(
            ['nix', 'eval', '--json', '--file', 'secrets/secrets.nix', '--apply', 's: s.' + json.dumps(name) + '.publicKeys'],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        ).stdout)
        if not recipients:
            raise ValueError()
        args = ['age', '--encrypt', '--output', str(output / name)]
        for recipient in recipients:
            args.extend(['--recipient', recipient])
        subprocess.run(args, input=payload, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with (work / 'admin').open('xb') as handle:
        handle.write(password)
        os.fchmod(handle.fileno(), 0o400)
except Exception:
    sys.exit('Generation failed; do not switch or publish partial candidates.')
print('3 ciphertexts written')
PYROTATE
```

The only temporary plaintext file is `/run/ops372/admin` (root:root, 0400); it
stays on hsb0 tmpfs solely for the probe below. Never copy it to hsb8 or a
workstation. On abort, remove it immediately using the probe's unlink cleanup or root Python
`Path('/run/ops372/admin').unlink(missing_ok=True)`. Never put plaintext in
persistent Trash.
Clean failed candidate directories only through the operator's trash procedure.
Do not reuse a partial set. Candidate ciphertexts may leave hsb0; credentials,
verifiers, private keys, and runtime YAML may not.
Copy ciphertexts off hsb0 with `scp`/`install`/`rsync`, never `cat`.

OPS installs only these three ciphertexts into `secrets/` in its review branch
and stages them before flake evaluation. Do not declare the Markus-only
`adguard-admin-password.age` in any host or module. Its plaintext is recoverable
only by Markus; each host receives only `/run/agenix/<host>-adguard-users`
(root:root, 0400). Run T105 with the flake-pinned `NIXPKGS_LIB`, T47 and full-host
evaluations, then obtain review and merge the one PR. Retain the root tmpfs file
only until both post-switch probes finish; remove it on any abort or delay and
arrange Markus's own status-only probe instead.

### Switch, verify, remove temporary plaintext

On each host, use `gitpl && just switch` only after approval and merge. Agenix
activation requires the switch; restarting a container or AdGuard alone is
insufficient. `restartTriggers` tracks ciphertext content, so secret-only
rotations restart AdGuard. Verify service state and DNS/DHCP using the existing
host tests (lease contents must stay private). Also require
`adguardhome-users-health.service` to pass after its next minute tick and the
`/run/AdGuardHome/admin-locked` marker to be absent.

Immediately after both switches, run this as root **on hsb0**. The hsb8 address
is discovered from Tailscale and must be in the tailnet IPv4 range; credentials
travel to hsb0 on loopback and hsb8 only through the encrypted tailnet. Redirects
are disabled. It prints HTTP status codes only, never bodies, cookies or headers,
and removes the plaintext in `finally`, including on failure.

```bash
sudo nix-shell -p python3 --run 'python3 -' <<'PYLOGIN'
import ipaddress, json, pathlib, secrets, subprocess, sys, time, urllib.error, urllib.request
admin = pathlib.Path('/run/ops372/admin')
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
def status(base, path, payload=None):
    request = urllib.request.Request(base + path, data=payload,
        headers={'Content-Type': 'application/json'} if payload is not None else {},
        method='POST' if payload is not None else 'GET')
    for attempt in range(4):  # Initial request plus up to three connection-error retries.
        try:
            with opener.open(request, timeout=10) as response:
                return response.status
        except urllib.error.HTTPError as error:
            return error.code  # Never retry HTTP results, including a positive-login 403.
        except (urllib.error.URLError, TimeoutError):
            if attempt == 3:
                raise
            time.sleep(10)
try:
    password = admin.read_text()
    state = json.loads(subprocess.run(['tailscale', 'status', '--json'], check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout)
    peers = [p for p in state['Peer'].values() if p.get('HostName') == 'hsb8']
    if len(peers) != 1:
        raise ValueError()
    addresses = [ip for ip in peers[0]['TailscaleIPs'] if ipaddress.ip_address(ip) in ipaddress.ip_network('100.64.0.0/10')]
    if len(addresses) != 1:
        raise ValueError()
    valid = json.dumps({'name': 'admin', 'password': password}).encode()
    invalid = json.dumps({'name': 'admin', 'password': secrets.token_urlsafe(24)}).encode()
    for base in ('http://127.0.0.1:3000', 'http://' + addresses[0] + ':3000'):
        positive = status(base, '/control/login', valid)
        negative = status(base, '/control/login', invalid)
        unauthenticated = status(base, '/control/status')
        print(positive, negative, unauthenticated)
        if positive != 200 or negative not in (400, 401, 403) or unauthenticated not in (302, 401, 403):
            raise ValueError()
except Exception:
    sys.exit('login check failed')
finally:
    admin.unlink(missing_ok=True)
PYLOGIN
```

Record only status codes, health/unit results, and DNS/DHCP pass/fail on OPS-372.
Markus can later use the encrypted admin password through his own private
recovery flow; OPS never decrypts the Markus-only file.

### Immediate first-cutover rollback

If the `adguardhome` unit, DNS, or DHCP fails, immediately run
`nixos-rebuild switch --rollback` in the live root session on the affected host,
using its IP connection. This restores the previous generation, including its
old compromised verifier, to recover availability. Record that exposure and the
rollback generation on OPS-372, verify DNS/DHCP recovery, and fix forward with a
reviewed candidate. Keep the dated YAML/leases backup for controlled recovery;
never dump it to a terminal. Remove `/run/ops372/admin` immediately on abort.
If the unit and DNS/DHCP are healthy and only the login probe fails, stay forward:
the UI is locked or carries an unknown verifier, which is the safe state.
Investigate `adguardhome-users-health.service` and `/run/AdGuardHome/admin-locked`,
record the findings on OPS-372, and fix forward. Never roll back for a login-only failure.
If the negative login or the unauthenticated GET returns 2xx, the UI is open, not
locked: treat it as an incident (stop the UI or roll back) and record it on
OPS-372; this is never a stay-forward case.

For subsequent rotations, revert all three ciphertexts together to the recorded
known-good revision via PR and CI, then switch both hosts.

### Runtime failure behaviour

The upstream store template contains no users. After upstream preStart and the
existing static-leases hook, the injector runs as DynamicUser, reads the private
systemd credential and atomically replaces runtime YAML (0600, same ownership).
No root merge or sandbox relaxation is used. `LoadCredential` and agenix are
only declared when the ciphertext exists. An empty `SetCredential` fallback
lets a missing runtime source reach the injector instead of failing in systemd.
Missing or malformed users cause a fresh random bcrypt user and loopback-only
HTTP binding, preserving DNS/DHCP settings. The unknown password is discarded;
the runtime marker causes the minute health check to fail visibly. Restoring a
valid secret and restarting recopies the template, restores the configured HTTP
listener and clears the marker. Template/parser/write failures still prevent
AdGuard starting, because starting a users-less template would open admin access.
The pre-existing static-leases preStart failure path is outside this change.
Password changes in the UI are overwritten on restart; rotate through agenix.

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
13 MiB for the app's 12 MiB floor-plan uploads. The more specific
exact `/ops/api/import` location permits 257 MiB for the raw application/zip
body capped at 256 MiB, keeps the same LAN access rules and proxy settings, and
forwards to exactly `/api/import`. nginx hides upstream
Cache-Control and sends a single `no-store` policy.

The native `hausnetz.service` listens on `0.0.0.0:8377`, with TCP 8377 opened
only on `br-+` and `docker0`, never the LAN interface. mDNS discovery opens
UDP 5353 only on `enp2s0f0`. SSDP uses fixed source UDP 1901 and opens
replies only on that same interface (`ssdpInterfaces` defaults to
`mdnsInterfaces`), never globally or on Docker bridges. UDP 1900 remains the
remote SSDP query destination, not an additional inbound opening. The module
also allows AF_NETLINK for Go interface enumeration. State starts empty in
`/var/lib/private/hausnetz` (DynamicUser, exposed as `/var/lib/hausnetz`), with no
seed or DHCP leases integration. Limits: 512M memory, 50% CPU quota, nice 10.
The `br-+` iptables wildcard intentionally covers every user-defined Docker
bridge, not only hsb0-home's bridge; this round leaves that rule unchanged.

The private flake input is pinned to `577c1590b43dea87e43f101b8e9e8bfa130ecfcf`
(`v261017075838.0.0`, OPS-355), with `discovery.passive = true` (ARP/DHCP
listener on `enp2s0f0` only; the unit gains `CAP_NET_RAW` and `AF_PACKET`).
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

For each pin bump, update the explicit revision in `flake.nix` and only the
hausnetz node in `flake.lock`; verify the release revision and NAR hash and
run the local contracts and full CI evaluation below. On hsb0, after the
reviewed change is merged and pulled, run `just nix-build` first (root fetch
and build), then `just switch`. Roll back this bump by reverting its reviewed
commit(s), restoring the previous pin
`680a1d4eebf0050158eab4c73ead818cbddba32b` (`v261016221544.0.0`), its lock
node and the T99 pin; the options are unchanged between the two releases.
Repeat the same root-build-before-switch sequence. Retain `/var/lib/private/hausnetz` and
download a state backup from `GET /ops/api/export` on the LAN before activation;
reverting a source pin does not undo imported data. Both nginx snippets
(`hsb0-home-hausnetz.conf` and `hsb0-home-inflight.conf`) are compose restart
triggers, so a normal switch recreates `hsb0-home` when either changes.

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
Every other host is still evaluated. Skips remain in stdout and the detail log;
the published plan keeps Pharos's accepted keys. `all_host_eval_passed` means
every host evaluated on that machine passed. A credentialed
evaluator sets `canEvaluatePrivateInputs`; the deployment target itself is never skipped.
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
`/ops/` from the LAN, and that direct LAN connections to port 8377 fail. From
the LAN, POST an `application/zip` body larger than 13 MiB to
`/ops/api/import?dry_run=1`: it must reach the app (for example, 422 for an
invalid archive), rather than returning nginx's 413. This checks the live
import location after container recreation. Roll back the OPS-207 commit and rebuild
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

The session supervisor exits 0 for a healthy session when alerts are intentionally disabled. Each disabled run logs exactly one `warning: alert adapter disabled; reason=...` line: `alert-enable-false`, `transport-none`, `receiver-parked`, or `receiver-not-declared` describes configuration, not a session failure. On confirmed recovery it retires pending alerts with a value-free record, without claiming delivery; unenrolled chat is also retired while email continues. Session failures exit 3; delivery failures with a configured adapter exit 2 and retain their retry state.

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
