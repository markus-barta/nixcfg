#!/bin/bash
# Pre-migration backup script for imac-mba-home
# Creates timestamped backup of all configuration files and system state
# Run this BEFORE starting Phase 1 of the migration

set -e # Exit on error

# Configuration
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$HOME/migration-backup-$TIMESTAMP"

echo "🔒 Creating migration backup..."
echo "Destination: $BACKUP_DIR"
echo ""

# Create backup directory
mkdir -p "$BACKUP_DIR"

# 1. Fish configuration
echo "📁 Backing up Fish configuration..."
if [ -d "$HOME/.config/fish" ]; then
  mkdir -p "$BACKUP_DIR/fish"
  cp -r "$HOME/.config/fish/"* "$BACKUP_DIR/fish/" 2>/dev/null || true
  echo "✅ Fish config backed up"
else
  echo "⚠️  No Fish config found"
fi

# 2. Starship configuration
echo "📁 Backing up Starship configuration..."
if [ -f "$HOME/.config/starship.toml" ]; then
  mkdir -p "$BACKUP_DIR/starship"
  cp "$HOME/.config/starship.toml" "$BACKUP_DIR/starship/"
  echo "✅ Starship config backed up"
else
  echo "⚠️  No Starship config found"
fi

# 3. WezTerm configuration
echo "📁 Backing up WezTerm configuration..."
if [ -f "$HOME/.wezterm.lua" ]; then
  cp "$HOME/.wezterm.lua" "$BACKUP_DIR/"
  echo "✅ WezTerm config backed up"
else
  echo "⚠️  No WezTerm config found"
fi

# 4. Git configuration
echo "📁 Backing up Git configuration..."
if [ -f "$HOME/.gitconfig" ]; then
  cp "$HOME/.gitconfig" "$BACKUP_DIR/"
  echo "✅ Git config backed up"
fi
if [ -f "$HOME/.gitignore_global" ]; then
  cp "$HOME/.gitignore_global" "$BACKUP_DIR/"
  echo "✅ Global gitignore backed up"
fi

# 5. Scripts directory
echo "📁 Backing up Scripts directory..."
if [ -d "$HOME/Scripts" ]; then
  mkdir -p "$BACKUP_DIR/Scripts"
  cp -r "$HOME/Scripts/"* "$BACKUP_DIR/Scripts/" 2>/dev/null || true
  SCRIPT_COUNT=$(find "$HOME/Scripts" -type f | wc -l | xargs)
  echo "✅ Scripts backed up ($SCRIPT_COUNT files)"
else
  echo "⚠️  No Scripts directory found"
fi

# 6. System state
echo "📁 Capturing system state..."
mkdir -p "$BACKUP_DIR/system-state"

# Homebrew packages
if command -v brew &>/dev/null; then
  brew list --formula >"$BACKUP_DIR/system-state/brew-formulae.txt"
  brew list --cask >"$BACKUP_DIR/system-state/brew-casks.txt"
  brew list --versions >"$BACKUP_DIR/system-state/brew-versions.txt"
  echo "✅ Homebrew package lists saved"
fi

# Current shell and PATH
echo "$SHELL" >"$BACKUP_DIR/system-state/current-shell.txt"
echo "$PATH" >"$BACKUP_DIR/system-state/current-path.txt"
cat /etc/shells >"$BACKUP_DIR/system-state/etc-shells.txt"

# Tool versions
{
  echo "=== System Versions ==="
  echo "Date: $(date)"
  echo "macOS: $(sw_vers -productVersion)"
  echo ""
  echo "=== Tool Versions ==="
  command -v fish &>/dev/null && echo "fish: $(fish --version)" || echo "fish: not found"
  command -v starship &>/dev/null && echo "starship: $(starship --version)" || echo "starship: not found"
  command -v git &>/dev/null && echo "git: $(git --version)" || echo "git: not found"
  command -v node &>/dev/null && echo "node: $(node --version)" || echo "node: not found"
  command -v python3 &>/dev/null && echo "python3: $(python3 --version)" || echo "python3: not found"
} >"$BACKUP_DIR/system-state/tool-versions.txt"

echo "✅ System state captured"

# 7. Create checksums for verification
echo ""
echo "🔐 Creating checksums..."
if command -v shasum &>/dev/null; then
  # Create checksums for all files except CHECKSUMS.txt itself
  find "$BACKUP_DIR" -type f ! -name "CHECKSUMS.txt" -exec shasum -a 256 {} \; >"$BACKUP_DIR/CHECKSUMS.txt"
  echo "✅ Checksums created"
fi

# 8. Create restore instructions
cat >"$BACKUP_DIR/RESTORE.md" <<'EOF'
# Backup Restore Instructions

This backup was created before the Nix/home-manager migration.

## Full Restore (Emergency Rollback)

```bash
# Restore Fish configuration
cp -r fish/* ~/.config/fish/

# Restore Starship configuration
cp starship/starship.toml ~/.config/

# Restore WezTerm configuration
cp .wezterm.lua ~/

# Restore Git configuration
cp .gitconfig ~/
[ -f .gitignore_global ] && cp .gitignore_global ~/

# Restore Scripts directory
cp -r Scripts/* ~/Scripts/

# Verify shell
echo "Current shell: $SHELL"
echo "Available shells:"
cat system-state/etc-shells.txt

# If needed, restore Homebrew packages
# brew install $(cat system-state/brew-formulae.txt)
```

## Selective Restore

Restore individual files as needed from this backup directory.

## Verification

```bash
# Verify checksums
shasum -a 256 -c CHECKSUMS.txt
```

## Important Notes

- Keep this backup until migration is fully verified (minimum 2 weeks)
- Test restored configurations before removing backup
- Some tools may require reinstallation (Homebrew packages)
EOF

# 9. Final summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 Backup complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Backup location: $BACKUP_DIR"
echo ""
echo "Contents:"
# shellcheck disable=SC2012 # Using ls for human-readable output
ls -lh "$BACKUP_DIR" | tail -n +2 | awk '{printf "  %-20s %s\n", $9, $5}'
echo ""
echo "Backup size: $(du -sh "$BACKUP_DIR" | awk '{print $1}')"
echo ""
echo "📋 Restore instructions: $BACKUP_DIR/RESTORE.md"
echo "🔐 Checksums: $BACKUP_DIR/CHECKSUMS.txt"
echo ""
echo "⚠️  Keep this backup until Phase 5 complete (minimum 2 weeks)"
echo ""
echo "✅ Ready to proceed with migration!"
echo ""

# Check Time Machine
if [ -d "/Volumes/Time Machine Backups" ] || tmutil latestbackup &>/dev/null; then
  LATEST_TM=$(tmutil latestbackup 2>/dev/null || echo "unknown")
  echo "💾 Time Machine last backup: $LATEST_TM"
  echo ""
fi
