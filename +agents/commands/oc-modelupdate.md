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

## Step 5 — After user approval: apply + commit + push

1. Edit both JSON configs (identical models section)
2. `git diff` to verify — no secrets, no unrelated changes
3. `git add` + `git commit` + `git push`
4. Provide restart commands (no rebuild needed for config-only changes):

```bash
# hsb0 (~30s)
ssh mba@hsb0.lan "cd ~/Code/nixcfg && gitpl && cd hosts/hsb0/docker && docker compose restart openclaw-gateway"

# miniserver-bp (~30s)
ssh msbp "cd ~/Code/nixcfg && gitpl && cd hosts/miniserver-bp/docker && docker compose restart openclaw-percaival"
```

## SYSOP rules

- Do NOT touch fallback/primary model without explicit approval
- Do NOT commit without user saying "OK to apply"
- Do NOT invent or guess model IDs — only use IDs confirmed in the catalogue
- Both configs must stay in sync — always edit both
