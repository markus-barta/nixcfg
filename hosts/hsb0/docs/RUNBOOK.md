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

**URL**: http://hsb0/hostdash/ or http://hsb0.lan/hostdash/
**Container**: `hsb0-home` | **Unit**: `hsb0-home-dashboard` | **Source**: `github.com/markus-barta/hostdash`

The dashboard is mounted from `/etc/hostdash/hsb0/share/hostdash-hsb0` and
reconciled by NixOS. Restart it without touching the rest of the compose stack:

```bash
sudo systemctl restart hsb0-home-dashboard
```

### hausnetz (OPS-207)

After HNET-237 activation, hausnetz is the front page at `http://hsb0.lan/`.
The host-local `docker/front-page-nginx.conf` replaces the shared vhost only
on this host. The existing container, host-gateway mapping and mounts remain.
`/ops` and `/ops/...` GET/HEAD requests return 301 to `/` and `/...`, preserving
the raw escaped path, query and browser fragment. Non-GET/HEAD requests are
internally rewritten to the root API so a legacy POST retains its method and
body; legacy imports reach the same exact `/api/import` location as new ones.
Both root hausnetz and old-prefix entrypoints retain the IPv4 LAN-only
`192.168.1.0/24` policy. Tailnet, IPv6 and same-host/bridge clients receive
403 by design; redirects run after access checks. The app keeps its 13 MiB
limit and `/api/import` keeps 257 MiB for the raw ZIP capped at 256 MiB.
SSE buffering/cache stay disabled, the read timeout stays one hour, and nginx
still emits no-store, noindex/nofollow and no-referrer.

HostDash remains at `/hostdash/`, including its relative `config.js`, optional
`manifest.json` and `status/status.json`. `/status/status.json`, `/config.js`
and `/manifest.json` remain available for old consumers and already-open
boards. `/inflight/` and `/videos/` keep their existing aliases and policies.
Other hosts continue using the shared HostDash vhost at `/`.

Deploy and verify the hausnetz release at `/ops/` first. Then apply this nginx
change and recreate only the front-page container through compose reconciliation.
Keep the prior NixOS generation and pinned hausnetz revision as the rollback
path: revert this routing commit through a review PR and rebuild using that
pin, preserving `/var/lib/private/hausnetz`. A cached 301 still lands at `/`
after rollback, so verify both entrypoints during rollback. Archive the live
nginx config, previous NixOS generation and exact pin on the OPS ticket before
activation. This draft does not update the hausnetz release pin or deploy.

The native `hausnetz.service` listens on `0.0.0.0:8377`, with TCP 8377 opened
only on `br-+` and `docker0`, never the LAN interface. mDNS discovery opens
UDP 5353 only on `enp2s0f0`. SSDP uses fixed source UDP 1901 and opens
replies only on that same interface (`ssdpInterfaces` defaults to
`mdnsInterfaces`), never globally or on Docker bridges. UDP 1900 remains the
remote SSDP query destination, not an additional inbound opening. The module
also allows AF_NETLINK for Go interface enumeration. State starts empty in
`/var/lib/private/hausnetz` (DynamicUser, exposed as `/var/lib/hausnetz`), with no
seed. Since `v261017120723.0.0` (HNET-228) the DHCP leases are optional
enrichment: because AdGuard runs DHCP here, `discovery.leasesFile` defaults to
`/var/lib/AdGuardHome/data/leases.json`; the root `hausnetz-leases` service
(path unit on change plus a 5-minute timer) copies it to
`/run/hausnetz-leases/leases.json` (0640 root:hausnetz-leases, 8 MiB bound) and
hausnetz reads only that copy via a supplementary group. Limits: 512M memory, 50% CPU quota, nice 10.
The `br-+` iptables wildcard intentionally covers every user-defined Docker
bridge, not only hsb0-home's bridge; this round leaves that rule unchanged.

