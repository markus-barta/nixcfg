# +agents

IDE/LLM-agnostic agent configuration for nixcfg. Holds the slash-command definitions and the per-role operational reference docs (SYSOP, SYSOP-GB). The hard rules ("never cat secrets", "use trash not rm", etc.) live one layer up — see "Doctrine layering" below.

## Structure

```
+agents/
├── commands/                  # Slash commands (IDE-agnostic; load via `@filename` from harnesses)
│   ├── ops.md                 # /ops — load AGENTS rules + SYSOP role
│   ├── ocbots.md              # /ocbots — OpenClaw bots ops context
│   ├── modelhelp.md           # /modelhelp — OpenClaw model cheat-sheet
│   ├── oc-modelupdate.md      # /oc-modelupdate — research + update model lists
│   ├── push.md                # /push — single-repo commit+push helper
│   ├── pushall.md             # /pushall — multi-repo dispatch
│   └── …                      # add more here
└── rules/                     # Per-role operational reference docs (NOT the canonical rule source)
    ├── SYSOP.md               # Infrastructure ops role — decision tree, SSH matrix, HIL protocol
    └── SYSOP-GB.md            # Same role tuned for Gerhard's setup
```

> **The canonical file `AGENTS.md` lives at the repo root** (since 2026-05-14), not under `+agents/rules/`. The per-role docs in `+agents/rules/` are **operational reference only** — they document the role's decision-flow, SSH matrix, audit checklist, etc. The hard rules they used to carry have been promoted upstream (see Doctrine layering).

## Doctrine layering (post-INSPR-179, 2026-05-14)

Every agent reading nixcfg follows these layers, top-down:

1. **[inspr-modules/docs/AGENTS-CORE.md](https://github.com/markus-barta/inspr-modules/blob/main/docs/AGENTS-CORE.md)** — universal rules every agent follows (199 rules)
2. **[inspr-modules/docs/AGENTS-PROFILE-MARKUS.md](https://github.com/markus-barta/inspr-modules/blob/main/docs/AGENTS-PROFILE-MARKUS.md)** — Markus's personal preferences (153 rules)
3. **[inspr-modules/docs/AGENTS-AGENT-SYSOP.md](https://github.com/markus-barta/inspr-modules/blob/main/docs/AGENTS-AGENT-SYSOP.md)** (or `AGENTS-AGENT-SYSOP-GB.md`) — sysop-role rules
4. **[../AGENTS.md](../AGENTS.md)** (this repo's root) — nixcfg-specific delta (55 rules)
5. **`+agents/rules/SYSOP.md`** (or `SYSOP-GB.md`) — operational reference for the role: where am I, how to SSH, audit checklist. _Not a rule source._

If you're authoring a NEW rule: add it upstream in inspr-modules at the right layer. Don't add it to `+agents/rules/SYSOP.md` — that file holds only operational reference now.

## Symlinks

Tool-discovery wrappers — IDE/LLM tools auto-load these names:

| Symlink                           | Target                             | Tool(s)                                         |
| --------------------------------- | ---------------------------------- | ----------------------------------------------- |
| `AGENTS.md`                       | _(real file, no symlink)_          | OpenCode, Cursor, Zed                           |
| `CLAUDE.md`                       | `AGENTS.md`                        | Claude Code                                     |
| `.rules`                          | `AGENTS.md`                        | Zed (primary lookup)                            |
| `.github/copilot-instructions.md` | `../AGENTS.md`                     | GitHub Copilot                                  |
| `SYSOP.md` (root)                 | `+agents/rules/SYSOP.md`           | Discoverability (Markus's role)                 |
| `SYSOP-GB.md` (root)              | `+agents/rules/SYSOP-GB.md`        | Discoverability (Gerhard's role)                |
| `.opencode/commands`              | `+agents/commands`                 | OpenCode slash commands                         |
| `.claude/commands`                | `+agents/commands`                 | Claude Code slash-command discovery (INSPR-190) |
| `+agents/commands/inspr.md`       | `../../doctrine/commands/inspr.md` | `/inspr` meta-command (canonical upstream)      |

`AGENTS.md` was made a real file (no longer a symlink) on 2026-05-14 (INSPR-179 Phase 5.2) so the modern AGENTS.md tooling convention finds the canonical file at the standard repo-root location.

## Adding a new tool

1. Find what file/path the tool auto-detects.
2. Create a symlink at that location → `AGENTS.md` (the root file).
3. Add it to the table above.

## Editing rules

- **Hard rules** (security, git safety, style, etc.) — edit upstream in `inspr-modules/docs/`. Don't add new rules here.
- **nixcfg-specific deltas** (rules unique to this repo, e.g. NixOS build safety, runbook-secrets workflow) — edit `../AGENTS.md` (the root file).
- **Per-role operational reference** (decision tree, SSH matrix, audit checklist) — edit `+agents/rules/SYSOP.md` or `SYSOP-GB.md`.
- **Slash commands** — edit files under `commands/`.

When in doubt about whether something is a "rule" or "operational reference": rules are imperative and evaluable ("did the agent follow it?"); operational reference is flow/lookup material ("how do I…?", "where am I?"). New rules go upstream; new lookup material goes here.
