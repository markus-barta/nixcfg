# +agents

IDE/LLM-agnostic agent configuration. Single source of truth for all AI coding tools.

## Structure

```
+agents/
├── commands/           # Slash commands (IDE-agnostic)
│   ├── ops.md          # /ops — load AGENTS rules + SYSOP role
│   └── git.md          # /git — stage, commit, push
└── rules/              # Agent rules & roles
    ├── AGENTS.md       # Universal agent instructions (canonical)
    └── SYSOP.md        # Infrastructure ops role
```

## Symlinks

All symlinks point to `+agents/` as the single source of truth.

| Symlink                           | Target                    | Tool(s)                 |
| --------------------------------- | ------------------------- | ----------------------- |
| `AGENTS.md`                       | `+agents/rules/AGENTS.md` | OpenCode, Cursor, Zed   |
| `CLAUDE.md`                       | `+agents/rules/AGENTS.md` | Claude Code             |
| `.rules`                          | `+agents/rules/AGENTS.md` | Zed (primary lookup)    |
| `.github/copilot-instructions.md` | `+agents/rules/AGENTS.md` | GitHub Copilot          |
| `SYSOP.md`                        | `+agents/rules/SYSOP.md`  | Discoverability         |
| `.opencode/commands`              | `+agents/commands`        | OpenCode slash commands |

## Adding a new tool

1. Find what file/path the tool auto-detects
2. Create a symlink at that location → `+agents/rules/AGENTS.md`
3. Add it to the table above

## Editing rules

Edit the canonical files in `+agents/rules/` directly. All symlinks follow automatically.
Never edit the symlink targets — they're just pointers.
