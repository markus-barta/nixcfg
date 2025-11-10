# SSH Keys for miniserver99

## Your Keys

**Personal (Use for NixOS):**

- `~/.ssh/id_rsa` + `.pub`
- RSA, created June 2019
- ✅ Configured in `secrets/secrets.nix` for private-only access

**Company (BYTEPOETS):**

- `~/.ssh/id_ed25519_bytepoets` + `.pub`
- ED25519, for work only

**GitHub Actions:**

- `~/.ssh/github-actions-deploy` + `.pub`
- Automated deployments

## Backup

**1Password:** Store private key `~/.ssh/id_rsa` as secure note
