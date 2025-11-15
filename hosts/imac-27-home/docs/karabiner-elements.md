# Karabiner-Elements - Declarative Configuration with Nix

## The Solution

**Good news**: Karabiner-Elements uses JSON configuration files, which can be managed declaratively via home-manager!

**Bad news**: Karabiner-Elements itself is NOT in nixpkgs, so you need to keep it in Homebrew.

**The Elegant Hybrid Approach**:

- Install Karabiner-Elements via **Homebrew** (GUI app + system driver)
- Manage configuration **declaratively via Nix** (home-manager)

## Implementation

### 1. Keep Karabiner-Elements in Homebrew

```bash
# Keep installed via Homebrew
brew install --cask karabiner-elements
```

**Why Homebrew?**

- Karabiner-Elements requires kernel extensions/system permissions
- Not available in nixpkgs (macOS-specific, complex installation)
- GUI app management is better suited for Homebrew cask

### 2. Manage Configuration Declaratively via Nix

Add to your `home.nix`:

```nix
# Karabiner-Elements configuration (declarative!)
home.file.".config/karabiner/karabiner.json".text = builtins.toJSON {
  global = {
    check_for_updates_on_startup = true;
    show_in_menu_bar = true;
    show_profile_name_in_menu_bar = false;
  };

  profiles = [
    {
      name = "Default profile";
      selected = true;

      # Simple modifications (key remapping)
      simple_modifications = [
        # Example: Caps Lock to Escape
        # {
        #   from = { key_code = "caps_lock"; };
        #   to = [{ key_code = "escape"; }];
        # }
      ];

      # Complex modifications (advanced remapping)
      complex_modifications = {
        rules = [
          # Example: Caps Lock to Hyper (Ctrl+Option+Cmd+Shift)
          {
            description = "Caps Lock to Hyper (Ctrl+Option+Cmd)";
            manipulators = [
              {
                from = {
                  key_code = "caps_lock";
                  modifiers = { optional = [ "any" ]; };
                };
                to = [
                  {
                    key_code = "left_control";
                    modifiers = [ "left_option" "left_command" ];
                  }
                ];
                type = "basic";
              }
            ];
          }
        ];
      };

      # Virtual modifiers
      virtual_hid_keyboard = {
        country_code = 0;
        keyboard_type_v2 = "ansi";
      };
    }
  ];
};
```

### 3. Your Current Configuration

Let me extract your current Karabiner configuration and convert it to Nix format.

**Your existing configuration location**: `~/.config/karabiner/karabiner.json`

I can help you:

1. Read your current Karabiner config
2. Convert it to Nix format
3. Add it to your `home.nix`
4. Make it fully declarative

### Benefits

✅ **Configuration version-controlled** - All key mappings in git  
✅ **Reproducible** - Same keyboard setup on all machines  
✅ **Declarative** - Edit home.nix, run switch, done  
✅ **Safe** - Can rollback to previous configurations  
✅ **Documented** - Your key mappings are self-documenting in Nix

### The Hybrid Approach

**Karabiner-Elements App**: Homebrew (stays there)  
**Karabiner Configuration**: Nix/home-manager (declarative)

This is actually the **best** approach for macOS-specific system tools:

- System integration via Homebrew (stable, tested)
- Configuration management via Nix (declarative, version-controlled)

## Next Steps

Would you like me to:

1. Extract your current `karabiner.json`
2. Convert it to Nix format
3. Add it to your `home.nix`
4. Document your key mappings (especially the Caps Lock → Hyper setup)

This way you'll have declarative keyboard configuration while keeping the reliable Homebrew installation! 🎯
