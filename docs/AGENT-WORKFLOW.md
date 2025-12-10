# Agent Workflow

How agents (AI or human) should work with this infrastructure codebase.

---

## The Prime Directive

> **Keep config, docs, and tests in sync. Every change to one should prompt review of the others.**

---

## Task Management

### When to Create a .pm Task

See [.pm/README.md](../.pm/README.md#when-to-create-a-task) for the decision table.

**Rule of thumb**: If you need to track progress or might get interrupted, create a task.

### Task Workflow

```bash
# Create new task
touch .pm/backlog/$(date +%Y-%m-%d)-short-description.md

# Complete task
mv .pm/backlog/YYYY-MM-DD-task.md .pm/done/

# Cancel task
mv .pm/backlog/YYYY-MM-DD-task.md .pm/cancelled/
```

For task template and full workflow details, see [.pm/README.md](../.pm/README.md).

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

| Test Type          | Location                   | Purpose                               |
| ------------------ | -------------------------- | ------------------------------------- |
| Host-specific      | `hosts/<hostname>/tests/`  | Ongoing functionality (DNS, services) |
| General/structural | `tests/`                   | Repository structure, cross-cutting   |
| Task-specific      | Inline in `.pm/` task file | One-time verification                 |

---

## Pre-Change Checklist

Before modifying any host configuration:

```text
□ Identify affected host(s)
□ Check host criticality in INFRASTRUCTURE.md
□ Check dependencies (will this affect other hosts?)
□ Review current RUNBOOK.md for the host
□ For bigger tasks: Create .pm/backlog/ item
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
□ Move .pm task to done/ (if applicable)
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

## Thymis Integration (Planned)

Once [Thymis](https://thymis.barta.cm) is deployed, deployment workflows differ by host type:

### NixOS Hosts → Thymis

Thymis handles deployment for: hsb0, hsb1, hsb8, gpc0, csb0, csb1

```text
SYSOP edits config → Push to GitHub → Thymis pulls → Human approves → Deploy
```

**SYSOP role**: Edit configs, push to Git. Thymis handles the rest (after human approval).

### macOS Hosts → Manual via SYSOP

macOS hosts (imac0, mba-imac-work, mba-mbp-work) are **not managed by Thymis**.

```bash
# SYSOP deploys to macOS manually
ssh <host> "cd ~/Code/nixcfg && git pull && home-manager switch --flake '.#markus@<host>'"
```

**SYSOP role**: Full deployment responsibility — pull, switch, verify.

### Quick Reference

| Host Type | Deployment Method | SYSOP Responsibility         |
| --------- | ----------------- | ---------------------------- |
| NixOS     | Thymis            | Edit + push (Thymis deploys) |
| macOS     | Manual            | Edit + push + deploy         |

For architecture details, see [INFRASTRUCTURE.md](./INFRASTRUCTURE.md#thymis-fleet-management-planned).

---

## References

- **Host structure requirements**: [HOST-TEMPLATE.md](./HOST-TEMPLATE.md)
- **Infrastructure inventory**: [INFRASTRUCTURE.md](./INFRASTRUCTURE.md)
- **PM workflow**: [.pm/README.md](../.pm/README.md)
- **Test guidelines**: [tests/README.md](../tests/README.md)
