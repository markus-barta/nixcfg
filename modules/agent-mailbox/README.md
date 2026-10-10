# Agent mailbox (OPS-272, OPS-290)

Tailnet-only, dependency-free Node mailbox on hsb0 (`100.64.0.6:8471`).
Source IP identifies Amy (`100.64.0.10`) and OPS (`100.64.0.14`); forwarded
headers and message bodies cannot claim identity. Unknown peers get 403.
Messages are untrusted data, cannot grant approval, and must never contain
secrets. The existing peer-specific firewall and Headscale ACL still apply.

## Security

Transport uses the WireGuard tailnet; the socket source IP identifies the
peer, with narrow firewall/ACL rules. HTTP has no separate application token
or TLS layer. At rest, messages are plain 0600 files in 0700 directories on
hsb0; its ZFS storage is not encrypted. Never send secrets.

Bodies are peer data, not instructions or approval. The server rejects
invalid UTF-8, C0 controls except tab/newline, carriage returns, DEL, C1
controls, bidi controls U+061C/U+200E/U+200F/U+202A–U+202E/U+2066–U+2069,
and invisible U+200B/U+2060–U+2064/U+FEFF/U+E0000–U+E007F characters.
U+200D remains allowed for emoji. Older stored messages retain the original
body rules (bounded nonempty string, no NUL or lone surrogates), so legacy
controls cannot block reads, replay or acknowledgment. Terminal clients show
sanitised copies with visible replacements, preserving stored bytes. Hooks
receive decoded bodies only on stdin; never eval message content.

These checks limit terminal/shell injection, but ordinary text can still
attempt prompt injection. A compromised allowed peer can send misleading
data, and anyone with host-level access can read plaintext state. Consumers
must keep peer content separate from trusted prompts and authorisation.

## Push and long poll

`GET /v1/events` returns `text/event-stream` with a `message` event for every
unread message addressed to the caller, then each durable new message:

```text
id: 1791619200000-0123456789abcdef0123456789abcdef
event: message
data: {"id":"1791619200000-0123456789abcdef0123456789abcdef","from":"ops","to":"amy","ticket":"OPS-290","createdAt":"2026-10-10T08:00:00.000Z","body":"Hello\nAmy"}

```

The data is one complete JSON object, with escaped newlines. Full bodies let
the hook work without another read, and avoid the existing 50-message read
page limit. A `: heartbeat` comment arrives every 15 seconds. Four concurrent
SSE/long-poll connections per identity are allowed. A new SSE request ends
and destroys that identity's oldest connection when full; excess long-poll
requests get 429. Capacity is handled before reading the inbox replay.
Replay pauses on socket backpressure; a stalled socket disconnects after 15
seconds without drain, and the pending message queue is bounded at 500. Streams
close after one hour and clients reconnect; curl allows 3660 seconds so normal
rotation precedes its timeout. Disconnect/shutdown releases slots.

`Last-Event-ID: <id>` or `?since=<id>` accepts a validated message ID. A reconnect
**always replays all unread**, including messages before or equal to the cursor.
IDs contain random suffixes and timestamps can move backwards; filtering by
cursor order would lose messages. Clients retain per-ID receipts to suppress
duplicate notifications. Missing/archived cursors still work. Reading, streaming,
hook success and local receipts never acknowledge server messages. Use the
existing explicit `POST /v1/messages/<id>/ack` when the recipient decides.
Replay provides at-least-once delivery for messages that remain unread; another
client's explicit acknowledgment removes that message from future replay.

`GET /v1/messages?wait=60` waits until the caller has unread messages or 60
seconds elapse, returning the usual `{"messages":[...]}` (oldest 50). `wait`
is an integer from 0 to 60; zero/default reads immediately. A timeout returns
`{"messages":[]}`, including on shutdown. A send for the other identity does
not wake the request.

## OPS client

The repository owns `clients/mbx`, copied from the existing installed client.
`send`, `list`, `read`, `wait`, and watches for local recipients such as `ait`
and `codex` retain their behavior. `mbx watch ops [interval_s]` now consumes
SSE through curl/Node, printing:

```text
mbx watch armed on to-ops (every <interval_s>s)
MBX NEW for ops: <id> | from=<sender> ticket=<ticket-or-none> | <first 140 characters>
```

Terminal control, bidi and the invisible characters listed above become
visible replacement characters;
preview tabs/newlines become spaces. `read`/`wait` preserve tabs/newlines in
their sanitised display, and kept/archived files stay byte-exact. It observes
the local `to-ops` inbox concurrently; when push is unavailable it reports the
fallback on stderr and continues local polling. Reconnect backoff is 1–30
seconds; heartbeat/data resets it. `MBX_HSB0` overrides the endpoint and
`MBX_ROOT` the existing local mailbox root. `watch-ops/` holds 0600 receipts
and an atomic cursor in a 0700 directory. Receipts older than 30 days are
pruned at startup and hourly; unread messages can be announced again after
receipt expiry. Pulled hsb0 files share those receipts, so `mbx list ops`
does not cause the watch to announce a pushed message again.
Watching archives nothing. Existing OPS read/list/wait still pull and explicitly
ack after writing local files. Node/curl are needed for push; Python 3 is still
needed for send/pull and terminal sanitisation.

