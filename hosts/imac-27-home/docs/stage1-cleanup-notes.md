# Stage 1: Homebrew Cleanup - Notes

**Date**: 2025-11-14  
**Status**: Partially Complete

## Successfully Removed ✅

- `fish` (4.1.2) - 22.7MB freed
- `bat` (0.26.0) - 5.3MB freed
- `btop` (1.4.5) - 1.4MB freed
- `ripgrep` (15.1.0) - 6.5MB freed
- `fd` (10.3.0) - 3.3MB freed
- `zoxide` (0.9.8) - 1.1MB freed
- `direnv` (2.37.1) - 12.4MB freed
- `starship` (1.23.0) - 9.7MB freed

**Total: 8 packages, ~62MB freed**

## Auto-removed Dependencies ✅

- `libgit2` (1.9.1) - 5MB freed
- `bash` (5.3.3) - 11.7MB freed

## Blocked by Dependencies ⚠️

### `node` (25.2.0)

Required by: `prettier`

**Options:**

1. Keep Homebrew node (unlinked, not in use)
2. Force remove: `brew uninstall --ignore-dependencies node`
3. Migrate `prettier` to Nix (already in devenv.nix for nixcfg)

### `python@3.13` (3.13.9)

Required by: `esptool`, `evernote-backup`, `nmap`

**Options:**

1. Keep Homebrew python (unlinked, not in use)
2. Force remove: `brew uninstall --ignore-dependencies python@3.13`
3. Check if these tools need updating or migration

## Configuration Leftovers ℹ️

Manual cleanup needed (optional):

- `/usr/local/etc/fish/` - old fish config
- `/usr/local/etc/bash_completion.d/` - bash completion

## Verification ✅

All Nix versions working correctly:

```bash
$ which fish node python3 bat btop rg fd zoxide direnv starship
/Users/markus/.nix-profile/bin/fish
/Users/markus/.nix-profile/bin/node
/Users/markus/.nix-profile/bin/python3
/Users/markus/.nix-profile/bin/bat
/Users/markus/.nix-profile/bin/btop
/Users/markus/.nix-profile/bin/rg
/Users/markus/.nix-profile/bin/fd
/Users/markus/.nix-profile/bin/zoxide
/Users/markus/.nix-profile/bin/direnv
/Users/markus/.nix-profile/bin/starship
```

**All tools from Nix!** 🎉

## Next Steps

1. ✅ Added missing CLI tools to `home.nix` (bat, btop, ripgrep, fd, fzf)
2. ⏭️ Decide: Keep or force-remove node/python from Homebrew
3. ⏭️ Optional: Clean Homebrew cache (`brew cleanup --prune=all`)
4. ⏭️ Stage 2: Development tools cleanup
