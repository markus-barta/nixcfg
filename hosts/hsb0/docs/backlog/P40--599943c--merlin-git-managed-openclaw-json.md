# merlin-git-managed-openclaw-json

**Host**: hsb0
**Priority**: P40
**Status**: Done
**Created**: 2026-02-20

---

## Problem

Merlin's `openclaw.json` is not managed by git. It is seeded via a NixOS activation script only on the first boot, and any runtime changes (like model selection) are only persisted locally on the Docker volume. This is out of sync with how Percy is managed (Percy pulls config from git on boot, while still allowing runtime edits).

Additionally, the model list is outdated and needs to be replaced with a specific list of newer models.

## Solution

Migrate Merlin's `openclaw.json` to be managed by git, using the same pattern implemented for Percy. The git repository will contain the baseline config. On container startup, the entrypoint script will copy this baseline over the live config (creating a timestamped backup of any runtime changes first).

## Implementation

- [x] Create `hosts/hsb0/docker/openclaw-merlin/openclaw.json` as the new git-managed baseline config.
- [x] Populate the baseline config using the live `openclaw.json` from `hsb0` but with the `models` block completely replaced.
- [x] Set Primary Model: `openrouter/google/gemini-3-flash-preview`
- [x] Set Fallback Model: `openrouter/moonshotai/kimi-k2.5`
- [x] Set the new `models` list:
  - `openrouter/anthropic/claude-sonnet-4.6` ("Claude Sonnet 4.6")
  - `openrouter/anthropic/claude-opus-4.6` ("Claude Opus 4.6")
  - `opencode-zen/glm-5-free` ("GLM-5 Free")
  - `openrouter/z-ai/glm-5` ("GLM-5")
  - `openrouter/openai/gpt-5.2-codex` ("GPT-5.2-Codex")
  - `openrouter/google/gemini-3-flash-preview` ("Gemini 3 Flash Preview")
  - `openrouter/google/gemini-3.1-pro-preview` ("Gemini 3.1 Pro Preview")
  - `openrouter/moonshotai/kimi-k2.5` ("Kimi K2.5")
  - `opencode-zen/minimax-m2.5-free` ("MiniMax M2.5 Free")
- [x] Strip runtime noise from the baseline config (remove `meta` and `wizard` blocks).
- [x] Ensure NO hardcoded secrets are in the baseline config (keep substitution vars like `${TELEGRAM_BOT_TOKEN}`).
- [x] Update `hosts/hsb0/docker/docker-compose.yml` to bind-mount the new config as `ro` to `/home/node/.openclaw-config/openclaw.json`.
- [x] Update the inline `command` script in `docker-compose.yml` to include the backup-and-copy logic (copying from the `.openclaw-config` mount to the live `/home/node/.openclaw` path).
- [x] Remove the outdated `openclaw.json` seed block from `hosts/hsb0/configuration.nix`.

## Acceptance Criteria

- [x] `hosts/hsb0/docker/openclaw-merlin/openclaw.json` exists and contains the correct new models.
- [x] `docker-compose.yml` mounts the config and contains the copy script.
- [x] `configuration.nix` is cleaned up.
- [x] No plaintext secrets are committed.

## Notes

- The OpenCode Zen models are not standard OpenRouter slugs; using standard provider prefix syntax `opencode-zen/...`.
- `meta` and `wizard` blocks are runtime tracking data used by OpenClaw and should not be tracked in git.
