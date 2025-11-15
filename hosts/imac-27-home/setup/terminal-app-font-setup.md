# Terminal.app Font Configuration

## One-Time Manual Setup

Terminal.app requires manual font configuration on each machine (cannot be done declaratively via Nix).

### Steps

1. Open **Terminal.app**
2. Press **Cmd+,** (Preferences)
3. Go to **Profiles → Text tab**
4. Click **"Change"** button next to font
5. Search for **"Hack Nerd"**
6. Select **"Hack Nerd Font Mono"**
7. Close preferences

### Verification

Test that Nerd Font icons render correctly:

```bash
printf 'Nerd Font icons: \uE0A0 \uE718 \uE73C \uF07B \uF00C\n'
```

You should see: Git branch , Node.js , Python , Folder , Check ✓

### Why Manual?

Terminal.app stores font settings in a binary plist format (`~/Library/Preferences/com.apple.Terminal.plist`) that cannot be reliably manipulated programmatically. This is a macOS limitation.

**Note**: Your WezTerm is fully configured via Nix and doesn't require any manual setup.
