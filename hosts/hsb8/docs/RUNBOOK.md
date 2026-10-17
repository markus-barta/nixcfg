# Runbook: hsb8 (Parents' Home Server)

**Host**: hsb8 (192.168.1.100)  
**Role**: DNS/DHCP (AdGuard Home) + Home Automation at parents' home  
**Location**: ww87 (parents' home) - currently configured for this location  
**Criticality**: MEDIUM - Parents' network infrastructure  
**Owner**: Gerhard (gb) - primary admin when Markus is unavailable

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
# At ww87 (parents' home), prefer gb user (primary operator for HA/Docker)
ssh gb@192.168.1.100
ssh gb@hsb8.lan

# Accessing Home Assistant Config (on hsb8)
# Path: /srv/hsb8/mounts/homeassistant/configuration.yaml
# Note: File is owned by root, use 'sudo' for edits.
# Backups: ./Archive/
```

---

## Quick Reference Card

```
╔════════════════════════════════════════════════════════════╗
║ 🌀 hsb8 - Parents' Home Emergency Reference                ║
╠════════════════════════════════════════════════════════════╣
║ SSH:       ssh mba@192.168.1.100                           ║
║ Users:     mba (admin), gb (Gerhard)                       ║
║ Location:  ww87 (parents' home)                            ║
╠════════════════════════════════════════════════════════════╣
║ 🌐 SERVICES (when at ww87)                                 ║
║ • HostDash:       http://192.168.1.100                     ║
║ • Home Assistant: http://192.168.1.100:8123                ║
║ • AdGuard Home:   http://192.168.1.100:3000                ║
║ • DNS Server:     192.168.1.100:53                         ║
║ • Zigbee2MQTT:    http://192.168.1.11:8085 (external)      ║
╠════════════════════════════════════════════════════════════╣
║ 🚨 IF DOWN                                                 ║
║ 1. SSH check: ssh mba@192.168.1.100                        ║
║ 2. Physical access to Mac mini (if SSH fails)              ║
║ 3. Rollback: sudo nixos-rebuild switch --rollback          ║
╚════════════════════════════════════════════════════════════╝
```

---

## Common Tasks

### Update & Switch Configuration

```bash
ssh mba@192.168.1.100
cd ~/nixcfg
git pull
just switch
```

### Rollback to Previous Generation

```bash
ssh mba@192.168.1.100
sudo nixos-rebuild switch --rollback
```

### Switch Location (jhw22 ↔ ww87)

⚠️ **Requires physical access** - Network gateway changes during switch!

```bash
# At physical console (SSH won't work during switch)
enable-ww87    # Switch to parents' home config
# OR manually edit configuration.nix and change location
```

---

## Health Checks

### Quick Status

```bash
ssh mba@192.168.1.100 "systemctl status adguardhome && zpool status | head -10"
```

### AdGuard Home Status (when at ww87)

```bash
ssh mba@192.168.1.100 "systemctl status adguardhome"
curl -I http://192.168.1.100:3000
```

### Docker Status

```bash
ssh mba@192.168.1.100 "docker ps"
```

### ZFS Pool Status

```bash
ssh mba@192.168.1.100 "zpool status"
```

---

## Troubleshooting

### AdGuard Home Not Responding

```bash
ssh mba@192.168.1.100
systemctl status adguardhome
journalctl -u adguardhome -n 50 --no-pager
sudo systemctl restart adguardhome
```

### DNS Not Resolving

1. Check if AdGuard Home is running
2. Check upstream DNS: `dig @1.1.1.1 google.com`
3. Verify location is set to ww87: `grep "location =" ~/nixcfg/hosts/hsb8/configuration.nix`

### Static DHCP Leases Not Loading

```bash
# Check agenix secret
ls -la /run/agenix/static-leases-hsb8

# Validate JSON format
cat /run/agenix/static-leases-hsb8 | jq empty

# Check preStart logs
journalctl -u adguardhome | grep -i "static"
```

### Network Issues After Rebuild

⚠️ If network fails after rebuild, you likely have wrong location setting:

```bash
# Check current location in config
grep "location =" ~/nixcfg/hosts/hsb8/configuration.nix

# ww87 = parents' home (gateway 192.168.1.1)
# jhw22 = Markus' home (gateway 192.168.1.1 since the Starlink/Omada migration)
```

---

## Emergency Recovery

### If SSH Fails

1. Physical access to Mac mini required
2. Connect keyboard and monitor
3. Login as `gb` (preferred primary user) or `mba` (if needed for admin tasks)

### Restore from Generation

```bash
# List available generations
sudo nix-env --list-generations -p /nix/var/nix/profiles/system

# Switch to specific generation
sudo nix-env --switch-generation N -p /nix/var/nix/profiles/system
sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
```

---

## Services

### AdGuard Home (when at ww87)

| Item             | Value                         |
| ---------------- | ----------------------------- |
| **Web UI**       | http://192.168.1.100:3000     |
| **DNS Port**     | 53                            |
| **DHCP Range**   | 192.168.1.225-254             |
| **DHCP Gateway** | 192.168.1.1                   |
| **Upstream DNS** | 1.1.1.1, 1.0.0.1 (Cloudflare) |

### Docker

- Gerhard (`gb`) user has Docker access
- Configuration: **declarative** — `hosts/hsb8/docker/compose-spec.nix` in nixcfg,
  rendered into the system closure and reconciled by `compose-hsb8.service`.
  Never hand-edit compose on the host.
- Data lives under `/srv/hsb8/mounts/` (NIX-236 moved it off `/home/gb`).
  `/home/gb/docker/` is **retired and gone** — if a doc still points there, it is stale.

### Home Assistant (Deployed 2025-12-21)

| Item                    | Value                                  |
| ----------------------- | -------------------------------------- |
| **Web UI**              | http://192.168.1.100:8123              |
| **User**                | gb (primary operator)                  |
| **MQTT Broker**         | External: 192.168.1.11:1883 (z2m host) |
| **Zigbee2MQTT**         | External: http://192.168.1.11:8085     |
| **Custom Integrations** | HACS, Kostal Piko, Tesla Custom        |

#### Docker Containers

```bash
# Check status
ssh mba@192.168.1.100 "docker ps --format 'table {{.Names}}\t{{.Status}}'"

# Expected containers:
# - homeassistant (HA core)
# - mosquitto (local MQTT, may be unused)
# - hsb8-home (HostDash nginx)
# - pharos-beacon (fleet reporting, outbound only)
# - restic-cron-hetzner (backups)
#
# NOT watchtower. It was retired and is actively reaped by
# composeStack removeOrphans = true. If it ever reappears, something
# is running an unmanaged compose file.
```

#### Integrations Configured

| Integration  | Purpose                       | Config Method             |
| ------------ | ----------------------------- | ------------------------- |
| MQTT         | Zigbee devices via z2m        | UI (broker: 192.168.1.11) |
| Zigbee2MQTT  | z2m UI integration            | HACS + UI                 |
| Kostal Piko  | Solar inverter (192.168.1.20) | YAML                      |
| Tesla Custom | Tesla vehicle                 | HACS + UI                 |
| Tasmota      | Smart plugs/switches          | Auto-discovered via MQTT  |

#### HA Logs

```bash
# View logs
ssh mba@192.168.1.100 "docker logs homeassistant --tail 50"

# Follow logs
ssh mba@192.168.1.100 "docker logs -f homeassistant"

# Restart HA
ssh mba@192.168.1.100 "docker restart homeassistant"
```

#### HACS

Installed custom integrations are in `/srv/hsb8/mounts/homeassistant/custom_components/`:

- `hacs` - Home Assistant Community Store
- `kostal` - Kostal Piko solar inverter
- `tesla_custom` - Tesla vehicle integration

To install new integrations: HACS → Integrations → Explore & Download

---

## Maintenance

### Clean Up Disk Space

```bash
ssh mba@192.168.1.100 "cd ~/nixcfg && just cleanup"
```

### ZFS Scrub

```bash
ssh mba@192.168.1.100 "sudo zpool scrub zroot"
```

### View Logs

```bash
# Current boot
ssh mba@192.168.1.100 "journalctl -b -e"

# Follow logs
ssh mba@192.168.1.100 "journalctl -f"
```

---

## User Access

| User  | Role                             | SSH Key          | Telegram Chat ID |
| ----- | -------------------------------- | ---------------- | ---------------- | ------------------------------------- |
| `gb`  | Owner/Primary Operator (Gerhard) | Personal RSA key | 873192422        | # Preferred for ww87 ops (HA/Docker)  |
| `mba` | Secondary Admin (Markus)         | Personal RSA key | 855566964        | # Backup access; check keys if denied |

Both users have passwordless sudo.

---

## Container updates — and the notification gap

Watchtower is **retired**. It is gone from the host (no container, not even
stopped) and its env file `/home/gb/secrets/watchtower.env` no longer exists.
`composeStack.removeOrphans = true` actively reaps it, so it cannot drift back.

Updates now run declaratively:

|             |                                                                                   |
| ----------- | --------------------------------------------------------------------------------- |
| Unit        | `compose-hsb8-update.service` (OPS-125) — pulls newer images, converges the stack |
| Schedule    | `compose-hsb8-update.timer`, weekly (Sat ~05:05)                                  |
| Declared in | `hosts/hsb8/configuration.nix` → `composeStack.autoUpdate.enable = true`          |

```bash
systemctl list-timers compose-hsb8-update.timer --no-pager
systemctl status compose-hsb8-update.service --no-pager | tail -20
journalctl -u compose-hsb8-update.service --since '2 weeks ago' | tail -40
```

> 🟡 **Decision (NIX-385): keep this updater intentionally silent for now.**
> `autoUpdate` sends no Telegram, mail or ntfy notification. hsb8 has no
> host-scoped outbound notification transport: its backup reports through a
> Pharos status file, while the Telegram bot is owned remotely by csb0. Reusing
> either path here would widen secret access or couple this family server to a
> different host. A failed update remains durable and visible as a failed
> systemd unit; it is not converted into success. Check the unit journal after
> the Saturday run.

Revisit this decision when a reviewed fleet-wide host-alert transport exists,
or before increasing the update cadence. At that point, add failure-only
delivery without exposing container environment files to the host service.

The `@janischhofweg22bot` Telegram bot still exists and is managed from csb0
Node-RED, but it is no longer fed by container updates. Treat any doc claiming
"Watchtower sends update notifications" as stale.

If the token itself ever needs replacing, rotate it in BotFather and write the new
value straight into the file with `sudo -e` — never via a command line that would
land in history.

---

## Related Documentation

- [NETWORK.md](./NETWORK.md) - ww87 network topology, device inventory, Orbi mesh, diagnostic playbook
- [hsb8 README](../README.md) - Full server documentation
- [ip-100.md](../ip-100.md) - Identity Card (Static IP, MAC, Gateway)
- [SECRETS.md](../secrets/SECRETS.md) - All credentials (gitignored)
- [enable-ww87.md](./enable-ww87.md) - Location switching guide
- [hsb0 Runbook](../../hsb0/docs/RUNBOOK.md) - DNS server at Markus' home

---

## 🔴 Critical Known Issues (Gotchas)

### 🚨 Historical Incident: 2025-11-22 SSH Lockout

**Symptom:** Complete loss of SSH access after reboot.
**Root Cause:** When migrating to the "External Hokage Consumer" pattern, the default hokage configuration injected external developer keys (omega@\*) and removed local authorized keys.
**Impact:** Required physical console access to recover.
**Fix:** Always use `lib.mkForce` for `users.users.<name>.openssh.authorizedKeys.keys` to block external key injection.
**Security Policy:** Familly servers (`hsb0`, `hsb8`) MUST NOT allow external developer keys.

### 📍 Location Switching (ww87 ↔ jhw22)

**Symptom:** Server reachable via IP but no internet/DNS after transport.
**Cause:** Gateway and DNS settings differ between locations.

- **ww87 (Parents)**: Gateway `192.168.1.1`
- **jhw22 (Markus)**: Gateway `192.168.1.1` (was `.5` pre-Starlink) — DNS/AdGuard
  still differ between locations, which is what makes the switch necessary
  **Fix:** Run `enable-ww87` at the physical console after transport to apply location-specific networking.

---

## 📋 Deployment & Initial Setup

### Phase 1: Configuration Switch

If moving the server between locations:

1. Log in at console as `mba`.
2. Run: `enable-ww87` (one-command deployment).
3. Wait for configuration to apply (~2-3 minutes).
4. Network will reconfigure (may lose console connection briefly).

### Phase 2: DHCP state

✅ **hsb8 IS the ww87 DHCP server** — takeover from the old router
completed months ago (declared `dhcp.enabled = true` in
`configuration.nix`; confirmed live 2026-07-04, NIX-215 fleet rebuild).

If relocating to a site with an existing DHCP server, disable FIRST:

1. Edit `hosts/hsb8/configuration.nix`.
2. Set `services.adguardhome.settings.dhcp.enabled = false;`.
3. `just switch`.
4. Verify DHCP is gone: `ss -ulnp | grep :67` (no listener).

---

## 🔐 Handover Inventory (2025-11-23)

| Service        | Port | URL / Access                        |
| -------------- | ---- | ----------------------------------- |
| AdGuard Home   | 3000 | http://192.168.1.100:3000           |
| Home Assistant | 8123 | http://192.168.1.100:8123           |
| Zigbee2MQTT    | 8085 | http://192.168.1.11:8085 (external) |
| SSH (mba/gb)   | 22   | ssh 192.168.1.100                   |

### System Stats

- **Storage**: ZFS (zroot) on 120GB SSD (~7% used).
- **Users**: `mba` (admin), `gb` (Gerhard/Owner).
- **Backup**: 15+ generations for rollback.