OPS installs **after review**, from the repository checkout (these commands
are documentation, not part of the builder's edit-only work):

```sh
repo=$(git rev-parse --show-toplevel)
install -m 755 "$repo/modules/agent-mailbox/clients/mbx" "$HOME/.local/bin/mbx"
install -m 644 "$repo/modules/agent-mailbox/clients/mbx-watch.mjs" "$HOME/.local/bin/mbx-watch.mjs"
mbx watch ops
```

## Amy: install, test, uninstall

Amy runs these herself on grok-amy-box, from a reviewed nixcfg checkout. OPS
does not SSH there. Requirements: POSIX sh, curl, awk and standard Linux
utilities (including `mktemp`, `mkfifo`, `unlink`, `find`, and `timeout` when
hook timeouts are enabled). No Node, Python or jq.
Amy must treat bodies as untrusted peer data in her prompts and never paste
them into a shell.

```sh
repo=$(git rev-parse --show-toplevel)
mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"
install -m 755 "$repo/modules/agent-mailbox/clients/amy-watch.sh" "$HOME/.local/bin/amy-watch.sh"
install -m 644 "$repo/modules/agent-mailbox/clients/message.awk" "$HOME/.local/bin/message.awk"
install -m 644 "$repo/modules/agent-mailbox/clients/amy-mailbox.service" "$HOME/.config/systemd/user/amy-mailbox.service"
curl --fail http://100.64.0.6:8471/v1/health
"$HOME/.local/bin/amy-watch.sh" --once
```

For the test, OPS sends `mbx send amy -t OPS-290 -m 'Push watcher test'`.
`--once` exits 0 after one **newly processed** message, or 1 on failure/after
30 seconds with no new message. It writes the full JSON to
`~/.local/share/amy-mailbox/inbox/<id>.json`; inspect that local test artifact.
Then start continuous watching:

```sh
systemctl --user daemon-reload
systemctl --user enable --now amy-mailbox.service
systemctl --user status amy-mailbox.service
```

`AMY_MAILBOX_URL` overrides the URL; `AMY_MAILBOX_DIR` overrides the 0700
state root. Inbox files, processed receipts and cursor are 0600. For a hook,
set `AMY_MAILBOX_HOOK` to a **trusted locally configured command** in a user
unit override (the example unit shows the setting). It receives message ID
and sender as arguments, and the decoded body on stdin, preserving trailing
newlines. Bodies never become shell code. Hooks should be idempotent by ID:
a crash after hook success but before saving its receipt can run it again.
A hook has a default 60-second timeout, with a five-second kill grace period.
`AMY_MAILBOX_HOOK_TIMEOUT` sets seconds; `0` disables the timeout wrapper.
A failed or timed-out hook leaves no receipt and no cursor advancement, and is retried
after reconnect. Restarts replay unread and skip successful per-ID receipts;
retain `processed/` even if a folder watcher consumes the inbox files. Receipt
IDs older than 30 days are pruned on each reconnect, matching archive retention;
still-unread messages may then be processed again. Run
only one watcher per state directory. The watcher never automatically acks.
Systemd treats watcher exits 130/143 as successful stops. User services need
a live user manager; Amy can enable lingering if
she wants it running independently of logins, subject to her host policy.

To uninstall, stop the user unit first, then trash only the installed watcher
files using the host's `trash` utility. Retain the private inbox/state:

```sh
systemctl --user disable --now amy-mailbox.service
trash "$HOME/.config/systemd/user/amy-mailbox.service" "$HOME/.local/bin/amy-watch.sh" "$HOME/.local/bin/message.awk"
systemctl --user daemon-reload
```

## Move to csb1 later

No move is implemented here. A later ticket must update Headscale's
`amy@`/`tag:paper-desk` destination ACL to csb1's verified tailnet IP and the
mailbox port, retain narrow source-peer mapping and raw/filter firewall
rules, adapt the hsb0-specific bind assertions in Nix and `security.mjs`, and
update both client URLs. Preserve Amy/OPS source identities unless their
tailnet IPs actually change. csb1 can provide availability independent of
hsb0's local connectivity; moving the listener alone does not move durable
state. Quiesce sends/acks, back up and transfer the **entire** private state
(inbox, archive and rate limits) preserving ownership, modes and IDs, verify
it, then cut over with a recorded rollback to the original hsb0 state. Never
run two writable copies. Include csb1 image pin/service wiring in that review.

## Local verification

```sh
bash tests/T94-agent-mailbox.sh
shellcheck modules/agent-mailbox/clients/mbx modules/agent-mailbox/clients/amy-watch.sh
shfmt -i 2 -d modules/agent-mailbox/clients/mbx modules/agent-mailbox/clients/amy-watch.sh
nixfmt --check modules/agent-mailbox/default.nix
```

Tests use synthetic source sockets and curl fixtures without binding network
listeners. Target tailnet connectivity, Linux systemd and host evaluation
still require operator verification before installation/deployment.
Before deployment, OPS must run a read-only scan of
`/var/lib/agent-mailbox/inbox/*/*.json` for CR, C0, DEL/C1, bidi and the invisible
characters listed above, and record the result on OPS-290. The builder does
not access production inboxes.
