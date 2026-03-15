---
description: "Research, validate and update OpenClaw model lists across all bots"
---

Read and follow @+agents/rules/AGENTS.md
Assume @+agents/rules/SYSOP.md role

# Task: `/oc-modelupdate`

You are updating the `agents.defaults.models` list in both OpenClaw configs.
Both configs must always be identical (in sync).

## Config files to update

- `@hosts/hsb0/docker/openclaw-gateway/openclaw.json`
- `@hosts/miniserver-bp/docker/openclaw-percaival/openclaw.json`

## Current OpenRouter model catalogue

!`curl -s https://openrouter.ai/api/v1/models | python3 -c "
import json, sys
data = json.load(sys.stdin)
rows = []
for m in data.get('data', []):
    mid = m.get('id', '')
    p = m.get('pricing', {})
    prompt = str(p.get('prompt', '?'))
    completion = str(p.get('completion', '?'))
    created = m.get('created', 0)
    ctx = m.get('context_length', 0)
    rows.append((created, mid, prompt, completion, ctx))
rows.sort(reverse=True)
print('id | prompt | completion | ctx | created')
print('---|---|---|---|---')
for created, mid, prompt, completion, ctx in rows[:80]:
    print(f'{mid} | {prompt} | {completion} | {ctx} | {created}')
"
`

## Step 1 — Research: find new/better models

Using the catalogue above AND your knowledge of the LLM landscape (as of today), identify:

1. **Newer versions** of models already in the list (e.g. sonnet 4.5 → 4.6, gpt-5.2 → 5.4)
2. **Brand-new capable models** released recently that are good choices for an AI assistant (Telegram bot use case: general assistant, home automation, calendar, work tasks)
3. **Free models** worth adding (prompt=0 AND completion=0)

Be selective — quality over quantity. Only suggest models that genuinely improve the roster.
If nothing new and worthwhile is found, say so honestly. Do NOT invent model IDs.

## Step 2 — Validate every model in the current list + suggestions

For EACH model (current AND suggested), validate against the live catalogue above:

- ✅ exists → keep; note if free (prompt=0 and completion=0)
- ❌ missing → remove
- 🆕 new suggestion → validate it exists, note pricing

## Step 3 — Build updated model list

Rules:

- Alias style: short, lowercase, no spaces (Percy-style). Examples: `sonnet46`, `kimi25`, `gem3flash`
- Free models: append `-free` to alias (e.g. `hunter-alpha-free`, `step35free`)
- Model IDs: use exact API ID from the catalogue (no guessing)
- Both configs must end up **identical**
- Keep fallbacks (`model.primary` + `model.fallbacks`) in mind — primary must be a paid model

## Step 4 — Present findings to user BEFORE making any changes

Present a clear summary:

- Models to REMOVE (with reason)
- Models to ADD (with reason, pricing)
- Models to UPDATE (old → new)
- Alias changes
- Final proposed model list (table: id | alias | free?)

Ask: "OK to apply these changes?"

## Step 5 — After user approval: apply + commit + push (nixcfg)

1. Edit both JSON configs (identical models section)
2. `git diff` to verify — no secrets, no unrelated changes
3. `git add` + `git commit` + `git push`

## Step 6 — Regenerate modelhelp skill in all 3 workspace repos

The `modelhelp` skill contains a static model table that must mirror the openclaw.json model
list exactly. After updating the configs, regenerate the SKILL.md in all three workspace repos.

**Skill file locations:**

- `~/Code/oc-workspace-merlin/skills/modelhelp/SKILL.md`
- `~/Code/oc-workspace-nimue/skills/modelhelp/SKILL.md`
- `~/Code/oc-workspace-percy/skills/modelhelp/SKILL.md`

**Tier assignment rules** (apply to new/changed models):

| Tier        | Criteria                            |
| ----------- | ----------------------------------- |
| 🆓 free     | prompt=0 AND completion=0           |
| 💸 cheap    | prompt < $0.50 / 1M tokens          |
| 💰 mid      | prompt $0.50–3 / 1M tokens          |
| 🏆 powerful | prompt > $3 / 1M tokens OR flagship |

**Keyword categories to assign** (pick all that apply per model):

- Use-case domains: `general`, `coding`, `dev`, `it`, `writing`, `research`, `science`, `finance`, `human-sciences`, `multilingual`, `chinese`, `current-events`, `creative`
- Capability terms: `fast`, `long-ctx`, `reasoning`, `multimodal`, `structured-output`, `tools`, `experimental`, `large-model`, `powerful-for-free`, `high-volume`, `very-cheap`

**Decision guide** — update the "Task type → model" table to reflect any added/removed models.

**After editing all 3 SKILL.md files:**

```bash
# Pull latest remote changes first, then commit and push each repo
cd ~/Code/oc-workspace-merlin && git pull --ff-only && git add skills/modelhelp/SKILL.md && git commit -m "skills: update modelhelp model list" && git push
cd ~/Code/oc-workspace-nimue && git pull --ff-only && git add skills/modelhelp/SKILL.md && git commit -m "skills: update modelhelp model list" && git push
cd ~/Code/oc-workspace-percy && git pull --ff-only && git add skills/modelhelp/SKILL.md && git commit -m "skills: update modelhelp model list" && git push
```

(If `--ff-only` fails, use `git pull --rebase` instead.)

## Step 7 — Provide all deploy + sync commands

```bash
# Restart containers to pick up new openclaw.json (~30s each)
ssh mba@hsb0.lan "cd ~/Code/nixcfg && gitpl && cd hosts/hsb0/docker && docker compose restart openclaw-gateway"
ssh msbp "cd ~/Code/nixcfg && gitpl && cd hosts/miniserver-bp/docker && docker compose restart openclaw-percaival"

# Pull updated modelhelp skill into running containers
just oc-pull-workspace hsb0   # pulls merlin + nimue workspaces
just oc-pull-workspace msbp   # pulls percy workspace
```

## SYSOP rules

- Do NOT touch fallback/primary model without explicit approval
- Do NOT commit without user saying "OK to apply"
- Do NOT invent or guess model IDs — only use IDs confirmed in the catalogue
- Both openclaw.json configs must stay in sync — always edit both
- modelhelp SKILL.md in all 3 workspace repos must stay in sync with openclaw.json
