---
description: "Show OpenClaw model cheat-sheet with tiers, aliases, keywords and task guidance"
---

Read and follow @+agents/rules/AGENTS.md

# Model Help — Cheat Sheet

Reference the current modelhelp skill for the full model list and decision guide:

@/Users/markus/Code/oc-workspace-merlin/skills/modelhelp/SKILL.md

## Output format

Render a compact version of the model table grouped by tier. Add a one-line tip at the end
pointing to the Decision Guide for task-based selection.

If `$ARGUMENTS` is provided, treat it as a task description and recommend 1–2 specific models
with a short reason (alias + why). Example: `/modelhelp summarize a 200-page PDF`.
