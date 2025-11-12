# Justfile Commands Reference

This document covers useful commands available via the `justfile` task runner.

## Quick Start

```bash
# View all available commands
just --list

# View commands in a specific group
just --list | grep agenix
just --list | grep build
```

---

## Encryption & Secrets (agenix group)

### encrypt-file - Encrypt sensitive files

Encrypts any file in the `hosts/HOSTNAME/` directory structure using both your SSH key and the target host's key.

**Usage:**
```bash
just encrypt-file hosts/HOSTNAME/filename
```

**Examples:**
```bash
# Encrypt static DHCP leases
just encrypt-file hosts/miniserver99/static-leases.nix

# Encrypt API keys
just encrypt-file hosts/home01/api-keys.env

# Encrypt database credentials
just encrypt-file hosts/netcup01/db-config.conf
```

**What it does:**
1. Auto-detects hostname from path (`hosts/miniserver99/` → `miniserver99`)
2. Finds your SSH public key (`~/.ssh/id_rsa.pub` or `~/.ssh/id_ed25519.pub`)
3. Checks if SSH key has a passphrase (security reminder)
4. Extracts host's public key from `secrets/secrets.nix`
5. Warns if file exists in Git history
6. Encrypts with **both keys** (you can decrypt, host can decrypt)
7. Validates encryption was successful
8. Saves to `secrets/filename-hostname.age`
9. Atomically adds source file to `.gitignore` (if not already there)
10. Stages encrypted file and `.gitignore` for commit

**Security Features:**
- ✅ Dual-key encryption (redundancy)
- ✅ Encryption validation (ensures file is decryptable)
- ✅ Passphrase reminder (if SSH key unprotected)
- ✅ Git history check (warns if plaintext was committed)
- ✅ Atomic .gitignore updates (prevents race conditions)

**Requirements:**
- File must be in `hosts/HOSTNAME/` directory structure
- Host must be defined in `secrets/secrets.nix`
- `rage` must be installed (`nix-shell -p rage` or on macOS: `brew install rage`)

### decrypt-file - Decrypt encrypted files

Decrypts an `.age` file back to plaintext.

**Usage:**
```bash
just decrypt-file ENCRYPTED_FILE [OUTPUT_FILE]
```

**Examples:**
```bash
# Auto-detect output location
just decrypt-file secrets/static-leases-miniserver99.age

# Specify output location explicitly
just decrypt-file secrets/api-keys-home01.age hosts/home01/api-keys.env
```

**What it does:**
1. Creates timestamped backup if output file exists
2. Creates output directory if needed
3. Decrypts using your SSH private key
4. Saves to output location

**Auto-detection:**
- Pattern: `filename-hostname.age` → `hosts/hostname/filename.nix`
- Falls back to common extensions: `.nix`, `.conf`, `.env`, `.txt`

---

## Build & Deploy (build group)

### switch - Build and deploy current configuration

```bash
just switch
```

Builds and activates the NixOS configuration for the current host. Uses `nh` (nix helper) for better output and notifications.

### upgrade - Update and rebuild

```bash
just upgrade
```

Updates flake inputs, builds, and switches to the new configuration. Equivalent to:
```bash
nix flake update
just build
just switch
```

### build - Build current host

```bash
just build
```

Builds the current host configuration without activating it. Useful for testing changes.

### check - Validate configuration

```bash
just check
```

Checks if the current host configuration can be built successfully without actually building it.

### check-all - Validate all hosts

```bash
just check-all
```

Checks if all hosts defined in `flake.nix` can be built. Shows summary of successes and failures.

---

## Maintenance (maintenance group)

### cleanup - Free up disk space

```bash
just cleanup
```

Performs system cleanup:
- Clears journal logs older than 3 days
- Prunes Docker system
- Empties trash
- Runs nix garbage collection
- Optimizes nix store

**Note:** Asks for confirmation before running.

### list-generations - Show system generations

```bash
just list-generations
```

Lists all system generations (rollback points).

