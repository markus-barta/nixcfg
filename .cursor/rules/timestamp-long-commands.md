# Timestamp Long-Running Commands

## 🕐 CRITICAL RULE: Always Show Timestamp Before Long Operations

**ALWAYS** output a timestamp before running commands that are expected to take significant time.

### ⏱️ Commands That Require Timestamps

**NixOS Operations**:

- `nixos-rebuild` (build, switch, test, boot)
- `nix build` (any derivation building)
- `nix-build` (legacy builds)
- `nix flake check`
- `nix flake update`
- `nixos-install`

**File System Operations**:

- `find` (searching large directory trees)
- `du` (disk usage calculations)
- `rsync` (file synchronization)
- `tar` (creating/extracting archives)
- `cp -r` (recursive copies of large directories)

**Development Operations**:

- Package installations (`npm install`, `cargo build`, etc.)
- Test suites (any test command expected to take >10 seconds)
- Docker builds
- Database operations (migrations, backups, restores)

**System Operations**:

- `apt update && apt upgrade` (system updates)
- `zfs` operations (snapshots, sends, receives)
- Network operations (large downloads, uploads)

## 📋 How to Implement

Always prefix long-running commands with a timestamp command:

```bash
date && <long-running-command>
```

### ✅ GOOD Examples:

```bash
# Before NixOS rebuild
date && sudo nixos-rebuild switch --flake .#miniserver99
```

```bash
# Before find operation
date && find /nix/store -name "*.drv"
```

```bash
# Before building
date && nix build .#packages.x86_64-linux.qownnotes
```

```bash
# Before test
date && sudo nixos-rebuild test --flake .#hsb8
```

### ❌ BAD Examples:

```bash
# Missing timestamp - user won't know when it started
sudo nixos-rebuild switch --flake .#miniserver99
```

```bash
# Missing timestamp - find can take a long time
find /nix/store -name "*.drv"
```

## 🎯 Why This Matters

1. **Tracking**: User can see in chat history when operation started
2. **Debugging**: Helps correlate timing with other events
3. **Planning**: User can estimate how long similar operations take
4. **Transparency**: Clear indication of when long waits began

## 💡 Shell-Specific Considerations

**Fish Shell** (user's default shell):

```fish
date; and sudo nixos-rebuild switch --flake .#miniserver99
```

**Bash/Zsh**:

```bash
date && sudo nixos-rebuild switch --flake .#miniserver99
```

## 🔔 AI Assistant Responsibility

Before suggesting or running any long-running command:

1. **Assess Duration**: Will this likely take >10 seconds?
2. **Add Timestamp**: Prefix with `date &&` (or `date; and` for fish)
3. **Explain**: Briefly mention "This may take a while" if appropriate
4. **Combine**: Use single command line so timestamp and command appear together

### Special Cases

**Multiple Commands**: If running several long operations in sequence, add timestamp before each:

```bash
date && nix build .#package1 && date && nix build .#package2
```

**Background Jobs**: Add timestamp before starting background operation:

```bash
date && nix build .#large-package &
```

**Remote Commands**: Include timestamp in SSH command:

```bash
ssh server "date && sudo nixos-rebuild switch"
```

## ⏰ Timestamp Format

The default `date` command output is sufficient and provides:

- Day of week
- Date
- Time (including seconds)
- Timezone

Example output: `Fri Nov 21 14:23:45 CET 2025`

## 🎯 Remember

> **When in doubt, add a timestamp!**
>
> It's better to have an unnecessary timestamp than to wonder when a long operation started.

If a command might take more than 10 seconds, prefix it with `date &&`.
