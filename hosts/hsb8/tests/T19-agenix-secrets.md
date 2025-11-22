# T19: Agenix Secret Management - Manual Test

Tests that agenix is properly configured and can decrypt secrets for DHCP static leases.

## Prerequisites

- SSH access to hsb8
- Agenix CLI installed on server
- `secrets/static-leases-hsb8.age` exists in repository

## Manual Test Procedure

### Step 1: Verify Agenix CLI is Available

```bash
ssh mba@192.168.1.100
which agenix
```

**Expected**: `/nix/store/.../bin/agenix` or similar path

### Step 2: Verify rage (encryption tool) is Available

```bash
ssh mba@192.168.1.100
which rage
```

**Expected**: `/nix/store/.../bin/rage` or similar path

### Step 3: Check Secrets Configuration

```bash
ssh mba@192.168.1.100
cd ~/nixcfg
cat hosts/hsb8/configuration.nix | grep -A 5 "age.secrets"
```

**Expected**: Configuration should reference `static-leases-hsb8.age`

### Step 4: Verify Secret File Exists in Repository

```bash
ssh mba@192.168.1.100
cd ~/nixcfg
test -f secrets/static-leases-hsb8.age && echo "✅ Secret file exists" || echo "❌ Secret file missing"
```

**Expected**: "✅ Secret file exists"

### Step 5: Check Host Key in secrets.nix

```bash
ssh mba@192.168.1.100
cd ~/nixcfg
grep "hsb8 =" secrets/secrets.nix -A 1
```

**Expected**: Should show hsb8 host SSH key

### Step 6: Verify Secret is Decrypted at Runtime

```bash
ssh mba@192.168.1.100
test -f /run/agenix/static-leases-hsb8 && echo "✅ Secret decrypted" || echo "❌ Secret not decrypted"
```

**Expected**: "✅ Secret decrypted" (only if DHCP enabled and system activated)

### Step 7: Validate JSON Format (if decrypted)

```bash
ssh mba@192.168.1.100
if [ -f /run/agenix/static-leases-hsb8 ]; then
  cat /run/agenix/static-leases-hsb8 | jq empty && echo "✅ Valid JSON" || echo "❌ Invalid JSON"
fi
```

**Expected**: "✅ Valid JSON"

### Step 8: Count Static Leases

```bash
ssh mba@192.168.1.100
if [ -f /run/agenix/static-leases-hsb8 ]; then
  jq 'length' /run/agenix/static-leases-hsb8
fi
```

**Expected**: Should show number of static leases (e.g., 27)

## Expected Results

- ✅ Agenix CLI available on server
- ✅ rage encryption tool available
- ✅ Secret file exists in repository
- ✅ hsb8 host key configured in secrets.nix
- ✅ Secret decrypts properly (when DHCP enabled)
- ✅ JSON format is valid

## Troubleshooting

### Secret Not Decrypted

If `/run/agenix/static-leases-hsb8` doesn't exist:

1. Check if DHCP is enabled in configuration
2. Check if `useSecrets = true` in hokage config
3. Check systemd logs: `sudo journalctl -u agenix -n 50`
4. Verify host key matches: `cat /etc/ssh/ssh_host_rsa_key.pub`

### Invalid JSON

If JSON validation fails:

```bash
cd ~/Code/nixcfg
agenix -e secrets/static-leases-hsb8.age
# Fix JSON format, save, and redeploy
```

### Permission Denied

If agenix can't decrypt:

1. Verify your SSH key is in `secrets/secrets.nix` (markus key)
2. Verify hsb8 host key is in `secrets/secrets.nix`
3. Check file ownership: `ls -la secrets/static-leases-hsb8.age`

## Test Results Log

| Date | Manual | Auto | Notes |
| ---- | ------ | ---- | ----- |
|      |        | ⏳   |       |

## Notes

- Static leases stored encrypted in git (`secrets/static-leases-hsb8.age`)
- Dual-key encryption: Markus' SSH key + hsb8 host key
- Decrypted at boot by agenix to `/run/agenix/static-leases-hsb8`
- Format: `[{"mac": "AA:BB:CC:DD:EE:FF", "ip": "192.168.1.X", "hostname": "device"}]`
- Based on Pi-hole backup data from parents' network
- Contains ~27 static leases for critical devices (Orbi routers, Shelly switches, cameras, etc.)