### rollback - Rollback to previous generation

```bash
just rollback
```

Rolls back to the previous NixOS generation.

---

## Agenix Secrets Management

### rekey - Rekey all secrets

```bash
just rekey
```

Re-encrypts all secrets in `secrets/` directory with current keys from `secrets/secrets.nix`. Useful after adding new machines or rotating keys.

### keyscan - Get SSH host keys

```bash
just keyscan
```

Scans localhost for SSH host keys. Useful when setting up a new machine to extract its public key for `secrets/secrets.nix`.

---

## Documentation (docs group)

### hokage-options-md - Generate module documentation

```bash
just hokage-options-md
```

Generates Markdown documentation for all hokage module options and displays it.

### hokage-options-md-save - Save module documentation

```bash
just hokage-options-md-save [path]
```

Generates and saves hokage module documentation to a file.

**Default path:** `docs/hokage-options.md`

---

## Logs (log group)

### logs-current-boot - View current boot logs

```bash
just logs-current-boot
```

Shows all logs from the current boot session.

### logs-previous-boot - View previous boot logs

```bash
just logs-previous-boot
```

Shows logs from the previous boot session (useful after crashes).

### logs-follow - Live log tail

```bash
just logs-follow
```

Follows system logs in real-time.

---

## Common Workflows

### Daily Development

```bash
# Make changes to configuration
nano hosts/miniserver99/configuration.nix

# Test the build
just check

# Apply changes
just switch
```

### Updating Static Leases

```bash
# Edit leases
nano hosts/miniserver99/static-leases.nix

# Deploy to server
just switch

# Backup encrypted version to Git
just encrypt-leases
git commit -m "backup: update static leases"
git push
```

### After Cloning Repo on New Machine

```bash
# Decrypt your sensitive files
just decrypt-leases

# Or decrypt any encrypted file
just decrypt-file secrets/api-keys-home01.age

# Build and deploy
just switch
```

### System Updates

```bash
# Update flake inputs and rebuild
just upgrade

# If issues occur, rollback
just rollback
```

### Cleanup After Updates

```bash
# Free up disk space
just cleanup
```

---

## Tips & Tricks

### Command Chaining

```bash
# Update, build, switch, and push to cache
just upgrade push

# Switch and push to cache
just switch-push
```

### Build on Remote Host

For expensive builds, use a more powerful machine:

```bash
# Build on home01 server
just build-on-home01

# Build on caliban workstation
just build-on-caliban
```

### Check Specific Host

```bash
# Check if another host's config is valid
just check-host miniserver24
```

---

## Troubleshooting

### Command Not Found

If `just` command is not found:
```bash
# Install via Nix (NixOS/Linux)
nix-shell -p just

# Or on macOS via Homebrew
brew install just
```

### rage/age Not Found

If encryption fails:
```bash
# Install via Nix (NixOS/Linux)
nix-shell -p rage

# Or on macOS via Homebrew
brew install rage
```

### No SSH Key Found

If encryption complains about missing SSH key:
```bash
# Generate a new SSH key
ssh-keygen -t ed25519 -C "your@email.com"

# Backup to 1Password for safety
```

---

## Advanced Usage

### Custom Build Arguments

```bash
# Limit download parallelism
just switch --max-jobs 1

# Build with extra verbosity
just build -v
```

### Environment Variables

```bash
# Use specific SSH key for agenix operations (rarely needed)
AGENIX_USER_KEY=~/.ssh/id_ed25519_work.pub just encrypt-file hosts/home01/config.env
```

---

## Related Documentation

- **NixOS Manual**: https://nixos.org/manual/nixos/stable/
- **Just Manual**: https://just.systems/man/en/
- **agenix**: https://github.com/ryantm/agenix
- **rage**: https://github.com/str4d/rage

---

## Contributing

When adding new justfile commands:
1. Add them to the appropriate group: `[group('groupname')]`
2. Add helpful comments above the command
3. Document them in this file
4. Test on both NixOS and macOS if applicable

