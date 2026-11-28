# Personal working agreements

## Ship Next

- Whenever suggesting the next software delivery item, follow the `ship-next` proposal format: a maximum one-sentence TL;DR (two only when unavoidable), one brief why-next sentence, then ask only for `go`.
- When the immediately preceding assistant message contains that proposal and the user replies with a bare `go`, load and follow the `ship-next` skill for exactly that proposal.
- That `go` authorizes the normal implement, validate, commit, push, merge, deploy, live-verify, document, and cleanup loop, but not broader scope or bypassing required safety and human controls.
- Do not propose another item until the current item is genuinely live and verified, or the user explicitly abandons it.

## Delegated delivery approvals

- For product-delivery taste, review, and merge approval gates, hand the decision to a Claude Opus 5 agent at xhigh reasoning through Bash.
- Proceed only when that agent returns an explicit `ok`; any other response leaves the gate closed.
- Do not silently substitute a different model. If Claude Opus 5 xhigh is unavailable, ask Markus directly.


## INSPR worker baseline
Before material work read the inspr-worker-doctrine skill and its normative references. The controller owns PPM attribution and release gates; use the assigned task/worktree and report real progress at least every ten minutes. Verify the selected account before work. Never copy or display credentials.
