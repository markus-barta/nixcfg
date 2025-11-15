# Homebrew Cleanup Analysis

## Formulae (CLI Packages) - 193 total

### ✅ Safe to Remove (Already in Nix or Duplicates)

- `cloc` - Already in your devenv.nix
- `font-hack-nerd-font` (cask) - Already installed via Nix
- `pyenv` - Not needed, using Nix python
- `python@3.9`, `python@3.10`, `python@3.12`, `python@3.14` - Old Python versions, using Nix
- `htop` - Have btop from Nix (better)
- `nano` - macOS has built-in, or use vim/nvim
- `ncurses` - System dependency, likely not needed directly
- `zsh-syntax-highlighting` - Using Fish shell from Nix
- `defaultbrowser`, `defbro` - Duplicates (one should be enough)

### 🤔 Review Needed (Might be Used)

- `git` - Homebrew version, but macOS has built-in
- `gh` (GitHub CLI) - Do you use this?
- `lazygit` - Already in your devenv.nix
- `just` - Already in your devenv.nix for nixcfg
- `tmux`, `zellij` - Terminal multiplexers (choose one?)
- `wget`, `rsync` - macOS has these built-in
- `tree` - Simple utility, could migrate to Nix
- `tldr` - Useful, could migrate to Nix
- `jq` - JSON processor, could migrate to Nix
- `go-jira`, `magic-wormhole` - Specialized tools, do you use?

### ⚠️ Keep (Likely in Use)

- `evcc` - Electric vehicle charging control
- `mosquitto` - MQTT broker (if you use IoT/home automation)
- `ffmpeg` - Video processing (complex dependencies)
- `imagemagick`, `ghostscript` - Image/PDF processing
- `openjdk`, `temurin` (cask) - Java (for development)
- `lua`, `luarocks` - For Hammerspoon/WezTerm config
- `restic`, `rage` - Backup/encryption tools

### 📦 GUI Apps (Casks) - Likely Keep

- `cursor`, `qownnotes`, `hammerspoon` - Active apps
- `wezterm` - Keep for now (have Nix version too)
- `mactex-no-gui` - LaTeX (large but specialized)

## Recommended Actions

### Phase 1: Remove Obvious Duplicates (Safe)

```bash
brew uninstall cloc htop nano pyenv python@3.9 python@3.10 python@3.12 python@3.14 \
  zsh-syntax-highlighting defaultbrowser
brew uninstall --cask font-hack-nerd-font
```

### Phase 2: Remove Underused Tools (After Confirming)

```bash
# If you don't use these:
brew uninstall go-jira magic-wormhole defbro
```

### Phase 3: Migrate to Nix (Optional)

Add to home.nix if you use them:

- jq, tree, tldr, lazygit, just (already in devenv)

### Phase 4: Clean Dependencies

```bash
brew autoremove
brew cleanup --prune=all
```
