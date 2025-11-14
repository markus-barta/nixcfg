# 🔄 Switch to Nix Versions - Action Items

**Status**: Nix packages installed ✅ | Awaiting manual setup to switch default shell

## Quick Setup (5 minutes)

### Step 1: Run the setup script

Open your **actual terminal** (not through Cursor) and run:

```bash
cd ~/Code/nixcfg/hosts/imac-27-home
./setup/setup-macos.sh
# Enter your password when prompted
```

This will:

- Add Nix fish to `/etc/shells` (requires sudo)
- Change your default shell to `~/.nix-profile/bin/fish`

### Step 2: Restart your terminal

Close and reopen your terminal app, or run:

```bash
exec fish
```

### Step 3: Verify the switch

After restarting, verify you're using Nix versions:

```bash
# Check shell
echo $SHELL
# Should show: /Users/markus/.nix-profile/bin/fish

# Check tool paths
which fish && fish --version
which node && node --version
which python3 && python3 --version
which starship && starship --version
which git && git --version

# All "which" commands should now show paths starting with:
# /Users/markus/.nix-profile/bin/ or /nix/store/
```

### Step 4: Test critical workflows

After switching, test your critical workflows:

```fish
# SSH shortcuts
ssh qc99    # Should still work (stored in ~/.ssh/config)
ssh qc24
ssh qc0
ssh qc1

# Custom scripts
flushdns.sh       # DNS flush
pingt google.com  # Timestamped ping
stopAmphetamineAndSleep.sh  # Sleep script

# Fish functions and abbreviations
l                 # Should expand to 'la -lah'
gs                # Should expand to 'git status'
```

## What's Next?

After verifying everything works with Nix versions:

1. ✅ **Continue using your system** - Everything should work the same
2. 📝 **Document any issues** - If something doesn't work, note it
3. 🧹 **Gradual Homebrew cleanup** - See `docs/testing-and-cleanup.md` for the staged removal plan

## Rollback (if needed)

If something doesn't work, you can quickly switch back:

```bash
# Change shell back to Homebrew fish
chsh -s /usr/local/bin/fish

# Restart terminal
exec /usr/local/bin/fish
```

Homebrew versions are still installed, so nothing is lost!

---

**Current versions available:**

| Tool     | Nix (ready to use) | Homebrew (current) |
| -------- | ------------------ | ------------------ |
| fish     | 4.1.2              | 4.1.2              |
| node     | v22.20.0 (LTS)     | v25.2.0            |
| python3  | 3.13.8             | 3.10.3 (pyenv)     |
| starship | 1.23.0             | 1.23.0             |
| git      | 2.51.1             | 2.51.1             |

All configs are already managed by Nix home-manager! 🎉
