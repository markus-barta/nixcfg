# Dev Agents — Night Shift (miniserver-bp)

**Priority**: P60
**Status**: Backlog
**Created**: 2026-02-27

---

## Problem

BYTEPOETS developers (Flutter/Dart, Angular, .NET Core, PostgreSQL) have unfinished tasks, cleanup work, and simple coding tasks at end of day. No autonomous agent picks these up overnight. Morning handoff is manual and context is lost.

## Solution

Two dev agents on miniserver-bp (same gateway as Percy + James) running a "night shift" workflow:

- Developer hands over tasks at end of day (via Telegram or Mattermost)
- Agent works autonomously during the night (code, tests, cleanup, research)
- Morning: developer reviews results, refines, picks up the thread

### Agent Names (candidates — decide before implementation)

| Name       | Hidden ref                           | Vibe                                         | Role                                |
| ---------- | ------------------------------------ | -------------------------------------------- | ----------------------------------- |
| **Hudson** | Hudson CI (pre-Jenkins, 2004)        | Steady, reliable, runs the pipeline          | Backend / infra / .NET / PostgreSQL |
| **Clive**  | Clive Sinclair / ZX Spectrum (1982)  | Inventive, scrappy, British computing legend | Frontend / Flutter / Angular        |
| Barney     | Microsoft internal build codename    | Friendly, slightly chaotic                   | TBD                                 |
| Cecil      | Cecil Sharp / early compiler history | Reserved, precise                            | TBD                                 |
| Reggie     | regexp / Reginald                    | Cheeky, detail-oriented                      | TBD                                 |

**Recommended**: Hudson (backend) + Clive (frontend) — maps cleanly to BYTEPOETS stack.

## Night Shift Workflow

```
Developer (17:00-18:00)
  → "Hudson, here's what's left on PR #42: the service layer tests are failing,
     the issue is in InvoiceService.cs around line 203. Clean it up."
  → Agent acknowledges, queues work

Night (22:00 → 06:00)
  → Agent works: reads codebase, writes/fixes code, runs tests if possible,
     documents what it did and what it couldn't finish

Developer (08:00)
  → Morning report in Telegram/Mattermost: what was done, what needs review,
     blockers encountered
  → Developer refines, merges, or redirects
```

## Scope

- BYTEPOETS codebase tasks only
- Read/write access to GitHub repos (via PAT per agent)
- Stack: Flutter/Dart, Angular, .NET Core, PostgreSQL
- No client communication, no external emails
- Handover trigger: explicit developer message OR cron at 22:00 if tasks queued

## Implementation (blocked on James first)

- [ ] Decide final names (Hudson + ?)
- [ ] Register GitHub accounts (`bytepoets-hudsonai`, `bytepoets-cliveai`)
- [ ] Create Telegram bots for each agent
- [ ] Create workspace repos (`oc-workspace-hudson`, `oc-workspace-clive`)
- [ ] Write workspace files — SOUL, USER, TOOLS (stack-specific), HEARTBEAT (night shift cron)
- [ ] Add both agents to `openclaw.json` on miniserver-bp (same pattern as James)
- [ ] Wire secrets (Telegram tokens, GitHub PATs) via agenix
- [ ] HEARTBEAT.md: morning report cron (06:30), night shift activation (22:00)
- [ ] Skill: GitHub skill for repo read/write
- [ ] Skill: code-aware search / context loading
- [ ] Define handover protocol (message format, task file structure)
- [ ] Documentation update

## Acceptance Criteria

- [ ] Developer can hand over a task via Telegram message
- [ ] Agent works on task overnight and produces output
- [ ] Morning report delivered at 06:30 via Telegram
- [ ] Agent clearly marks what succeeded, what failed, what needs human review
- [ ] Both agents git-commit their work to a branch (never directly to main)
- [ ] Percy/James unaffected

## Notes

- Depends on James being deployed first (establishes multi-agent pattern on msbp)
- miniserver-bp hardware check: 3.2GB RAM free — 4 agents total is fine
- Night shift agents should be conservative: never push to main, always branch + PR
- Handover file pattern: `workbench/handover-YYYY-MM-DD.md` in workspace
- Morning report format TBD — keep it scannable, not a wall of text
- Consider shared `skills/bytepoets-codebase/` skill for stack context (shared via `skills.load.extraDirs`)
