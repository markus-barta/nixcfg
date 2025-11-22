# Security Analysis: Passwordless Sudo + User Password

## Configuration Options Comparison

### Option 1: Current Plan (Recommended)

```nix
users.users.mba = {
  # Has password: yes (strong one)
  # Can sudo: yes, passwordless
  openssh.authorizedKeys.keys = lib.mkForce [ "ssh-rsa ..." ];
};
security.sudo-rs.wheelNeedsPassword = false;
```

**Attack Scenarios**:

| Attack Vector       | Can they login?     | Can they sudo?        | Risk Level |
| ------------------- | ------------------- | --------------------- | ---------- |
| SSH from internet   | ❌ No (needs key)   | N/A                   | ✅ None    |
| Container breakout  | ⚠️ If weak password | ✅ Yes (passwordless) | ⚠️ Medium  |
| Physical access     | ⚠️ If weak password | ✅ Yes (passwordless) | ⚠️ Medium  |
| SSH with stolen key | ✅ Yes              | ✅ Yes                | 🚨 High    |

**Key Point**: If attacker gets IN (password or key), they can sudo freely.

### Option 2: Password for Sudo Too

```nix
users.users.mba = {
  # Has password: yes (strong one)
  # Can sudo: yes, but needs password again
  openssh.authorizedKeys.keys = lib.mkForce [ "ssh-rsa ..." ];
};
security.sudo-rs.wheelNeedsPassword = true;  # <- The difference
```

**Attack Scenarios**:

| Attack Vector       | Can they login?     | Can they sudo?                | Risk Level |
| ------------------- | ------------------- | ----------------------------- | ---------- |
| SSH from internet   | ❌ No (needs key)   | N/A                           | ✅ None    |
| Container breakout  | ⚠️ If weak password | ❌ No (needs password again!) | ✅ Low     |
| Physical access     | ⚠️ If weak password | ⚠️ If weak password           | ⚠️ Medium  |
| SSH with stolen key | ✅ Yes              | ❌ No (needs password)        | ⚠️ Medium  |

**Key Point**: Two-factor defense - must know password AND get in.

### Option 3: No User Password (Current Concern)

```nix
users.users.mba = {
  hashedPassword = "!";  # Disabled!
  # Can sudo: yes, passwordless
  openssh.authorizedKeys.keys = lib.mkForce [ "ssh-rsa ..." ];
};
security.sudo-rs.wheelNeedsPassword = false;
```

**Attack Scenarios**:

| Attack Vector       | Can they login?       | Can they sudo?         | Risk Level |
| ------------------- | --------------------- | ---------------------- | ---------- |
| SSH from internet   | ❌ No (needs key)     | N/A                    | ✅ None    |
| Container breakout  | ❌ No password exists | ✅ Yes (if already in) | ⚠️ Medium  |
| Physical access     | ❌ Can't login        | N/A                    | ✅ None    |
| SSH with stolen key | ✅ Yes                | ✅ Yes                 | 🚨 High    |

**Key Point**: Very secure from password attacks, but NO recovery if SSH breaks!

## The Container Breakout Scenario (Detailed)

### What Actually Happens:

```bash
# Inside compromised container
whoami
# Output: container_user (UID 1000)

# Try to access mba user
su - mba
# Needs password!

# Can they escalate?
sudo whoami
# Either:
# a) sudo: not in sudoers file (container user has no sudo rights)
# b) sudo: password required (if they're not in wheel group)
```

**Critical Point**: Container processes run as different users (usually), not as your `mba` user!

### If Container Runs as Root (Docker default):

```bash
# Inside compromised container with root
whoami
# Output: root (but containerized root, limited)

# Can they break out to host?
# Depends on:
# - Docker security settings
# - Kernel vulnerabilities
# - Container capabilities
# - AppArmor/SELinux policies
```

**If they DO break out to host root**: Password doesn't matter - they're already root!

## The Real Security Layers

```
┌─────────────────────────────────────────┐
│ Layer 1: Network Firewall               │ ← Blocks external access
├─────────────────────────────────────────┤
│ Layer 2: SSH Key Authentication         │ ← Your main protection
├─────────────────────────────────────────┤
│ Layer 3: Container Isolation            │ ← Prevents breakout
├─────────────────────────────────────────┤
│ Layer 4: User Permissions               │ ← Limits container user
├─────────────────────────────────────────┤
│ Layer 5: User Password                  │ ← YOUR CONCERN
├─────────────────────────────────────────┤
│ Layer 6: Sudo Password                  │ ← What we're removing
└─────────────────────────────────────────┘
```

**Your question**: "Should Layer 6 (sudo password) exist if Layer 5 (user password) is weak?"

**Answer**: YES! It's defense-in-depth.

## Recommendations

### For hsb8 (Home Server)

**Best Practice**:

```nix
# Strong user password (emergency access)
users.users.mba = {
  # Set via: sudo passwd mba
  # Use: correct-horse-battery-staple-2025
};

# KEEP sudo password requirement
security.sudo-rs.wheelNeedsPassword = true;
```

**Tradeoff**: Less convenient (need password for sudo), but more secure.

### For Remote Servers (csb0, csb1)

**Best Practice**:

```nix
# No user password (SSH only)
users.users.mba = {
  hashedPassword = "!";
};

# Passwordless sudo (already SSH-authenticated)
security.sudo-rs.wheelNeedsPassword = false;
```

**Rationale**: No physical access possible, SSH key is the security boundary.

## Your Specific Case

**hsb8 Profile**:

- Home server (physical access possible)
- Will run Docker containers
- Network-facing services (AdGuard DNS/DHCP)
- Located at family home (lower risk)

**My Recommendation**:

1. **Set a STRONG password**:

   ```bash
   ssh mba@192.168.1.100
   sudo passwd mba
   # Use: correct-horse-battery-staple-2025
   # Or generate: pwgen -s 20 1
   ```

2. **Keep sudo password requirement** (more secure):

   ```nix
   security.sudo-rs.wheelNeedsPassword = true;
   ```

3. **Accept the inconvenience**:
   - Remote deployments need password
   - More secure against container breakout
   - Better for a server with Docker

### Alternative: Risk-Based Decision

**Low-risk scenario** (current):

- Keep passwordless sudo (our current plan)
- Strong password on user account
- Accept: If someone breaks container + guesses password, they have root
- Probability: Very low on home network

**High-risk scenario** (if running untrusted containers):

- Require sudo password
- Strong password on user account
- Defense-in-depth: Even with container breakout + password guess, can't sudo
- Probability: Protected against most attacks

## The Bottom Line

**Your intuition is correct**: Passwordless sudo + weak password IS a security risk.

**The fix**: Strong password + passwordless sudo = acceptable risk for home server.

**The paranoid fix**: Strong password + sudo requires password = maximum security.

**The question for you**: How convenient vs. how paranoid?

For a home server running Docker, I'd say:

- ✅ Strong password (generate one)
- ✅ Passwordless sudo (convenience)
- ✅ Good container security practices
- ✅ Minimal attack surface

**But if you're concerned**: Keep `wheelNeedsPassword = true` and accept the inconvenience of entering password for sudo.
