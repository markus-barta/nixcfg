# P9501 - HSB2: Rename Host from raspi01 to hsb2

## Status: 🔵 PLANNED

Migrate the Raspberry Pi Zero W hostname from `raspi01` to `hsb2` to align with the infrastructure naming convention (`hsb*` = Home Server Barta).

## Current State

| Item       | Current                | Target      |
| ---------- | ---------------------- | ----------- |
| Hostname   | `raspi01`              | `hsb2`      |
| IP Address | `192.168.1.95`         | (unchanged) |
| OS         | Raspbian 11 (bullseye) | (unchanged) |

## Required Changes

### 1. On the Machine (192.168.1.95)

**Files to modify:**

- `/etc/hostname` - Change from `raspi01` to `hsb2`
- `/etc/hosts` - Update `127.0.1.1` line from `raspi01` to `hsb2`

**Command sequence:**

```bash
ssh mba@192.168.1.95

# Change hostname
echo 'hsb2' | sudo tee /etc/hostname

# Update hosts file
sudo sed -i 's/127.0.1.1\traspi01/127.0.1.1\thsb2/' /etc/hosts

# Verify changes
cat /etc/hostname
cat /etc/hosts | grep 127.0.1.1

# Reboot to apply
sudo reboot
```

**Post-reboot verification:**

```bash
ssh mba@192.168.1.95
hostname  # Should output: hsb2
hostnamectl status  # Should show Static hostname: hsb2
```

### 2. In nixcfg Repository

**Files to update:**

| File                   | Line | Current Text                       | Change To    |
| ---------------------- | ---- | ---------------------------------- | ------------ |
| `hosts/hsb2/README.md` | 12   | `` `hsb2` (currently `raspi01`) `` | `` `hsb2` `` |

**Note:** The reference to `raspi01` in `hosts/hsb0/README.md` (line 718) is historical context about UPS migration and should remain as-is for documentation purposes.

### 3. In Secrets (AGE-Encrypted)

**Files to update (user handles):**

- Static DHCP leases configuration - Update hostname from `raspi01` to `hsb2` for IP 192.168.1.95

## Acceptance Criteria

- [ ] Machine reports hostname `hsb2` after reboot
- [ ] `/etc/hostname` contains `hsb2`
- [ ] `/etc/hosts` contains `127.0.1.1 hsb2`
- [ ] `hosts/hsb2/README.md` updated (remove "currently raspi01")
- [ ] Static leases file updated (handled by user)
- [ ] SSH access works via both `ssh mba@192.168.1.95` and `ssh mba@hsb2.lan` (after DNS/cache updates)

## Risk Assessment

**Risk Level**: 🟢 LOW

- Hostname change is cosmetic on a single-node Raspbian system
- No services depend on hostname for functionality
- IP address remains unchanged (192.168.1.95)
- SSH access via IP is unaffected
- Can be reverted by changing files back and rebooting

## Rollback Plan

If issues occur:

```bash
ssh mba@192.168.1.95
echo 'raspi01' | sudo tee /etc/hostname
sudo sed -i 's/127.0.1.1\thsb2/127.0.1.1\traspi01/' /etc/hosts
sudo reboot
```

## Related

- **Host**: `hsb2` (192.168.1.95)
- **Previous Task**: P9500 (NixOS migration - abandoned)
- **Location**: Home LAN (192.168.1.0/24)
