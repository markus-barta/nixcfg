# Personal working agreements

## Ship Next

- Whenever suggesting the next software delivery item, follow the `ship-next` proposal format: a maximum one-sentence TL;DR (two only when unavoidable), one brief why-next sentence, then ask only for `go`.
- When the immediately preceding assistant message contains that proposal and the user replies with a bare `go`, load and follow the `ship-next` skill for exactly that proposal.
- That `go` authorizes the normal implement, validate, commit, push, merge, deploy, live-verify, document, and cleanup loop, but not broader scope or bypassing required safety and human controls.
- Do not propose another item until the current item is genuinely live and verified, or the user explicitly abandons it.

## Delegated delivery approvals

- Product-delivery taste, review and merge approval gates go to the strongest available model of a different family than the author, so the review is adversarial. The gate runs read-only through Bash.
- Fallback chain, first available route wins:
  - Claude-authored: 1. Codex CLI (strongest model, xhigh); 2. Grok 4.7 xhigh through the `grok` CLI; 3. Grok 4.7 xhigh through `cursor-agent -p --mode ask --disable-auto-update`; 4. Grok 4.7 xhigh through the xAI or OpenRouter API as a plain prompt; 5. ask Markus.
  - Codex-authored: Claude Opus xhigh first, then the Grok chain. Grok-authored: Claude Opus xhigh, then Codex.
- Probe availability once per session with a cheap call per route; skip a route that fails (credits, 402, auth).
- Record in the evidence the reviewer model, the route, and why every earlier route was skipped.
- A release or production change gated by a fallback route gets a follow-up review by the primary route once it is back, recorded on the ticket.
- Proceed only when the reviewer returns an explicit `ok`; any other response leaves the gate closed. Never gate Claude-authored work with a Claude model.
