Commit and push ALL workspace repos. Process each repo in order:

1. `~/Code/nixcfg`
2. `~/Code/oc-workspace-percy`
3. `~/Code/oc-workspace-merlin`

For **each repo**:

1. `cd` into the repo directory. If it doesn't exist, skip it and note that.
2. Run `git status` — if working tree is clean and nothing to push, skip with a short note.
3. If there are changes, follow the standard push procedure:
   a. Run `git diff` (staged + unstaged) to see everything that changed.
   b. **Group into logical commits** — files that belong together go in one commit.
   c. For each group: `git add <files>` then `git commit -m "<message>"`. Use the repo's existing commit message style (check `git log --oneline -10`).
   d. If pre-commit hooks modify files, stage auto-fixed files and retry. Never amend.
   e. `git pull --rebase && git push`.
4. If something looks wrong (secrets, unexpected files), stop and alert the user.

After all repos are processed, print a **summary table**:

| Repo                | Status           |
| ------------------- | ---------------- |
| nixcfg              | 3 commits pushed |
| oc-workspace-percy  | clean, skipped   |
| oc-workspace-merlin | 1 commit pushed  |

Do NOT ask for confirmation — just do it.
