# Agent Workflow

How agents (AI or human) should work with this infrastructure codebase.

---

## The Prime Directive

> **Keep config, docs, and tests in sync. Every change to one should prompt review of the others.**

---

## Task Management

### When to Create a PPM Issue

Use PPM via the `paimos` CLI. Search first to avoid duplicates; create an issue if the work needs tracking or might get interrupted.

**Rule of thumb**: If you need to track progress or might get interrupted, create a PPM issue.

### Task Workflow

```bash
# List recent issues in the NIX project
paimos --json issue list --project NIX --limit 20

# Create new task/ticket
paimos issue create --project NIX --type task --priority medium \
  --title "<title>" --description-file /tmp/desc.md

# Start work
paimos issue ensure-status NIX-123 in-progress

# Complete task
paimos issue update NIX-123 --status done --close-note-file /tmp/close.md

# Cancel task
paimos issue update NIX-123 --status cancelled --close-note-file /tmp/close.md
```

Run `paimos doctor` first if the CLI is not configured on this machine.

---

## The Sync Triad

Every host has three components that must stay synchronized:

```text
┌────────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│ Configuration      │ ←→  │ Documentation   │ ←→  │ Tests           │
│                    │     │                 │     │                 │
│ configuration.nix  │     │ README.md       │     │ tests/T*.sh     │
│ home.nix           │     │ docs/RUNBOOK.md │     │ tests/T*.md     │
└────────────────────┘     └─────────────────┘     └─────────────────┘
```

### When Config Changes → Update Docs

| Config Change     | Doc to Update              | Section                        |
| ----------------- | -------------------------- | ------------------------------ |
| New service added | README.md                  | Features table                 |
| New service added | RUNBOOK.md                 | Service section, health checks |
| Port changed      | README.md                  | Quick Reference                |
| Port changed      | RUNBOOK.md                 | Health checks, commands        |
| IP changed        | ip-\*.md                   | Rename file                    |
| IP changed        | README.md, RUNBOOK.md      | All IP references              |
| New secret        | secrets/runbook-secrets.md | Add credential entry           |
| New user          | README.md                  | Users table                    |
| New user          | RUNBOOK.md                 | Access section                 |

### When Config Changes → Update Tests

| Config Change   | Test Action                                      |
| --------------- | ------------------------------------------------ |
| New service     | Create `T##-<service>.sh` and `T##-<service>.md` |
| Service removed | Archive or delete corresponding test             |
| Port changed    | Update port in existing test                     |
| New feature     | Add test case to relevant `T##-*.sh`             |
| Behavior change | Update expected values in tests                  |

### Where Tests Live

| Test Type          | Location                  | Purpose                               |
| ------------------ | ------------------------- | ------------------------------------- |
| Host-specific      | `hosts/<hostname>/tests/` | Ongoing functionality (DNS, services) |
| General/structural | `tests/`                  | Repository structure, cross-cutting   |
| Task-specific      | PPM issue AC / comments   | One-time verification                 |

---

## Pre-Change Checklist

Before modifying any host configuration:

```text
□ Identify affected host(s)
□ Check host criticality in INFRASTRUCTURE.md
□ Check dependencies (will this affect other hosts?)
□ Review current RUNBOOK.md for the host
□ For bigger tasks: Search/create PPM issue
□ Identify which docs/tests need updating
□ For NixOS: Confirm build platform (gpc0 or hsb1, NOT macOS)
```

---

## Post-Change Checklist

After modifying any host configuration:

```text
□ Config builds successfully
□ README.md updated (if features/ports/IPs changed)
□ RUNBOOK.md updated (if procedures changed)
□ Tests updated or created (for new features)
□ secrets/runbook-secrets.md updated (if new credentials)
□ runbook-secrets.age re-encrypted (if secrets changed)
□ Git commit with descriptive message
□ Update PPM issue status / close note (if applicable)
```

---

## Quick Reference Commands

```bash
# Deploy to NixOS host (from that host)
just switch

# Deploy remotely to NixOS host
nixos-rebuild switch --flake .#<host> --target-host <host> --use-remote-sudo

# Deploy to macOS (home-manager)
home-manager switch --flake ".#markus@<host>"

# Check all configs build (from NixOS host)
nix flake check

# Encrypt runbook secrets
just encrypt-runbook-secrets <hostname>

# Decrypt runbook secrets
just decrypt-runbook-secrets <hostname>
```

---

## Fleet Management (Decommissioned)

NixFleet has been decommissioned (DSC26-53). Its successor **FleetCom** (DSC26-52) is in development.

### Manual Deployment

```bash
# NixOS
ssh <host> "cd ~/Code/nixcfg && git pull && sudo nixos-rebuild switch --flake .#<host>"

# macOS
ssh <host> "cd ~/Code/nixcfg && git pull && home-manager switch --flake '.#markus@<host>'"
```

### Quick Reference

| Host Type | Deployment Method | SYSOP Responsibility       |
| --------- | ----------------- | -------------------------- |
| NixOS     | SSH + rebuild     | Edit + push + SSH + switch |
| macOS     | SSH + HM switch   | Edit + push + SSH + switch |

For architecture details, see [INFRASTRUCTURE.md](./INFRASTRUCTURE.md#-fleet-management).

---

## Lockfile Merge Conflicts

`devenv.lock` and `flake.lock` are **generated files committed to git**.
Whenever multiple clones regenerate them in parallel (dev boxes, hosts
running `direnv`/`devenv`, CI, agents), `git pull`/`git rebase` produces
textual conflicts that can't be merged line-by-line — the JSON layout
shifts wholesale.

### The fix (already in-repo)

`.gitattributes` marks both files as `merge=ours`, so git's merge driver
keeps the current side and leaves the tree clean. This is safe because:

- Lockfiles are deterministic outputs of `nix` / `devenv` — never hand-edited.
- If the kept side is stale, the next `nix flake check` / `devenv` run
  regenerates it.

### One-time setup per clone

The `merge=ours` attribute references a **local git driver** that is not
enabled automatically — each clone must register it once:

```bash
just setup-git-drivers
# equivalent to:  git config --local merge.ours.driver true
```

Verify:

```bash
git config --local --get merge.ours.driver   # expect: true
```

### When it matters most

- **Servers running `direnv`** (e.g. hsb1): `cd ~/Code/nixcfg` silently
  regenerates `devenv.lock`, then your next `git pull` conflicts.
- **Parallel agent sessions** pushing from different machines.
- **CI pipelines** that bump lockfiles (update_flake_lock_action).

### If you see a conflict anyway

The driver is not registered on that clone. Either:

```bash
# nuke the conflict state and re-pull
git checkout HEAD -- devenv.lock flake.lock
git pull
just setup-git-drivers   # so it doesn't happen next time
```

---

## References

- **Host structure requirements**: [HOST-TEMPLATE.md](./HOST-TEMPLATE.md)
- **Infrastructure inventory**: [INFRASTRUCTURE.md](./INFRASTRUCTURE.md)
- **PM workflow**: PPM via `paimos` CLI (`pm.barta.cm`, project `NIX`)
- **Test guidelines**: [tests/README.md](../tests/README.md)