The private flake input is pinned to `41063ad31a7a3911abb3172a741a311f8ff099af`
(`v261020103312.0.0`, HNET-252/257/258: sidebar, keyboard and sheet-focus fixes, UI + QA tooling; module unchanged since `v261017204833.0.0`, OPS-355; the web source HNET-238 and the Starlink dish status HNET-48 keep their module defaults (on, owner-approved 2026-10-17): outgoing only, no firewall or capability change; `discovery.webCheck = false` or `starlink = false` turns either off), with `discovery.passive = true` (ARP/DHCP
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
`037a6b5f5580937f7e343c0ea04dadefe3f32889` (`v261017161630.0.0`), its lock
node and the T99 pin, and restoring the `webCheck = false` line (that release has
no `starlink` option).
Repeat the same root-build-before-switch sequence. Retain `/var/lib/private/hausnetz` and
download a state backup from `GET /api/export` (legacy `GET /ops/api/export` redirects) on the LAN before activation;
reverting a source pin does not undo imported data. The nginx snippets
(`hsb0-home-hausnetz.conf`, `hsb0-home-inflight.conf` and `hsb0-home-videos.conf`) are compose restart
triggers, so a normal switch recreates `hsb0-home` when any of them changes.

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
verify `/`, its assets, API reads/writes and `/api/events` from the LAN.
Check `GET /ops/api/meta?check=a%2Fb&check=two` returns a 301 Location of
`/api/meta?check=a%2Fb&check=two`, and `/ops/?check=1#/devices` reaches
`/?check=1#/devices`. Verify `/hostdash/`, `/hostdash/config.js`,
`/hostdash/status/status.json`, `/status/status.json`, `/inflight/` and `/videos/`.
Confirm both root and old-prefix app requests are refused off-LAN and direct
LAN connections to port 8377 still fail. POST an invalid `application/zip`
body larger than 13 MiB to both `/api/import?dry_run=1` and
`/ops/api/import?dry_run=1`: both must reach the app (422 for invalid ZIP),
with no redirect or nginx 413. Confirm another host's board is unchanged.
Preparing this configuration does not deploy it.

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

### Video overview page (OPS-380)

**URL**: http://100.64.0.6/videos/ (tailnet) or http://hsb0.lan/videos/ (home). Never public: hsb0 has no port forward.

VID's scored overview of the planned videos (AEON-1480): one self-contained `index.html`
(inline CSS and JS, no external requests, no private or client content). Same pattern as the
In-flight page: `/var/lib/videos` (mba, 0755, tmpfiles), mounted read-only at `/srv/videos`,
location from `docker/hsb0-home-videos.conf` through the HostDash include point, same headers,
dotfiles return 404. Push atomically:

```bash
scp -q index.html mba@100.64.0.6:/var/lib/videos/.index.html.tmp && ssh mba@100.64.0.6 'mv -f /var/lib/videos/.index.html.tmp /var/lib/videos/index.html'
```

---

## IB Gateway (paper) — enabled

**Status (2026-09-09)**: Compose service `ib-gateway` is **enabled** (paper) on default compose. Credentials via agenix. Full notes: **[IB-GATEWAY.md](./IB-GATEWAY.md)**.

**Container**: `ib-gateway` | **API**: `100.64.0.6:4002` (Tailscale only) | **Data**: `/var/lib/ib-gateway/tws_settings` (uid/gid 1000)

Mac must **not** run Gateway or an SSH `-L` tunnel. Desks connect directly over Tailscale to `100.64.0.6:4002`. The live account (port 4001) stays OFF.

Alerts on this host are enabled with transport `email-agent-bus`: email uses the managed house relay, while chat stays skipped until the Aeon notifier key is enrolled. When `destinations.json` loads, a null key path or absent key file logs exactly one `grok notification not enrolled: Aeon notifier key absent, chat channel skipped` line per run, even if the private chat section is missing or unusable. If the destination file cannot load, both channels report `notification unavailable: configuration or receiver missing` when delivery is attempted. On confirmed recovery, skipped chat's pending state retires with a value-free record without claiming delivery; email still completes its own delivery and recovery sequence.

A healthy `api_ready` run exits 0 once email succeeds. Expected startup and authentication waits also exit 0 until both the outage and any restart recovery have lasted at least ten minutes. Halts and restarts exit 3 immediately; otherwise a known unhealthy session exits 3 once that alert threshold is reached. An enrolled but unusable chat configuration, an unreadable enrolled key, or failed email delivery retains the configured channel's retries and exits 2 while its event is undelivered, including when a session problem occurs in the same run. A nonzero mail relay result logs only `email notification failed: relay exit status N`. This unit accepts only exit 0, so an uncaught Python crash (exit 1) is red. Other fleet units retain their own exit conventions. Intentionally disabled adapters still log one `warning: alert adapter disabled; reason=...` line and retire stale alerts only on confirmed recovery.

## Paper desk executor admission (OPS-384)

The executor still binds only hsb0's tailnet address on TCP 8470. The host's
`tailnet-peer-sync.service` reads `tailscale status --json` every 30 seconds,
and after tailscaled or firewall starts/reloads. The configured rule requires
both `tag:paper-desk` and exact Tailscale `HostName=grok-amy-box`, mapping
the current IPv4 address to `amy`. Additional desks require explicit identity
rules; a rule can omit the hostname when the tag alone is the intended identity.
HostName is self-reported; the tag is the admission boundary.
OPS remains static at `100.64.0.14`; the executor admin allowlist is unchanged.

Static rules remain in `paper-desk-peers` and `agent-mailbox-peers` in raw
PREROUTING, before Tailscale's input acceptance. Each jumps to its own dynamic
sub-chain. The sync replaces only the dynamic chains using
`iptables-restore --noflush`, with matching source-specific filter rules.
A shared lock serializes these updates with the modules' firewall hooks.
Firewall hooks create the lock directory and wait at most 30 seconds; lock
or async trigger failure is logged without aborting the host firewall script.
A refused tailnet packet increments the final DROP counter; LOG is limited to
two packets per minute with a burst of two. Refusal alerts contain only the
host and port; kernel packet logs remain in the local journal.

The `1000:1000`, mode `0600` `/run/tailnet-peers/peers.json` is atomically
replaced inside a `root:1000`, mode `0710` directory. Ownership is set before
publication; the directory permits group traversal only, and `state.json`
stays root-owned with mode `0600`. Both containers run as
`1000:1000` and mount that directory read-only at `/run/tailnet-peers`.
Mounting the directory lets atomic file replacements become visible.
Neither container receives the tailscaled socket or new privileges. The
executor reads the snapshot on each request; missing, unsafe or malformed
snapshots allow only static peers. Tagged peers never gain admin permissions.
The reader accepts only this fixed production path; test overrides require
Node's test runner and a canonical file under the source checkout's
`tests/.tmp`. The sync accepts only resolved `/nix/store` settings paths,
with an explicit `--test-config` override restricted to `tests/.tmp`. The
settings file carries data only: the `tailscale`, `iptables-restore`,
`iptables-save` and `docker` paths are substituted into the script at build
time, and an unbuilt copy refuses to start.
No trading brakes, HALT, ledger, Gateway ports or Results enablement change.

A daemon/status/parse error retains the last good admission and alerts.
A malformed individual peer is skipped and alerted without freezing admission
or tag revocation for healthy peers. Changes to the admitted node set and
multiple nodes matching one rule produce deduplicated, value-free notices.
An explicitly removed tag or changed hostname revokes immediately. A node
absent from an otherwise valid status (including a transient empty map) keeps
its last good admission for `nixcfg.tailnetPeers.staleSeconds` (default 300
seconds), then expires. Status errors never age out the last good list.
After reboot, /run starts empty and admission is static-only until a valid
status is read. Headscale has no static-IP reservation feature; re-joins can
receive new addresses, so identity rules replace manual pin updates.

Admission alerts reuse the existing Gateway notifier's managed email adapter
(`notification_delivery.email_sender`, `docker-smtp-1`, destinations loaded
directly from the existing Gateway notification declaration by the root sync
process, with the same private-file custody checks). Missing notification
configuration cannot prevent identity sync from starting; adapter failures are
logged in the journal. State load/write and unexpected snapshot failures also
attempt a value-free alert through this adapter on every failed tick.
No new receiver, credential or channel is introduced. Alerts cover an online
configured peer missing from the installed admission rules, status/sync failures
(including escalation after two minutes), and increments of either refusal
counter. Pending notices are batched into one bounded relay call per tick,
survive relay failure and retry on the next sync;
identical delivered notices are bounded to once per five minutes. Relay
acceptance means queued mail, not proof of inbox delivery.

On hsb0, inspect without opening private state or credentials:

```bash
systemctl status tailnet-peer-sync.service tailnet-peer-sync.timer
journalctl -u tailnet-peer-sync.service -n 40 --no-pager
cat /run/tailnet-peers/peers.json
sudo iptables -t raw -L paper-desk-peers -nvx
sudo iptables -t raw -L agent-mailbox-peers -nvx
```

The stage-2 Headscale policy grants `amy@` and `tag:paper-desk` TCP access
only to `paper-desk:8470` and `paper-desk:8471`, where `paper-desk` is
hsb0's /32. That file labels itself staged; verify its activation through the
owning operations workflow. No broader ACL or csb0 change is required here.

## Agent mailbox admission (OPS-384)

The mailbox still binds only the tailnet address on TCP 8471. It resolves the
socket source to a caller identity from the same snapshot on every request;
forwarded headers and message bodies cannot claim an identity. Missing or
invalid data allows static OPS only, while the configured Amy inbox remains
available as a recipient. Existing SSE/long-poll connections check admission
every 15 seconds and close if their source is revoked. Use the sync status,
public JSON and mailbox refusal counter checks above. Private message storage
and all existing container hardening stay in force.

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

## JoeDesk household v2 local staging (OPS-392)

The pusher vendors the exact 17-file JoeDesk contracts rev 9 closure from
`84c47b647cf06a38a3f61ce7f928a10ed10eeef3`, set digest
`000045fb7843a16be95f6a7e42d46d4b4ecb34b0efd39fc987bee444817fc9d5`.
Unmapped stage0 rows now stage a complete pair with `desk:null`,
`reasons.desk:desk_unmapped`, and all five valuation fields null with individual
`not_exact_yet` reasons. KEEP rows retain `scope:keep`, `desk:null` and no desk
reason; mapped stage0 rows also have no desk reason. Older contract-set pairs
still fail closed: preserve state and obtain coordinator review before promotion.
See the [pusher README](../docker/joe-board-pusher/README.md) for enrollment,
recovery and rollback. Local staging is not board acceptance or deployment.

OPS-392 cycle binding keeps the stager isolated: only the pusher stores exact v1
POST bytes under `/var/lib/joe-board-pusher/v1-cycles/<seq>.json` (0600; directory
0700), after v1 settles and the stager reserves the sequence. Pair receipts and
the value-free append-only receipt log bind that sequence to a unique
`observationId`, `v1Sha256`, `v1RepliedAt` and POST outcome. A failed write or
1500 ms acknowledgement timeout records `v1Status: "v1_unbound"`, preserving
the POST result in `v1PostStatus`; v1 publication remains independent. The
stager has no body mount or body frame. The pusher prunes bodies using the
stager's retained pair sequence set (10 by default), including after reconnect;
preserve both stores and sequence high water on rollback. The executor's
existing read-only `/pusher-state` mount exposes `v2` and `v1-cycles` for the
operator collector. Matching timestamps alone never establish cycle proof;
require matching digest, sequence, observation and a successful POST receipt.

Desk state follows [rev 9 `desks[].state`](../docker/joe-board-pusher/contracts/data.schema.json):
`stuck` when any desk evidence is unavailable/stale, `working` for positions,
active orders or executions on the executor's current NY day, and `sit-out`
otherwise. Evidence comes from the pusher's existing broker position/all-open-order
replies and completed family execution cycles, using the same dated ownership
policy and shared 420-second freshness bound as its readers; unknown ownership is
unavailable, never inferred. Read-only `reqAllOpenOrders` runs on connect and
every 60 seconds via the existing 5-second maintenance tick, with one reply
in flight. Each reply starts a fresh `(orderId, clientId)` set; `openOrderEnd`
atomically replaces the previous set (even when empty) and stamps its own
completion clock. Pending replies retain the last completed set and clock;
without an end marker no overlapping request is sent, and the old clock expires
after 420 seconds to `stuck`. Publication and cached executor order rows never
renew it. A new connection generation discards the pending reply. Executions
already use read-only `reqExecutions` 30 seconds after each completed cycle,
with a 20-second request timeout and existing retry backoff; identical completed
replays renew activity evidence, missing `execDetailsEnd` cannot prove absence,
and unchanged money keeps its original timestamp. NY midnight requires a new
current-day execution reply, and the mirrored day function is tested against
executor `brakeUsage`, including DST and weekends. No executor API or code change is added. Desk action
says "Valuation is not exact yet."; money remains null with `not_exact_yet`.
KEEP rows retain their existing scope and reasons.

R14 (`household-v2-switch-set-r14-202610201330`) parses completed raw IB fill
times with the family classifier's `executionTime` path, compares epochs and
stores canonical ISO activity times. Client 229 belongs to J from
`2026-10-06T13:40:47Z` inclusive; one second earlier remains unowned.

R15 (`household-v2-switch-set-r15-202610201500`, rollback
`household-v2-switch-set-r14-202610201330`) adds intent-only
attribution for the configured executor clients (700/705). The pusher reads
`/var/lib/paper-desk-executor/ledger.json` through a read-only directory mount;
the executor source and authority stay unchanged. Exactly one place intent's
`result.bracket` client/parent-or-stop key, or flatten intent's submitted
`result.flattened` client/order key, must match the execution's `(clientId,
orderId)`. Retained rows without that key require an exact execution-ID/client/
account lookup in the executor's own executions first. Missing/pruned evidence,
ambiguity and desks outside the explicit table stay unclaimed; orderRef prefixes
never assign ownership. OPS-403 applies Amy's fixed intent-desk table:
`j → j`, `j2 → j`, `j5 → j`, `joe → joe`, `joel → joel`. The original intent
desk is kept on the internal attributed execution as `subDesk` and in history
evidence, with no rev 9 output field. Unknown desks emit the value-free
`executor_intent_desk_unclaimed` event with the desk token and fixed cause only.
KEEP is excluded first, and dated/static assignments including 229 are unchanged.
The shared rule covers v1 valuation and v2 activity; `v2_desk_state` includes
value-free matched/unmatched counts per executor client when available. Its
policy hash selects a new baseline without changing retained history or files.

R16 (`household-v2-switch-set-r16-202610201700`, rollback
`household-v2-switch-set-r15-202610201500`; OPS-404) generates v2 at the worker's
observation-receipt instant, captured at sequence reservation before the v1
body-store handshake. Each roughly 30-second cycle advances `generatedAt` even
when the book stays unchanged for roughly three minutes. Pair v1 and v2 by
`v1Sha256`, never timestamp equality; v1 generation remains inside the stored v1
body. The receipt's `generatedAdvancedAt` tracks advancing v2 generations.
The existing durable `lastGeneratedAt` clamps the generation floor across
restart. The sequence-state keys stay unchanged, but **r16 pairs with source
times different from `generatedAt` are not readable by r15**: r15 requires
account and position `observedAt` to equal `generatedAt`, whereas r16 preserves
source times. R15 validates every retained pair on open; leaving even one such
pair causes `stage_storage_invalid` / `startup_invalid`.

R17 candidate (`household-v2-switch-set-r17c-202610202345`; OPS-408) flips
publication in the pusher only when the selected release set's
`board.data_schema == "v2"`. The current v1 set retains r16d images and its exact
environment/mounts; the source build context/restart trigger still changes with
production `.mjs`. Pusher and stager use `joeSet.pusher.image`, executor uses
`joeSet.executor.image`. The OPS activation commit (OPS-354) selects the matching
r17 images in the release set and moved the joedesk lock to 6eacd6c7 (JOED-58 retry; d36b5295 was the first attempt).
Since JOED-39 the v2 set pins r18a (ops_test), and since JOED-59 the joedesk lock is 040d6756 (sequence 27).

In v2 mode, only the `current.json` committed pair is eligible. The existing
stager reader validates it and returns the exact snapshot bytes for POST.
The pusher gets a nested read-only bind of exactly `v2`; staging stays
network-none with a writable v2 mount. No new committed sequence means no POST,
with no v1 fallback. V1 still produces stored evidence with
`v1PostStatus: "not_posted_v2_active"`; only a real body-store failure uses
`v1Status: "v1_unbound"`. OPS-392 collectors must not count either as successful
v1 board acceptance; require a numeric successful HTTP outcome. Match v2
acceptance by seq/body hash in the pusher-owned posting state.

Preserve `/var/lib/joe-board-pusher/v2-post-state.json` (0600) outside `v2`.
It atomically stores the last-posted sequence/hash, uncertain attempt and the
latest 128 value-free POST outcomes, bounded to 65536 bytes. ReceivedAt is null
when no board receipt is available; recordedAt still records the local outcome
time. Only a greater committed sequence can advance the cursor. A 422
`sequence_replayed` records a terminal outcome for retry/migrated-pair handling;
OPS must migrate from the same retained bytes and preserve the allocator,
because the response itself does not attest remote byte identity.

The r17 rollback image is `household-v2-switch-set-r16d-202610201800`.
**Before activation, r17 → r16d needs no move-aside. After activation, it does:**
r16d's receipt validator rejects `not_posted_v2_active`, including in the
append-only stager log. The new sibling posting-state file and its `.tmp` are
ignored by r16d and need no move. Use the normal separately authorized,
coordinated release-set/board rollback, with a verified private backup:

1. Apply the existing executor restart guards: **0 claimed intents** and healthy
   executor before restart, then verify health/reconciliation after it. All three
   services share the image, so r17 selection also restarts the executor. No
   executor admission, replay, health or ownership guard changes in r17.
2. With pusher and stager stopped, archive **all** `v2/pair-*`, `v2/current.json`
   and `v2/receipts.jsonl` into a new dated sibling directory outside `v2`.
   Also copy `v1-cycles` into that archive before pruning can resume. Preserve
   unexpected residue for review. Never put the archive inside `v2`.
3. Keep `v2/sequence-state.json` and `v2/.allocator.lock` untouched, including
   the lock inode, `lastReservedSeq`, `lastGeneratedAt` and gateway high-water.
   Keep the new posting-state file and v1 evidence in place. r16d opens the
   empty retained-pair set, creates a fresh receipt log and reserves strictly
   above the saved high-water; no re-enrollment or log rewriting is needed.
4. Select the retained r16d image and matching v1 board/release set through the
   reviewed rollback path. r16d posts v1, so it cannot publish to a v2-only board.
   Verify the new stager pair exceeds the high-water and executor health is
   sound. Preserve the archive and posting-state file as evidence.

After migrate-v2 seeds board seq N, a first flip POST can be N with identical
bytes if no newer pair committed, or greater than N otherwise. Strictly greater
is not guaranteed: `StageStore.reserve` durably increments `lastReservedSeq`
before staging; `open` restores it. Preserve this allocator and migrate the
exact retained pair. Do not claim that an independent board seed is synchronized.

R16d (`household-v2-switch-set-r16d-202610201800`; OPS-404) refreshes
read-only positions every 120 seconds on the existing five-second tick while
the session is ready, issuing `cancelPositions` then `reqPositions`. Requests
never overlap, even when an end is overdue. A fresh accumulator replaces the
last completed position set only at `positionEnd`; missing rows disappear.
During a reply, retain the previous completed rows and coverage clock. Partial
positions, portfolio updates and account-download completion never refresh
coverage. A missing end therefore fails closed at age 421 seconds. Both the
all-desk and J family activity paths use the completed coverage clock, rather
than accounting/mark ages. A reconnect retires the pending reply and rejects
its late callbacks. KEEP classification and identical-input v1 POST bytes stay
unchanged.

The R16d rollback image is `household-v2-switch-set-r16-202610201700`.
**R16d → R16 rollback needs no pair move-aside**: the stager, pair/store format,
source-clock semantics and sequence-state keys are unchanged. Select the
retained R16 image through the normal reviewed rollback path and preserve all
`v2/pair-*`, `v2/current.json`, `v2/sequence-state.json`, `v2/.allocator.lock`,
`v2/receipts.jsonl` and `v1-cycles` in place. Verify retained pairs open and the
next sequence exceeds the saved high-water. The R16 positions-age bug returns
on rollback; it does not justify editing source clocks or resetting the store.

For an authorized **r16 → r15 rollback**, first confirm the previous NixOS
generation selects `household-v2-switch-set-r15-202610201500`, then perform these
steps on hsb0 (never run the rebuild on macOS):

1. Stop the stager and pusher so no pair or v1 body changes during the move:
   `sudo docker stop joe-household-v2-stage joe-board-pusher`.
2. Move **every** `v2/pair-*` directory and `v2/current.json` into a new dated
   backup **outside `v2`**. Keep `v2/sequence-state.json`, `v2/receipts.jsonl`,
   `v2/.allocator.lock` and `v1-cycles` in place; never reset or re-enroll the
   allocator. Also copy `v1-cycles` into the backup: the pusher's normal reconnect
   pruning follows the now-empty pair set, so the archived bodies preserve the
   moved pairs' provenance. In a root Bash shell, with both containers stopped:

   ```bash
   set -euo pipefail
   state_root=/var/lib/joe-board-pusher
   backup_dir="$state_root/rollback-r16-$(date -u +%Y%m%dT%H%M%SZ)"
   mkdir -m 0700 -- "$backup_dir"
   if [[ -d "$state_root/v1-cycles" ]]; then
     cp -a -- "$state_root/v1-cycles" "$backup_dir/"
   fi
   shopt -s nullglob
   pairs=("$state_root/v2"/pair-*)
   if ((${#pairs[@]})); then
     mv -- "${pairs[@]}" "$backup_dir/"
   fi
   if [[ -e "$state_root/v2/current.json" ]]; then
     mv -- "$state_root/v2/current.json" "$backup_dir/"
   fi
   sync
   ```

   Never delete the backup or put it inside `v2`: unknown entries there fail
   closed. Preserve any unexpected residue for coordinator review.

3. Run `sudo nixos-rebuild switch --rollback`. Verify the r15 stager opens with
   no retained pairs and continues above the saved sequence high-water; keep the
   dated backup as evidence. No sequence or receipt-log edit is required.
4. Accept the bounded source-clock transient: r15 uses retained `lastGeneratedAt`
   as a floor on `book.ts`. It returns `source_time_invalid` until `book.ts`
   reaches or passes the r16 wall-clock floor, normally within one IB account
   update cycle (about 180 seconds with a healthy source and clock). Do not reset
   `lastGeneratedAt`; verify a new pair commits at a higher sequence once the
   source catches up. If the source does not advance within that cycle, investigate
   source/clock health rather than changing the allocator.

Desk reader times are fresh inclusively from v2 generation minus 420 seconds
through generation plus 30 seconds. Missing or unparseable times are unavailable;
older times or times beyond the future allowance are stale. Reader observations newer
than the book stay fresh, and diagnostics use the observation clock. NAV/cash
summary callbacks and completed position replies keep separate
source clocks in the private handoff, so unrelated callbacks cannot renew them.
Account `observedAt` is the oldest emitted money source; positions retain their
coverage observation time. Legacy frames fall back to book time. A source older than 420
seconds at generation withholds NAV/cash with `source_unavailable`; stale
positions keep values null with that reason and clear unproven desk ownership.
Readiness still requires a completed API reply younger than 60 seconds. At over
420 seconds its reason is `snapshot_stale`, with `apiSessionReady:false` because
rev 9 requires a boolean rather than null. Contracts remain revision 9.
The shared 420-second freshness bound covers desk readers and source honesty,
about twice IB's 180-second cadence plus margin. The separate board-side
five-second generation allowance remains unchanged.

The ownership change selects
`/var/lib/joe-board-pusher/day-baseline.<policyHash>.json` automatically.
Preserve legacy `day-baseline.json` and all other policy files; no retirement
command is required on switch. Before R14, a policy mismatch blocked v1 DAY
permanently, including across NY midnight and restart. R14 starts the new policy
without reusing old values. V1 DAY is unavailable/null until a complete fresh
KEEP-excluded equity vector is proven from retained execution/fee history,
ownership, marks and FX and saved durably. That sample supplies today's fixed,
explicitly approximate `session_open_proxy`, initially zero relative to its
actual sample time; earlier day change is excluded. A restart keeps that
reference. Bad/stale evidence, corrupt active-policy files and persistence
failures stay unavailable (`day_pnl_unavailable`). The next NY calendar-day
midnight can promote exact SOD only with a candidate no more than five minutes
old, continuous authoritative execution coverage and the matching boundary
history digest. Otherwise the next valid new-day sample supplies a new proxy.
V2 `dayPnl` remains null with `not_exact_yet` through either v1 recovery path.
R16d rollback uses `household-v2-switch-set-r16-202610201700`; preserve the legacy file
that the old image reads and every policy-keyed file.

Staging retains the newest **N=10 pairs by sequence count**, never age; the
reviewable `StageStore.retainPairs` constant override supports 10–1024. Preserve
`current.json`, `sequence-state.json`, `.allocator.lock` and `receipts.jsonl` on
restart. For r16 → r15 rollback, use the move-aside procedure above: preserve
the pairs and pointer in the backup, and keep sequence state, lock and log in
place. The 0600 append-only log records one sequence/outcome
(`committed`, `rejected` or crash-recovered `staged`), timestamps and snapshot hash
per staged/resolved sequence, without payload values; pruning never removes log
records. Pruning uses checked `.retired-<seq>` tombstones for interrupted cleanup.
A local commit emits `{event:"v2_stage_committed",seq}`; it proves local staging,
not board acceptance. Recovery validates retained pairs and log integrity before
pruning; torn logs or unknown files fail closed and preserve evidence for review.

## JoeDesk Results producer (JOED-39, enabled in config; switch pending)

On 2026-10-20, JOED-39 sets `nixcfg.joeResultsProducer.enable = true` in hsb0's
configuration. The OPS-354 csb0 cutover is live since 2026-10-21 (the token-only
`POST /joe/inbox/results` answers 401 without a token); Amy's JOED-38 sign-off and
the JOED gate remain before the host switch. No live enablement is claimed.
The household pusher tree (`hosts/hsb0/docker/joe-board-pusher/`, its README
included) stays byte-identical, so the pinned pusher source is unaffected.
The endpoint is exactly `https://cs0.barta.cm/joe/inbox/results`, on the board's
`https://cs0.barta.cm/joe/` origin (csb0 RUNBOOK and JoeDesk README).
`ingressHost = "cs0.barta.cm"` and `ingressAddress = "89.58.63.96"` pin TLS and
egress to csb0's declarative `networking.interfaces.ens3.ipv4.addresses` address.
The module retains the default KEEP set (`SXR8`, `TSLA`) and applies it to the
already enabled executor capture. It uses the existing
`age.secrets.joe-board-push-token.path`, from the same agenix file as the
household pusher's read-only token mount. Systemd `LoadCredential` supplies a
private raw-token copy; there is no new secret or format conversion.
The producer runs as uid 1000 with group `users`, reads executor files by owner-uid access through a read-only mount, and keeps its own state directory private (`0700`, umask `0077`).

Local gates on 2026-10-20 passed: T100's 277 producer tests, its 10 module
evaluations and actual hsb0 wiring evaluation; T93's 850 executor tests and its
module/guard checks; and all six applicable pre-commit hooks (the justfile hook
had no matching file). T100 also verifies the IP against csb0's configuration,
the shared agenix file/path, capture KEEP agreement and the systemd sandbox.
Full hsb0 `nix eval` of `system.build.toplevel.drvPath` was attempted offline,
but the worker sandbox denied Nix daemon/store access; that gate remains
unverified and must pass outside this sandbox before activation. No NixOS build
ran. The operator must also complete the paper proof and approval gates at the
end of this section. The board deployment pin is unchanged.

Non-200 responses and refused redirects from `POST /joe/inbox/results` count as
delivery failures. The producer
keeps both journals, logs value-free diagnostics and retries with a fresh,
durably reserved sequence and recomputed snapshot. Failure backoff grows through
1, 2, 4, 8 and 16 seconds to a 25-second ceiling, bounded by the normal
25-second cadence. No failed delivery becomes accepted output. Capture continues;
the append-only producer journal grows with sequence reservations, source events
and changed health, so monitor disk space during a prolonged outage. Never
truncate either journal or reset sequence state to clear a delivery failure.

Rollback, producer only: `git revert -m 1 <#1059 merge>` through a reviewed PR
and the separately approved hsb0 switch. A JoeDesk v2 rollback (release set
`active` away from `v2`) turns the producer off in the same switch, because
`enable` follows `joeRelease.active == "v2"`; a variant B rollback also restores
hsb0's configuration.nix to the pre-cutover bytes (T100). Retain
`/var/lib/joe-results-producer/results.jsonl` and
`/var/lib/paper-desk-executor/results-input.jsonl`; executor capture remains
explicitly enabled. Keep the prior generation and compatible pins for recovery.

Household v2 health/account and equity fragments are outside v1 scope: the
service neither reads nor mounts the household producer directory. No fixtures
are selected by the service. No LIVE mode or Gateway client exists in the producer.

The already enabled executor capture writes
`/var/lib/paper-desk-executor/results-input.jsonl` before admission pruning,
recon compaction and ordinary saves. Each hash-chained, fsynced line commits a
whole capture cut or a small FX-only event. Cuts contain only owned Stage-0
fills, commissions, close FX and reconciliation evidence with hashed identifiers.
Capture exceptions retain the full ledger without pruning or recon compaction;
admission/save proceeds within the capacity limits below if the ledger remains
writable. If ledger publication itself fails (including ENOSPC, EDQUOT, EROFS,
EIO or EFBIG on the shared state volume), the existing intent failure remains:
HTTP 500 `status: "rejected"` for a failed claim save, no broker call and no
in-memory claim carried into later loads. If rename/link succeeded before a
directory-fsync or cleanup error, the visible claim remains on disk for the
existing uncertain/replay handling; that failed save still makes no broker call.
A failure after a durable claim keeps
that claim's existing uncertain/replay behavior; an alert never authorizes
execution without durable evidence. Legacy migration remains pending with its
complete evidence until capture succeeds.

Book polls load read-only snapshots without initialization or migration. Failed
capture during a migration never publishes that reader's snapshot; the exclusive
save publishes its diagnostics alongside the current claim and delivery receipts.
Startup capture also runs on that exclusive queue. Journal initialization,
append/fsync or migration-publication failures leave the executor listening with
its capture hook installed and evidence retained. If diagnostics cannot be saved,
health retains them in memory until a later exclusive publication succeeds,
for both startup and ordinary save failures. It reports
`resultsCapture.persisted: false`; only diagnostics and delivery bookkeeping
are retained, never undurable intent/evidence changes. An unsaved diagnostic
cannot survive process termination, but startup redetects a continuing outage.
Exception text and filesystem paths are excluded from these capture diagnostics.

Executor `/v1/health` and loopback Results health (`127.0.0.1:8472`) report
`status: "degraded"` after a capture/catch-up failure. This is executor health:
it does not set HALT or change trading brakes. The Results producer projects it
to the board contract's existing executor `status: "degraded"`, keeping its
`halt`, `brakes` and gateway fields independent. Board rendering and changes to
the pinned board contract belong to JoeDesk. The executor endpoints expose
the following fields for that consumer; size diagnostics are not added to the
pinned Results wire contract here:

| Field                                                  | Meaning                                                                                                                                                         |
| ------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `resultsCapture.ok`, `resultsCapture.degraded`         | False/true during an unresolved capture or catch-up failure                                                                                                     |
| `resultsCapture.persisted`                             | False while capture/delivery diagnostics live only in memory; true after their ledger publication succeeds                                                      |
| `resultsCapture.state`, `reason`                       | `ok` with no reason; otherwise `degraded` with `results_capture_failed`, or `ledger_size_limit` when new admissions are blocked                                 |
| `resultsCapture.since`, `lastErrorAt`, `code`, `count` | Outage start, latest failure, fixed value-free error class, cumulative failure count                                                                            |
| `ledgerBytes`, `ledgerMaxBytes`, `ledgerPercent`       | Current on-disk ledger bytes, 16 MiB cap (16,777,216 bytes), percent used; also repeated inside `resultsCapture`                                                |
| `resultsCapture.ledgerCapBytes`                        | Alias of the existing `ledgerMaxBytes`; both remain 16,777,216 bytes                                                                                            |
| `resultsCapture.admissionThresholdBytes`               | 15,099,494 bytes: 90% of the existing ledger cap, rounded down                                                                                                  |
| `resultsCapture.newAdmissionsBlocked`                  | Capture degraded and ledger at/above that threshold; new placement admissions are refused                                                                       |
| `resultsCapture.lastRecoveredAt`                       | Most recent successful capture, catch-up compaction/prune and ledger publication                                                                                |
| `resultsCapture.alertDelivery`, `lastAttemptAt`        | `unconfigured` without the local mailbox; otherwise `pending`, `delivered` or `failed`, plus latest UTC delivery attempt when present                           |
| `resultsCapture.durability`, `durabilityCode`          | `uncertain` plus a fixed code (allowlisted, otherwise `unavailable`) while a capture-durability warning is held (set/cleared: see 'Capture-durability warning') |

The allowed-peer `GET /v1/health` on port 8470 exposes these names, as does
loopback Results health. JOED-45 replaces the JOED-43 interim board mapping
with the vendored rev-9 contract: capture failure below the admission bound maps
to `safety.executor.status: "degraded"` with `reason: "results_capture_failed"`;
`newAdmissionsBlocked` or `reason: "ledger_size_limit"` maps to `degraded` with
`reason: "ledger_size_limit"`. `executor_broker_disagreement` takes priority
over both. The producer includes `ledgerBytes` and `ledgerCapBytes` together
when both are known safe integers (bytes ≥ 0, cap ≥ 1); otherwise it omits both.
Bytes above the cap remain valid telemetry. No cap is sent without bytes, and
byte counts alone never infer an admission block. The data contract id remains
`inspr.joe.household.v2`.

At the threshold, NEW placement intents fail closed with HTTP 422 and both
`code` and `reason` equal to `results_capture_degraded_ledger_cap`. They receive
no claim and make no broker call. Failed capture still skips all pruning: never
destroy uncaptured evidence to make space. Idempotent replay remains available.
Recon, cancel, flatten and modify-stop remain allowed at this new threshold so
existing positions can be reconciled or made safer. Existing ownership, KEEP,
HALT, order checks, claim/execution budgets and the hard persistence cap remain
enforced for those actions. The 10% margin reserves headroom for in-flight work
and safety actions; it cannot promise unlimited reconciliation growth or writes
on an already full filesystem. Restore capture/storage before exhausting it.

Persisted `resultsCaptureAlerts` receipts have one active row per fixed error
class, plus at most 128 resolved outage receipts. Each class alerts/logs once per unresolved outage,
including across alternating errors, repeated saves and executor restarts; no
exception messages or broker values are included. Active receipts remain until
recovery; resolved receipts expire from their last observation using the
foreign-alert retention period. A successful capture alone, admission pruning,
legacy migration or health polling cannot clear degradation. A save must capture,
successfully catch up recon compaction and retention pruning, and publish the
ledger before setting `ok: true`, `lastRecoveredAt`, and each active receipt's
`resolvedAt`. Capture success followed by catch-up failure retains full evidence
and degraded health for retry. The same class can alert again after recovery.
Health polling does not retry a pending capture migration.

When both executor and mailbox modules are enabled, capture alerts also go to
Amy's existing mailbox inbox. A separate Unix listener at
`/run/agent-mailbox-local/sender/mailbox.sock` constructs the
`paper-desk-executor` sender identity. The host parent is 0750 root:1000;
its socket directory is 0700 1000:1000 and the socket is 0660. Only the mailbox
and executor containers mount it; the executor mount is read-only. The socket
creation umask stays restrictive through asynchronous listen and final chmod,
and is restored after success or failure. The socket
accepts only `POST /v1/messages`, recipient `amy`, JSON ticket `JOED-43` and
`X-Ticket: JOED-43`. Every read, health, ack and events route is 403. TCP peers
cannot claim this identity. Existing TCP source identity, firewall rules and
message UTF-8/control/bidi checks still apply.

The background sender sends one value-free message per class outage and one
resolution, containing only event, fixed class code, since/at timestamps,
ledger bytes/cap and admission-block flag. It never waits on the intent path.
Each attempt has a one-second absolute deadline; five attempts use bounded
backoff of 250 ms, 1 s, 4 s and 15 s. Attempts and delivered markers normally
persist on the outage receipt. When the shared volume cannot persist an
attempt marker, the sender still posts best effort, with one in-memory delivery
record per class and at most one post in flight. It uses the same five-attempt
budget and backoff, without growing a retry list. This volatile attempt budget
lasts for the process lifetime; a restart during unwritable storage redetects
the fault and can retry, while the mailbox still deduplicates the message.
For a never-persisted receipt, its class, last durable ledger digest and
modification time anchor the stable delivery key; its message's since/at
timestamp is that modification time (a lower bound on the outage start).
The publication time distinguishes a later healthy rewrite of identical bytes.
This reconstructs the same key and body across restart while the ledger is
unchanged. The first
successful publication adopts that receipt's identity, body and attempt state.
Persisted receipts keep their original identity, so restart does not reset
their retry budget or repeat a delivered message.
Every ledger-store atomic write shares one publication outcome: an error before rename/link
throws with `published: false`; a successful publication returns
`published: true` and `durability: "ok"` or `"uncertain"`, plus an allowlisted
error class when uncertain. A later directory open/fsync/close or temporary
cleanup error cannot turn visible bytes into a failed capture. Published recon
evidence (including its rotated generation) permits the receipt swap and recovery;
a published exclusive migration backup permits migration. An existing regular
backup is validated and kept immutable on `EEXIST`. HALT and both audit
generations use the same writer; audit rotation copies the complete old generation
before publishing the new one. The attribution journal publishes in the ledger.

Capture-durability warning: a published-but-uncertain ledger-store publication, or an audit failure after HALT is published, sets `durability: "uncertain"` with a fixed `durabilityCode` (an allowlisted error code, otherwise `unavailable`). It is held in memory only: a later ledger.json publication that completes with durability ok clears it, provided no other warning arose during that save, migration or single ledger.json write. Publications of other files never clear it, and a restart starts without it. `/halt` 200 reports it whenever it is set; health reports the same value under `resultsCapture` whenever the ledger has `resultsCapture` or capture is on.

`audit()` reads the whole file and atomically rewrites up to 1 MiB, plus fsync
per row. This is safe only while every caller is synchronous and runs in the
single executor Node process. No second process (CLI or tool) may ever write
`audit.jsonl`. Near a full volume, the rewrite needs about 1 MiB free where an
append needed only one row.
After HALT is published, an audit failure still returns HTTP 200 with
`status: "halted"`, `active: true`, `source: "local"`, plus
`durability: "uncertain"` and a fixed `durabilityCode` (an allowlisted capture error code, otherwise `unavailable`); see 'Capture-durability warning'. The halt response reports the current capture-durability warning (see 'Capture-durability warning'), so a healthy halt can carry a warning from an earlier publication or halt. The visible halt is retained;
a failure before HALT publication keeps the existing error response. Repeated
halt requests keep the halt active.
Once a ledger rename or initial hard link succeeds, its published body becomes
the in-memory state, including capture recovery, resolved receipts and delivery
records. Initialization, migration, normal saves, delivery updates and OPS re-arm
all adopt it before a separate, value-free `durability: "uncertain"` warning is
propagated. Ledger persistence still throws on that warning so a claim fails
closed without a broker call. It cannot hide a published recovery or turn
`persisted` false. Only an error before publication may preserve the old state or
pending capture diagnostics.
Pending diagnostics reconcile by outage ID, adopting the published resolution
and delivery record when another generation appears. An unresolved on-disk
receipt also supplies the canonical identity for a never-persisted outage of
that class. Same-generation memory retains newer unsaved attempt results.
Each resolved outage keeps one resolution; a later failure of the same class
gets a new outage ID and mailbox key. Recovery reopens the 90% admission cap
as soon as the recovered body is published, including during a durability warning.
The mailbox deduplicates a stable local delivery key against
its durable inbox and 30-day archive, covering lost replies and acknowledgement.
Resolved receipt retention still applies. `failed` requires operator attention;
restoring delivery does not automatically reset an exhausted receipt's budget.
With the mailbox disabled, only the existing receipt/log remains and delivery
health is `unconfigured`.

After a separately reviewed deployment, OPS can verify the live path without
causing a capture failure:

```sh
sudo docker exec paper-desk-executor node /executor/send-test-alert.mjs
```

This sends exactly one `[TEST] JOED-43 capture alert path check` message to
`amy` over the same socket, exits zero on delivery or nonzero on failure and
prints one value-free line. It never reads or changes the ledger, receipts or
health. Verify receipt in Amy's existing watcher/inbox; do not infer receipt
from a log line alone. The builder does not run this command against production.

### Re-arming a failed capture alert delivery

After fixing the mailbox, OPS can re-arm unresolved receipts whose failure
delivery exhausted its five attempts. From an existing admin-allowed OPS peer
(the executor's `PAPER_DESK_ADMIN_ALLOW`, not an ordinary order peer), run:

```sh
curl --fail --silent --show-error --request POST \
  http://100.64.0.6:8470/v1/admin/capture-alerts/rearm
```

The value-free response is `{"status":"ok","rearmed":N}`. The endpoint
uses the exclusive intent/save queue. It resets only unresolved `failed`
failure-delivery counters/status/backoff, keeping their original body and
Idempotency-Key. It does not capture, compact, prune, clear degradation or
change evidence, claims, resolved receipts, pending deliveries or delivered
markers. The background sender retries; verify `alertDelivery` and Amy's
inbox. A lost reply can safely re-use the same key. If ledger publication
fails before rename, the endpoint returns HTTP 500 without resetting the budget;
restore storage before re-arming. A post-publication HTTP 500 leaves the reset
budget on disk, and the background sender retries that published receipt.
Verify health and Amy's inbox before re-arming again. Do not edit the ledger or
evidence files.

A post-publication intent-save error also returns HTTP 500 without replacing
the visible claim or result. Retrying the same intent replays its stored `done`
result, or returns HTTP 409 `uncertain` if only the claim was published; it never
re-executes that intent automatically.

Mailbox recovery alone does not re-arm an exhausted receipt. Capture
degradation clears by itself only after a successful capture, catch-up and
durable ledger save; that marks receipts resolved and schedules a resolution
message. A failed failure-delivery marker remains `failed` even after a
resolution is delivered, until the resolved receipt ages out under normal
retention. No forced-clear operation is provided. A later outage after
confirmed recovery receives a fresh receipt and retry budget.

Persistent failure grows the ledger: monitor these health fields, alert receipts
and `ledgerPercent`. Journal write/fsync failures latch the writer: restore
storage, retain both journals and the ledger, then restart the executor. Never
truncate or rebuild a damaged journal to clear the failure. Capture disabled
adds no fields and follows the existing retention and admission paths.
FX-only events update samples/status without repeating position or history
proofs; older producers ignore that event type on rollback; samples carried only
by FX-only events are then unseen, so USD days fail closed as partial until
roll-forward. Health rows in the
producer journal record changed health values; every transmission still reserves
a sequence durably, even when health is unchanged. Legacy, unowned and external
activity and policy KEEP symbols do not enter FIFO. The producer opens that
input read-only and keeps
its own append-only `/var/lib/joe-results-producer/results.jsonl`; retain and
back up **both** files. Never reconstruct them from the bounded executor ledger,
rotate them as ordinary logs, truncate a damaged tail, or reset sequence state
to satisfy the board. A damaged journal holds output for operator recovery.

FIFO uses independent `j`, `joe`, `joel` books and emits each closed portion.
M-2 (a) and L-6 (b), approved 2026-10-17: EUR-denominated commissions
use an eight-decimal BigInt allocation budget. Each non-final share is
`halfEvenUnits(fee * portionQuantity, executionQuantity)`; the final portion
takes `originalFee - sharesAlreadyAllocated` without additional rounding.
For seven shares and EUR 3, closing three allocates `1.28571429` and closing
four allocates `1.71428571`, conserving exactly `3.00000000`.
USD and other non-EUR commission shares stay rational (`fee * portionQuantity /
executionQuantity`), with no allocation rounding or final remainder adjustment.
Convert both opening and closing shares at that close's FX, combine them exactly,
then round the combined EUR commission once, half-even, to eight decimals.
A closing execution spanning several entry lots has its own allocation;
a reversal carries the EUR budget or foreign rational shares into its residual
opening lot. Pre-tracking and excluded portions consume their quantities and
EUR allocation budgets, so later portions cannot reuse either.
USD gross uses the exact quantity × price move × close rate product and rounds
once, half-even; EUR gross retains its exact conversion policy. Daily and range
totals sum emitted EUR portions exactly, without further rounding. The final
remainder/conservation rule applies only to EUR commissions; independently
rounded foreign portions need not always sum to a separately rounded total,
and different close FX rates do not imply a fixed EUR total.
The producer reads decimal strings only; the capture SDK boundary converts
Numbers per I-2 (a), as detailed below. Missing or stale USD FX excludes its
portion and marks its day partial with a value-free `conversion-exclusion`
journal record whose `kind` is `fx_missing`.
A missing opening or closing commission temporarily excludes its portion and marks its day partial with journal-only `broker_evidence_missing`, without a durable portion guard, scoped gap or `portionExclusions` count; the next snapshot can emit the trade and restore full coverage when the commission arrives.
Other unexpected failures (for example third-currency commissions or invalid
rates) are excluded with the existing journal-only `source_not_authoritative`
kind. An inexact fee split alone no longer excludes an EUR portion. Their journal
records contain only day/time and hashed desk, instrument and portion identity.
The quantity book advances even on exclusion; other portions keep producing.
A rollback to round 12b and roll-forward keeps any durable `source_not_authoritative` guards that 12b wrote for EUR fee splits; harmless while capture is off.
Coverage is per day across all desks: an affected desk makes the shared day partial while other desks retain their trades and totals.
Each such exclusion adds a 1 ms history gap at the affected close, scoped to
its desk and instrument. Its day stays partial, and later days with fills in
that book stay partial until position evidence covers the gap under the existing
proof rules. Producer health `portionExclusions` counts distinct exclusions
of this kind across polls and restart. Rev-6 wire diagnostics map the guarded
portion and its scoped 1 ms gap to `history_gap`; the original value-free
journal diagnostics remain replayable. Round-9b journals still
replay without rewriting old exclusions
or resetting sequence state. Days previously excluded only for precision now
include their rounded USD portions on the next snapshot and can become full
when the existing coverage and broker-evidence gates pass. With the JOED-20
sampler, USD fills use their own day's latest RTH
observation provisionally (same day, at most 30 minutes old) and the frozen
16:05 New York close when available.
The rate and sample timestamp travel together; a later day's rate never fills
historical holes. Legacy capture evidence keeps its execution-local 60-second
rule. EUR uses identity FX. Existing open lots can seed the
book, but round trips closing before capture began are omitted. `trackingStart`
is the Vienna date capture began; display earlier coverage as **since that
date**, never as a complete lifetime result.

Daily rows come only from captured executor activity on each Vienna day; days
without captured activity are omitted, except every Vienna day touching an
explicit history or fill gap (including unattributed own fills): those days emit a
partial row with an empty desk map, whose total is unknown, not zero.
`equityClose` is always null: v1 does not
consume household v2 health/account fragments, desk equity or History basis IDs,
and old household observation journal events are ignored on replay. Day realised
net, fees and trade counts sum every included closed FIFO portion across all
active desks, including opening-only desks with zero realised totals. Both legs'
fees are charged to each closed portion. Revision-6 validation still checks
missing traded desks, exact counts and exact net/fee sums on full days.

Under rev 6, every CLOSED partial Vienna day (date before the producer's send
day) emits a nonempty, unique `partialReasons` array. The OPEN day stays partial
("so far") and omits reasons when there is no real cause; it never gets
`capture_gap` merely because it has not closed. Real causes use the same
nonempty list on open and closed days, in this canonical order:

| Code                           | Producer evidence                                                                                                                         |
| ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `capture_gap`                  | Capture refusals/issues or a real tracking start after Vienna midnight                                                                    |
| `history_gap`                  | Unknown/malformed/missing history bounds, real history gaps, earlier fill gaps lacking position proof, guarded conversion/fill exclusions |
| `broker_trade_count_mismatch`  | Closed-day broker closing-execution count differs from FIFO portion count                                                                 |
| `broker_realised_pnl_mismatch` | Exact broker net differs by more than EUR 0.01                                                                                            |
| `unattributed_activity`        | Current capture cut reports own unattributed fills; `unattributedCount` is included only when known and positive                          |
| `avg_cost_mismatch`            | Reserved by the board; producer never emits it                                                                                            |
| `fx_disabled`                  | Required USD day FX is incomplete while the sampler is disabled                                                                           |
| `fx_missing`                   | Missing/stale portion FX, refused close FX or FX samples, stale/missing samples, sampler failures or missed fixed close                   |
| `broker_evidence_missing`      | Missing broker reports or commissions, including transient missing commissions; refused broker evidence                                   |

Full days carry neither reasons nor a count. Corrections may heal transient
commission and unattributed-activity diagnostics; capture refusals and guarded
history gaps retain their existing durable behavior. Old capture cuts without
unattributed metadata cannot distinguish an unattributed 1 ms gap from another
history gap: emit `history_gap` and omit the unknown count. Capture writes only
value-free day/count metadata for current unattributed activity; it deduplicates
logical fills, excludes KEEP/foreign/pre-tracking/out-of-window activity, and
updates the cut when attribution changes even at the same timestamp.
At ingress, the board and local validator reject a closed partial day without
reasons with 422 `partialReasonsRequired` at `$.days[i].partialReasons`. Local
validation always supplies `receivedAt`: the producer's reserved send time
(`generatedAt`), also used by snapshot validation and the push. Offline calls
without an explicit option use that same payload send time, never silently skip
the rule. Served legacy data uses its persisted board receipt. Strict producer
validation rejects the reserved code; only the open day without a real cause
may omit reasons. The board's open-day note rule shows no generic note when
that day has no reasons, and shows a real FX reason when present.
A reasonless open day built just before Vienna midnight and received just after
it gets one 422 `partialReasonsRequired`; the runner silently recomputes and
resends once without failure logging or counter changes. Only that sole error
on the day open at generation qualifies; other rejections use normal backoff.
New cuts journal reported `historyGaps` separately from value-free 1 ms
`fillGaps`, tagged `unattributed_activity` or `capture_gap`. They revoke coverage and
remain in earlier-gap position-proof maths; their own day carries its own reason
only, while later unproven days retain `history_gap`. A separate real history
gap still adds `history_gap` on the fill day. Legacy cuts without fill-gap
provenance keep their conservative `history_gap` label. The existing
`historyCoverage.gaps` field retains the combined omissions for conservative
older readers on rollback; the new producer uses the separate provenance for
labelling, without removing omissions from coverage or earlier-gap proof.
Fill-gap labels start at the tracking instant; pre-tracking fill gaps remain in
the proof maths without creating earlier day rows. Combining fill gaps is
idempotent across capture initialization, authority hashing and producer replay;
the round-14 authority hash stays unchanged.
Refused FX samples and close FX keep the journal kind `broker_evidence_missing`
for round-12b/13 rollback readers. The new producer maps fields `sample.rate`
and `closeFx.rate` to the Results reason `fx_missing`; other broker issues keep
their existing reason. Round-14 journals that already use `fx_missing` remain
readable by the new producer.
There is no exact rev-6 code for an unexpected conversion failure: `history_gap`
is used because containment creates that scoped gap. No provisional FX reason is emitted.

**P3 — per-desk close basis:** Amy approved the single `CLOSE_BASIS` constant
`execution-fifo-net-current-fx`, versioned by `manifest_revision`, for v1.
Changing that basis requires a manifest revision bump and matching contract
review; `backstop.test.mjs` preserves the approved close-basis baseline. A per-desk
close-basis wire field remains P3, requiring a future JoeDesk contract revision.
Pinned Results at `84c47b647cf06a38a3f61ce7f928a10ed10eeef3` (revision 9)
forbids adding an unversioned basis field to `days[]`.

KEEP fills are excluded at capture and again at FIFO, including pre-existing
captured fills. They contribute nothing to trades, day counts, realised net or
fees. The protected SXR8/TSLA floor cannot be removed.
Results never contains account/order IDs, receipts or broker account equity.
The runner reads only the executor's loopback health endpoint for local status,
halt, brakes and Gateway diagnostics; account fields are discarded before any
write. That status is never reconciliation evidence and no household handoff is
produced. Concrete owned-fill quantity vs complete broker-position evidence can
produce `executor_broker_disagreement` in Results' permitted `reason`.
Foreign/netted residuals and incomplete broker cuts do not prove disagreement;
gateway reachability changes alone never do.

Reserved ports: executor tailnet `8470`, mailbox tailnet `8471`, capture health
loopback `8472`. Capture OFF writes no `resultsFx`, `resultsHistoryCoverage`,
`resultsFxSampler` or `ownershipSnapshot.observedAt` into executor state/ledger.

The optional executor listener on `127.0.0.1:8472` serves only `GET /v1/health`; no intent/admin/halt route is exposed.

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
a new snapshot and sequence. It never sends `receivedAt`, `missingDays` or
`X-Joe-Received-At`; ingress stamps receipt time and uses `acceptSnapshot('results')`. HTTP redirects
are refused. A 200 updates the last-good snapshot; 422 retains it and logs only
an allowlisted reason and up to 20 safe `{path, rule}` pairs. 400/401/413/503
and network failures also back off with value-free diagnostics. The board is
stale after 60 seconds without an accepted push; retries do not fake freshness.

JOED-45 vendors JOED-52 rev 9 from `84c47b647cf06a38a3f61ce7f928a10ed10eeef3`,
superseding the JOED-49 rev-8 pin `dcdf850d06a5087b674a533875ebaec6127e9819`.
The complete self-contained `contracts/` directory (manifest revision 9,
including `vienna-date.mjs`) is vendored byte-for-byte. `contracts.lock.json`
pins its source revision, each file's byte count and SHA-256, and set digest
`000045fb7843a16be95f6a7e42d46d4b4ecb34b0efd39fc987bee444817fc9d5`.
Rev 9 adds household `positions.rows[].reasons.desk` and `desk_unmapped`.
A `stage0` row may have a null desk only with a desk reason (`deskRequired`
otherwise); a desk reason with a non-null desk or on any KEEP row is rejected
as `contradictoryDesk`. KEEP remains `scope: keep`, with a null desk and no desk
reason. Rev-8 payloads remain valid, including nullable household cash/position
quantity with per-field reasons and `not_exact_yet` / `source_unavailable`.
The `results.v2` schema and executor safety mapping remain unchanged: this
producer emits Results snapshots, not household positions rows.
A round-12b producer against the rev-6 board gets 422s on closed reasonless
days; the contract pin mismatch already blocks activation.
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
60 Vienna days in each DST season, including KEEP, with a 2,500 ms CPU bound
per operation: ingest of 1,920 cuts with per-cut position proofs and a persistent
earlier gap plus snapshot build/validation, and
separately restart replay plus prefix verification and snapshot build/validation.
Both the test and runtime transport check the 8 MiB
served-size limit including the board's `receivedAt` overhead; no broker or
account data is used.

Coverage uses the executor history's explicit `fromInclusive`/`toExclusive`
bounds minus gaps, persisted with capture cuts even when fills do not change.
The executor persists only status, target bounds and gap bounds, excluding
receipt lists. Own-account non-KEEP fills awaiting attribution at or after the
cutover add a 1 ms gap at their execution time inside the history target.
Attribution removes that gap on the next cut. Coverage-only cuts are written
when the gap set changes or another closed Vienna day is proved, rather than
for each movement of intraday bounds; fill and authority changes stay immediate.
The producer unions proven intervals across restart and subtracts newly
declared gaps from earlier proof too, using the vendored Vienna
date helper for 23/25-hour DST days. Missing/unknown bounds, any uncovered part
of a closed day, a mid-day window start, and the current day emit
`"coverage":"partial"`; a stale capture never extends proof to generation time.
For the open day, the reason check ends at the largest validated authoritative
history target's `toExclusive` or the send time, whichever is earlier.
The trailing unproven stretch is "so far",
without a `history_gap` label. Explicit gaps and holes between Vienna midnight
and that instant still produce `history_gap`; closed-day checks
continue to require proof through the next midnight.
Full days omit `coverage`, using the README's documented default of `"full"`.
An earlier gap also makes a day partial unless every captured Stage-0
fill on that day has a post-gap baseline for its instrument before that fill
(openings included): either a broker-flat
snapshot with every desk flat, or exact captured quantities reconciled to the
broker at the start of the proven interval containing the fill, or the last
proven interval for fills at or after its end under the open-day "so far" rule.
A later snapshot inside that interval can establish the start quantity by subtracting the same
captured intervening fills from both books. The executor records the complete
broker `positionEnd` time as `positionsObservedAt`, persists it with
`ownershipSnapshot.observedAt`, positions and ownership completeness, and
capture journals only hashed instruments, decimal quantities, the hashed foreign
instrument set and that time. Every non-KEEP broker-position instrument and
known instrument is listed; an absent instrument is proven broker-flat only
in a complete receipt that does not mark it foreign, with every desk also flat.
Legacy receipts lacking the foreign set prove only explicitly listed positions.
Missing, future, mismatched, equal-time ambiguous or pre-gap proof fails closed;
an activity timestamp never refreshes an old position snapshot. Opposing desk
positions do not count as flat. A gap after the day does not change its coverage;
the current Vienna day remains partial. Proof and corrections replay from the
same journals after either service restarts.

The I1/I2 coverage rules above remain in force. Their residual risk is a missed
open+close pair inside an earlier gap: quantities may net to zero while FIFO
prices shift. The automated broker backstop now compares each closed Vienna day
and desk before every push, using existing executor `executions` and
`commissions` only. `execution.execId` joins `commissionReport.execId` privately;
`time`, `shares`, `side`, contract currency and attributed desk establish the day
and closing execution count. Only hashed fill/instrument keys and an allowlisted
`brokerRealised: {amount,currency}` or `{unset:true,currency}` projection of `commissionReport.realizedPNL`
and `currency` enter the capture. Broker realised PnL is net (fees are not
subtracted again); the already captured close FX converts it to EUR exactly.
Broker net sums retain the exact PnL × rate products at 10⁻¹⁶ EUR with no
rounding, then compare against realised net scaled to the same precision.
IB unset realised PnL (null or Double.MAX_VALUE) is accepted only on quantity-book
openings with a commission report; closes require an exact amount.
No new IB request is added. At the SDK boundary, `Number.MAX_VALUE` (and its
String form), `2147483647`, null and missing values map to unset before conversion.
Unset PnL on closes still keeps D partial; unset opening PnL follows the quantity
book rules above. Numbers are accepted only when `String(n)` is a finite plain
decimal with at most 15 significant digits and fits the eight-decimal contract;
`-0` normalises to `0`. Exponents, NaN, infinities and excess precision are refused.
Decimal strings retain the existing exact policy. Converted fields carry additive
`src: "sdk_number_roundtrip"` provenance (fill fields use a `provenance` list);
older replays ignore it. A later string-source adapter can replace this boundary.
Every refused field produces a value-free `captureIssues` journal record with
`day`, hashed identity/desk, field name and kind: `capture_gap` for fill fields,
`broker_evidence_missing` for broker evidence. Its day stays partial on replay;
no refused numeric value or raw identifier is stored. Unset required fill fields
also record a gap, without counting as a conversion refusal. A refused fill
adds a 1 ms history gap at its timestamp, so later fills cannot silently pair
against an incomplete FIFO book even when broker PnL is exactly zero.
A capture issue keeps its day partial even after a clean correction arrives,
by design. The loopback health `resultsCapture.refusals` and producer
`captureRefusals` count distinct refused field records, deduplicated across
polls and restart. Missing reports and incompatible currencies also keep D partial.

A per-desk absolute net difference **above EUR 0.01**, or any count mismatch,
downgrades D to `partial` on the next push. Broker count is closing executions,
independent of FIFO price lots: one execution closing multiple FIFO portions
therefore conservatively remains partial even if amounts match. Missing broker
evidence also downgrades D. Unknown capture bounds remain partial regardless of
broker agreement; executor health and household fragments cannot restore full.
A `broker-mismatch` journal record contains only `{day, deskHash, kind}` (no
amounts or raw identifiers), deduplicated across heartbeats and replay. Late
commission/correction updates trigger a new capture cut; corrected evidence is
recompared without erasing old mismatch records. Capture/producer restarts retain
the same result. Private broker rehearsal on hsb0 remains an enablement gate.
The producer and fixture ingress call the vendored validator directly: partial
days skip day/trade reconciliation while schema and trade checks still apply;
full days reconcile every trading desk with exact counts and decimal sums.
KEEP contributes nothing to either array, including partial-day totals.
The revision-4 closed reason enum no longer permits `results_not_wired`.
Since JOED-39 the module is enabled in hsb0's configuration while the v2 release
set is active; the gates and switch procedure are in the JOED-39 section above.
The systemd sandbox uses executor uid 1000 with group `users` and read-only input mounts,
one writable state directory, empty capabilities, no added groups/Docker socket, and
IP egress limited to loopback and the pinned ingress address. The private hosts
file resolves the TLS hostname without DNS egress. Endpoint and health paths
are fixed by configuration/code; systemd's IP filter operates at address scope.
The module independently pins `JOE_RESULTS_INGRESS_ORIGIN` (scheme, host, port);
settings/state cannot redirect transport, and redirects are refused. Settings
must be an immutable Nix-store file; state/input paths are fixed. The credential
reader accepts only systemd's fixed service directory and fixed token basename,
refusing traversal and directory/file symlinks.

Paper proof, for the operator **after** separate enablement approval:

1. On the workstation/CI, run `bash tests/T100-joe-results-producer.sh` and
   `bash tests/T93-paper-desk-executor.sh`. Confirm the vendored bytes against
   `contracts.lock.json`. Keep synthetic compaction, torn-write and gateway-flap
   simulations in this lab; hsb0 remains a production paper host.
2. Before the approved hsb0 switch, retain its previous generation and compatible
   board/pusher/executor pins plus private backups of both Results journals (if
   present). Record the rollback path on JOED-20/OPS. The board endpoint, KEEP
   policy and IP/TLS pin are in hsb0's configuration (JOED-39).
   Verify the revision-4 contract pin, exact decimal source evidence and broker
   report backstop with JoeDesk/Amy first. Follow the normal remote NixOS build
   and human-controlled switch procedure; no local NixOS build on macOS.
   csb0's exact-path token-only router for `POST /joe/inbox/results` (JoeDesk README:425–429; OPS-354, PR #1007) is live since 2026-10-21.
3. On hsb0, inspect `systemctl status joe-results-producer` and the unit sandbox.
   Read `http://127.0.0.1:8472/v1/health` privately and verify paper Gateway
   configuration, halt and brakes. Do not copy its raw body/account into tickets,
   Git, public logs or fixtures. Verify non-GET/other paths return 404 and the
   optional listener is bound only to loopback. The producer never submits an
   intent to perform this check.
4. Observe an **already authorized paper** desk open/partial close/full close
   through the normal desk workflow. Compare private broker fill/commission/FX
   evidence to every Results portion and Vienna close; check the constant close
   basis and value-free broker mismatch journal records. Verify KEEP holdings
   are untouched. Observe two accepted Results generations within 30 seconds, strictly increasing sequence and
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
contract; exact broker source evidence; immutable deployment pins and Amy's
paper reconciliation approval. Household fragments are excluded from v1; the
per-desk close-basis field is P3. Amy's 2026-10-17 JOED-20 approval permits only
the isolated USD/EUR sampler described below; it does not widen any other IB
scope. Local fixture ingress is a test adapter, not an installed service.

### Close-FX sampler (JOED-20, local candidate)

When Results capture is enabled, the paper executor runs a separate background
FX reader using
client 709 and request IDs in 920000000..929999999. Reserve client 709 separately
from order/recon, quote and book clients. It requests only EUR/USD CASH on
IDEALPRO (`reqMktData`, snapshot=true, regulatorySnapshot=false), then inverts
the bid/ask midpoint to a USD→EUR observation at eight decimal places. This rate
is a float-derived observation, unlike the exact decimal financial inputs.
Sampler client-ID conflicts or invalid client-ID JSON disable the sampler with
a value-free reason. It uses
`cancelMktData` on success, error or timeout and disconnects its dedicated
client; it requests no account, order, execution or historical data.
The snapshot/cancellation mechanics follow the [IB API documentation](https://interactivebrokers.github.io/tws-api/md_request.html).

The one-second scheduler interprets America/New_York wall time: 09:30–16:00
RTH in 15-minute buckets, plus the fixed 16:05 close minute. Each RTH attempt
also requires a rolling 15-minute gap. A durable reservation precedes the IB
request, including across restart; this implementation chooses **zero retries**
(within the approved maximum of one). No catch-up request runs outside its
slot. RTH holidays and 13:00 early closes use the reviewed
[NYSE 2026–2028 calendar](https://ir.theice.com/press/news-details/2025/NYSE-Group-Announces-2026-2027-and-2028-Holiday-and-Early-Closings-Calendar/);
unknown years make no requests until that calendar is reviewed. For an
exceptional unscheduled market closure, OPS disables the sampler. The 16:05
sample remains fixed even on a scheduled early-close trading day. During
26–30 October 2026, 16:05 New York is **21:05 Vienna** (20:05 UTC), not 22:05.

`/var/lib/paper-desk-executor/results-fx.json` stores up to 14 sampled days,
each with bounded bucket reservations, attempt timestamp/reason and at most
27 `{rate, sampleAt, kind}` observations; the file cap is 256 KiB. It is a
separate executor state sidecar, never part of `ledger.json`. Capture copies
only changed dates’ samples and enabled/reason metadata into its durable cuts;
attempts and pending reservations remain private to the sidecar. Capture and
producer stream replay without retaining journal entries, and normal producer
polls verify the appended suffix plus a bounded tail anchor. The full source
prefix is checked again on restart. The producer retains frozen
historical closes after sidecar/ledger pruning. Preserve the two Results
journals when rolling back. A missing close is never backfilled the next day.
A day with USD activity is partial/yellow when disabled, sampling fails, or its
latest
RTH observation is more than 30 minutes old during RTH. A failed/missed close
keeps that USD day partial. Missing all usable FX excludes USD portions and
marks the day partial; EUR-only days are unaffected. Pending requests do not
publish a transient partial state.
Known limitation: a directory-sync error after sidecar rename can report
`state_unavailable` despite visible bytes; that bucket is not retried in the
same process. This affects only the FX sidecar, never the trading ledger,
capture-outage state or admission cap (unchanged in JOED-43).

Runtime kill switch, no rebuild or restart: OPS creates the regular file
`/var/lib/paper-desk-executor/FX-SAMPLER-OFF`, owned by 1000:1000, for example
`sudo install -m 0600 -o 1000 -g 1000 /dev/null /var/lib/paper-desk-executor/FX-SAMPLER-OFF`.
Contents are irrelevant. The next idle scheduler tick observes it; an already
in-flight snapshot finishes or times out within ten seconds. No later request
runs while it is present. An unreadable/invalid switch also disables requests.
OPS can remove its own switch with `trash` to resume in the next eligible
unreserved bucket. Disabling only affects Results completeness: it never
changes order admission, ownership, brakes, recon, HALT or `/v1/health`.

Live verification belongs to OPS after a separately reviewed deployment. Keep
all broker/account payloads private. Inspect the sidecar with a local script
that prints **only** day keys, sample counts, `sampleAt`, `kind`, attempt reasons
and file byte count; never print rates or the whole JSON. Check one request
per bucket and a single close, using timestamps rather than values. Confirm
that the OFF file suppresses the next eligible bucket and capture records
`enabled:false`; confirm producer day coverage is partial. Compare the
loopback health projection's ledgerBytes/ledgerPercent, status, brakes and
HALT before/after sampling, without printing its account field. Confirm the
sampler's client disconnects and has no remaining market-data lines in the
Gateway. Verify fills/recon through Amy's normal private paper workflow;
record only counts, digests and pass/fail on JOED-20.

Rollback starts by creating the OFF file and retaining it. Preserve the
sidecar and both journals (do not reset bucket reservations or producer
sequence). OPS then uses the normal reviewed rollback to the prior executor
source pin; round-8 baseline is `697959a6`. Keep Results disabled unless its
existing ingress and paper-reconciliation gates pass. This candidate neither
deploys nor changes producer enablement or board pins.
