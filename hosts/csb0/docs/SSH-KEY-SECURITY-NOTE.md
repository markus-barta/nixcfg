# SSH Key Security Note for csb0

## ⚠️ Critical: lib.mkForce Override Required

When using external Hokage modules from `github:pbek/nixcfg`, the `server-remote` role automatically injects SSH keys for omega (Patrizio). These include:

- `omega@yubikey` (sk-ecdsa)
- `omega@rsa` (ssh-rsa)
- `omega@semaphore` (ssh-ed25519)

## The Problem

Without override, both mba AND omega keys are accepted:

```nix
# What hokage does internally:
users.users.mba.openssh.authorizedKeys.keys = [
  "sk-ecdsa-sha2-nistp256@openssh.com ..." # omega@yubikey
  "ssh-rsa ..." # omega@rsa
  "ssh-ed25519 ..." # omega@semaphore
];
```

## The Solution

Use `lib.mkForce` to REPLACE (not merge) the SSH keys:

```nix
users.users.mba = {
  openssh.authorizedKeys.keys = lib.mkForce [
    # ONLY these keys can access csb0:
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABA..." # markus@iMac
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5..." # hsb1/Node-RED automation
  ];
};
```

## Incident History

### hsb8 Incident (2025-11-22)

- After migration, omega keys were injected
- Unexpected access was possible
- Fixed by adding `lib.mkForce` override

### hsb1 Lockout (2025-11-28)

- Migration used `lib.mkForce` for keys ✅
- But hokage also set `PasswordAuthentication = no`
- No password was set → Complete lockout!
- Required VNC console recovery

### csb1 Migration (2025-11-29) ✅

- Used `lib.mkForce` for SSH keys
- Enabled temporary password auth
- Set hashedPassword for mba user
- Successful migration with safety net

## csb0 Configuration

```nix
# hosts/csb0/configuration.nix

users.users.mba = {
  # Override hokage's SSH keys
  openssh.authorizedKeys.keys = lib.mkForce [
    # markus@iMac-5k-MBA-home.local (id_rsa)
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H1iVXWYKnHkxQsS7tGsZq3SoHxlVccd+kroMC/DhC4MWwVnJInWwDpo/bz7LiLuh+1Bmq04PswD78EiHVVQ+O7Ckk32heWrywD2vufihukhKRTy5zl6uodb5+oa8PBholTnw09d3M0gbsVKfLEi4NDlgPJiiQsIU00ct/y42nI0s1wXhYn/Oudfqh0yRfGvv2DZowN+XGkxQQ5LSCBYYabBK/W9imvqrxizttw02h2/u3knXcsUpOEhcWJYHHn/0mw33tl6a093bT2IfFPFb3LE2KxUjVqwIYz8jou8cb0F/1+QJVKtqOVLMvDBMqyXAhCkvwtEz13KEyt"
    # hsb1 (miniserver24): Node-RED container SSH automation
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAhUleyXsqtdA4LC17BshpLAw0X1vMLNKp+lOLpf2bw1 mba@miniserver24"
  ];
};

# TEMPORARY during migration - remove after!
services.openssh.settings.PasswordAuthentication = lib.mkForce true;
```

## Verification

After deployment, verify no omega keys exist:

```bash
ssh -p 2222 mba@cs0.barta.cm 'grep -c "omega" ~/.ssh/authorized_keys'
# Expected: 0
```

## Related

- [csb1 SSH Key Security Note](../../csb1/docs/SSH-KEY-SECURITY-NOTE.md)
- [hsb1 configuration.nix](../../hsb1/configuration.nix) - Reference implementation
