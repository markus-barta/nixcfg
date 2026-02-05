# Investigate and mitigate 400 "Thought signature is not valid" Errors

**Created**: 2026-02-05  
**Priority**: P2200 (High)  
**Status**: Backlog

---

## Problem

Intermittent API errors occur when using the Google Gemini models via OpenRouter. The error message is:
`400 Provider returned error { "error": { "code": 400, "message": "Unable to submit request because Thought signature is not valid..", "status": "INVALID_ARGUMENT" } }`

This seems to happen when the model generates internal "reasoning" or "thoughts" that are not correctly formatted or signed when passed back through the OpenRouter gateway. It interrupts the conversation flow and can lead to lost tool execution context.

---

## Solution

1.  **Monitor Frequency**: Track if this happens more often with specific tool calls or long conversations.
2.  **Model Configuration**: Investigate if setting specific resident reasoning flags or changing the model version (e.g., switching from `gemini-3-flash-preview` to a stable version) mitigates the issue.
3.  **Gateway Settings**: Check if OpenClaw's Reasoning/Verbose settings contribute to this formatting error.
4.  **Upstream Check**: Technical research into OpenRouter/Google Vertex AI "Thought signature" requirements.

---

## Acceptance Criteria

- [ ] Root cause identified (Formatting issue vs. Upstream bug).
- [ ] Mitigation strategy implemented (e.g., auto-retry or model switch).
- [ ] Reduction of 400 errors during complex tool-use sessions.

---

## Test Plan

### Manual Test

1. Execute a long series of complex tool calls (like the M365 auth flow).
2. Verify if the 400 error reappears and if the system recovers.

### Automated Test

Check logs for the specific error string.
