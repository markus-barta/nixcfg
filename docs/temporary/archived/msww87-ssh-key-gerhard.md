# SSH Key Added - Gerhard (gb user)

**Date**: November 16, 2025  
**User**: `gb` (Gerhard)  
**Machine**: msww87  
**Status**: ✅ Configured, pending deployment

---

## What Was Done

Added Gerhard's SSH public key to the `gb` user account on msww87.

### Configuration Changes

**File**: `hosts/msww87/configuration.nix`

```nix
users.users.gb = {
  openssh.authorizedKeys.keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDAwgtI71qYnLJnq0PPs/PWR0O+0zvEQfT7QYaHbrPUdILnK5jqZTj6o02kyfce6JLk+xyYhI596T6DD9But943cKFY/cYG037EjlECq+LXdS7bRsb8wYdc8vjcyF21Ol6gSJdT3noAzkZnqnucnvd7D1lae2ZVw7km6GQvz5XQGS/LQ38JpPZ2JYb0ufT3Z1vgigq9GqhCU6C7NdUslJJJ1Lj4JfPqQTbS1ihZqMe3SQ+ctfmHNYniUkd5Potu7wLMG1OJDL13BXu/M5IihgerZ3QuPb2VPQkb37oxKfquMKveYL9bt4fmK+7+CRHJnzFB45HfG5PiTKsyjuPR5A1N3U5Os+9Wrav9YrqDHWjCaFI1EIY4HRM/kRufD+0ncvvXpsp4foS9DAhK5g3OObRlKgPEc4hkD7hC2KBXUt7Kyg6SLL89gD42qSXLxZlxaTD65UaqB28PuOt7+LtKEPhm1jfH65cKu5vGqUp3145hSJuHB4FuA0ieplfxO78psVM= Gerhard@imac-gb.local"
  ];
};
```

**Source**: `~/Downloads/id_rsa.pub` (from Gerhard's Mac - imac-gb.local)

---

## How to Deploy

### Option 1: Deploy from msww87 directly

```bash
# SSH into msww87
ssh mba@192.168.1.223

# If nixcfg not cloned yet:
mkdir -p ~/Code
cd ~/Code
git clone <your-repo-url> nixcfg
cd nixcfg

# Or if already cloned:
cd ~/Code/nixcfg
git pull

# Deploy the configuration
just switch
```

### Option 2: Deploy via nixos-rebuild from your Mac

```bash
cd ~/Code/nixcfg
nixos-rebuild switch --flake .#msww87 --target-host mba@192.168.1.223 --use-remote-sudo
```

---

## Testing SSH Access

After deployment, Gerhard can test SSH access from his Mac:

```bash
# From Gerhard's Mac (imac-gb.local)
ssh gb@192.168.1.223

# After static IP configuration (when .100 is active):
ssh gb@192.168.1.100
ssh gb@msww87.lan
```

**Expected behavior**: Direct login without password prompt.

---

## User Account Details

### Username in SSH Key vs System Username

- **Comment in key**: `Gerhard@imac-gb.local`
  - This is just a label/comment
  - NOT used for authentication
  - Helps identify which key is which

- **System username**: `gb`
  - This is what matters for authentication
  - Created by `hokage.users = ["mba", "gb"]` in the config
  - Determines which user account the key grants access to

### Permissions

The `gb` user is configured with:

- Standard home directory: `/home/gb`
- SSH access via public key authentication
- Normal user privileges (not in `wheel` group = no sudo by default)

If `gb` needs sudo access, add to configuration:

```nix
users.users.gb = {
  extraGroups = [ "wheel" ];
  openssh.authorizedKeys.keys = [ ... ];
};
```

---

## Key Information

**Key Type**: RSA 3072-bit  
**Key Format**: OpenSSH public key  
**Fingerprint**: (calculate with `ssh-keygen -lf id_rsa.pub`)  
**Source Machine**: imac-gb.local (Gerhard's iMac)  
**Private Key Location**: `~/.ssh/id_rsa` on Gerhard's Mac (should remain private!)

---

## Security Notes

1. ✅ **Public key only** - Private key remains on Gerhard's Mac
2. ✅ **No password** required for SSH (key-based authentication)
3. ✅ **User isolation** - `gb` and `mba` are separate accounts
4. ⚠️ **Backup important** - Gerhard should back up his private key securely

---

## Troubleshooting

### Issue: "Permission denied (publickey)"

**Possible causes:**

1. Configuration not deployed yet → run `just switch`
2. Wrong username → use `ssh gb@...` not `ssh gerhard@...`
3. Private key not in standard location → use `ssh -i /path/to/key gb@...`
4. SSH agent not running → run `ssh-add ~/.ssh/id_rsa`

**Debug:**

```bash
# Verbose SSH connection
ssh -v gb@192.168.1.223

# Check which keys are offered
ssh -v gb@192.168.1.223 2>&1 | grep "Offering public key"
```

### Issue: "Host key verification failed"

**Cause**: SSH doesn't recognize the server's host key

**Solution**:

```bash
# Remove old host key (if machine was reinstalled)
ssh-keygen -R 192.168.1.223
# or
ssh-keygen -R msww87.lan

# Try connecting again
ssh gb@192.168.1.223
```

---

## Next Steps

- [ ] Deploy configuration to msww87
- [ ] Test SSH access from Gerhard's Mac
- [ ] Consider configuring static IP (separate task)
- [ ] Decide if `gb` needs sudo privileges

---

## Related Documentation

- [msww87 Server Notes](./msww87-server-notes.md) - Full system documentation
- [msww87 Setup Steps](./msww87-setup-steps.md) - Static IP configuration guide
- [NixOS SSH Configuration](https://nixos.wiki/wiki/SSH_public_key_authentication) - Official docs
