# Starship Configuration - AI Agent Rules

## ⚠️ CRITICAL: Unicode Handling

The `starship.toml` file contains **Nerd Font Unicode glyphs** that are easily corrupted.

### ❌ NEVER DO

1. **Never use heredocs** (`cat << 'EOF'`) to write starship.toml
2. **Never use `echo`** to create or modify the file
3. **Never manually type** Nerd Font icons in code
4. **Never copy/paste** icon characters directly into tool calls

### ✅ ALWAYS DO

1. **Start with official preset:**

   ```bash
   starship preset tokyo-night -o ~/.config/starship.toml
   ```

2. **Use `sed` for simple value changes:**

   ```bash
   sed -i '' 's/truncation_length = 3/truncation_length = 0/' file.toml
   ```

3. **Use Python for Unicode-safe modifications:**

   ```python
   # Reading and writing preserves Unicode
   with open('starship.toml', 'r') as f:
       content = f.read()

   # Simple replacements are safe
   content = content.replace('$nodejs\\', '$nodejs\\\n$python\\')

   # Adding new symbols - use Unicode escapes
   new_config = '''
   [python]
   symbol = "\ue73c"
   '''
   content += new_config

   with open('starship.toml', 'w') as f:
       f.write(content)
   ```

4. **Test after EVERY change:**
   - Open new terminal tab
   - Check for parse errors
   - Verify icons render

### Icon Unicode References

| Icon | Unicode  | Description           |
| ---- | -------- | --------------------- |
|      | `\uf179` | Apple/macOS           |
|      | `\uf313` | NixOS                 |
|      | `\uf17c` | Linux                 |
|      | `\ue725` | Git branch            |
|      | `\ue73c` | Python                |
|      | `\ue718` | Node.js               |
|      | `\uf308` | Docker                |
|      | `\ue0b0` | Powerline arrow right |
|      | `\ue0b2` | Powerline arrow left  |
|      | `\ue0b4` | Powerline round right |

### Step-by-Step Safe Editing

1. Get official preset: `starship preset tokyo-night -o ~/.config/starship.toml`
2. Make ONE small change
3. Test in new terminal tab
4. If working, make next change
5. Repeat until done
6. Copy final working config to repo

### Debugging

If icons show as boxes/rectangles:

1. Check font: `wezterm ls-fonts --text ""`
2. Remove conflicting fonts: `rm ~/Library/Fonts/Hack-*.ttf` (keep HackNerdFont-\*)
3. Refresh font cache: `killall fontd`
4. Restart WezTerm completely (Cmd+Q)

If TOML parse errors:

1. Check for unclosed quotes
2. Check for invalid escape sequences
3. Validate: `starship config` (will show errors)
