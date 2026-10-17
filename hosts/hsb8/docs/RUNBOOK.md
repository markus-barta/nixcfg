# Runbook: hsb8 (Parents' Home Server)

**Host**: hsb8 (192.168.1.100)  
**Role**: DNS/DHCP (AdGuard Home) + Home Automation at parents' home  
**Location**: ww87 (parents' home) - currently configured for this location  
**Criticality**: MEDIUM - Parents' network infrastructure  
**Owner**: Gerhard (gb) - primary admin when Markus is unavailable

---

## AdGuard admin rotation (OPS-372)

**Preparation only:** this revision removes the public verifier. It is not
safe to switch until the encrypted users file is provisioned and CI passes.
The agenix declaration is guarded by `builtins.pathExists`; the startup check
is deliberately unconditional while AdGuard is enabled. A missing, empty, or
malformed secret stops AdGuard (including DNS/DHCP), rather than opening the
admin interface. Removing a verifier changes the derivation: guard-off drvPath
identity with the old main is incompatible with that removal. OPS must resolve
that rollout criterion before approving a switch. No existing host is changed
by preparing this branch.

1. Markus chooses a **new** admin password in 1Password; do not reuse the
   exposed credential. Keep its value out of chat, shell history, command
   arguments, logs, and clipboard diagnostics. Preserve the previous encrypted
   secret and its matching 1Password revision for rollback when rotating later.
2. On **hsb8**, OPS prepares `/run/ops372-recipients` as root, mode 0600,
   containing only the public keys in `markus ++ hsb8` from
   `secrets/secrets.nix` (one key per line, all Markus identities, this host,
   no other users/hosts). Confirm this set against the declarations during
   review. Use the host's normal access path; do not move private keys or
   plaintext secrets onto a workstation.
3. On the host, generate the verifier and encrypt it directly. This command
   prompts through the terminal without displaying the password; the verifier
   travels only through private process memory and pipes. It creates a new
   encrypted candidate in `/run`, not a plaintext temporary file:

   ```bash
   sudo nix-shell -p apacheHttpd age python3 --run 'python3 -' <<'PYROTATE'
   import json, os, subprocess, sys
   os.umask(0o077)
   try:
       generated = subprocess.run(
           ['htpasswd', '-nBC', '12', 'admin'], check=True,
           stdout=subprocess.PIPE,
       ).stdout.decode().strip()
       name, separator, verifier = generated.partition(':')
       if name != 'admin' or not separator or len(verifier) != 60:
           raise ValueError()
       subprocess.run(
           ['age', '--encrypt', '-R', '/run/ops372-recipients',
            '--output', '/run/hsb8-adguard-users.age.next'],
           input=json.dumps([{'name': name, 'password': verifier}]).encode(),
           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
       )
   except Exception:
       sys.exit('Encryption failed; no credential output is permitted.')
   print('Encrypted candidate written.')
   PYROTATE
   ```

   The decrypted format is a nonempty JSON array of objects with exactly
   `name` and `password` fields. Names must be nonblank and unique; verifiers
   must have bcrypt syntax and cost 04–31. Do not display the candidate's
   plaintext or decrypt it for review. Remove any failed encrypted candidate
   through the operator's normal trash procedure before retrying.

4. After Markus's decision, OPS installs **only the ciphertext** at
   `secrets/hsb8-adguard-users.age` in its host-side review branch, opens a PR,
   and runs CI, including T105 and T47. Do not globally rekey. Adding the tracked
   file automatically enables both guarded recipient and agenix declarations;
   there is no extra flag. The runtime secret is
   `/run/agenix/hsb8-adguard-users` (`root:root`, 0400). Review both host
   candidates together before fleet rollout; switch each host only after its
   own file exists. Complete the independent approval gates, merge, then on
   this host use `gitpl && just switch`. A service restart alone does not run
   agenix activation. Never switch the preparation-only branch.
5. Verify unit state and DNS/DHCP with the existing host tests. Verify admin
   authentication by **status only**. In a host-local terminal, the following
   prints only the HTTP status, and sends no password in argv:

   ```bash
   python3 - <<'PYLOGIN'
   import getpass, json, urllib.request, urllib.error
   payload = json.dumps({'name': 'admin', 'password': getpass.getpass()}).encode()
   request = urllib.request.Request(
       'http://127.0.0.1:3000/control/login', data=payload,
       headers={'Content-Type': 'application/json'}, method='POST',
   )
   try:
       with urllib.request.urlopen(request, timeout=10) as response:
           print(response.status)
   except urllib.error.HTTPError as error:
       print(error.code)
   except Exception:
       print('login check failed')
   PYLOGIN
   ```

   Expect successful login status 200; an intentionally incorrect login must
   fail. Also check that unauthenticated `/control/status` is denied. Do not
   print bodies, cookies, headers, runtime YAML, or the users secret. Record
   statuses only on OPS-372, then close the local verification session.

6. **Rollback:** keep the users-secret hook active. Revert to the last known
   good encrypted users revision through a reviewed PR and CI, then
   `gitpl && just switch`; use its matching 1Password revision. For unrelated
   configuration regressions, select a recorded generation that already uses
   runtime secret users. The first cutover has no prior safe generation:
   repair the candidate or have Markus decide emergency recovery. Never
   silently restore the published verifier or remove the startup check.

The pinned upstream module is `nixos/modules/services/networking/adguardhome.nix`
at nixpkgs `f5c082a40f7571c266e74e80ae2e68aadd8a9fc7`: YAML is generated into
an immutable store template at lines 37–39; `mutableSettings = false` copies
it to `$STATE_DIRECTORY/AdGuardHome.yaml` at lines 178–204. systemd loads the
root-only secret via `LoadCredential`; the additional `ExecStartPre` runs as
DynamicUser after the upstream copy and existing DHCP hook. It reads JSON from
the private credentials directory, merges users via pinned `yq-go`, and
atomically replaces runtime YAML with mode 0600 and the same ownership. The
upstream sandbox remains active; no root merge step or privileged chown is needed. Parser diagnostics are
suppressed; errors produce a fixed message and prevent `ExecStart`. Password
changes in the UI are overwritten at the next restart; rotate through agenix.

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
