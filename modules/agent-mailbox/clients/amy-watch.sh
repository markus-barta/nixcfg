#!/bin/sh
# OPS-290: message bodies are untrusted DATA. Only the locally configured hook
# is a command; ids/from are validated and body bytes go exclusively to stdin.
set -eu
umask 077
LC_ALL=C
export LC_ALL
once=0
case ${1-} in
'') ;;
--once) once=1 ;;
*)
  echo 'usage: amy-watch.sh [--once]' >&2
  exit 2
  ;;
esac
endpoint=${AMY_MAILBOX_URL:-http://100.64.0.6:8471}
directory=${AMY_MAILBOX_DIR:-"$HOME/.local/share/amy-mailbox"}
helper=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/message.awk
mkdir -p "$directory/inbox" "$directory/processed"
chmod 700 "$directory" "$directory/inbox" "$directory/processed"
work=$(mktemp -d "$directory/.watch.XXXXXXXX")
curl_pid=''
cleanup() {
  if [ -n "$curl_pid" ]; then
    kill "$curl_pid" 2>/dev/null || true
    wait "$curl_pid" 2>/dev/null || true
  fi
  # Only this process's fixed temporary files; no recursive removal.
  for file in events event.json id from body cursor receipt; do
    if [ -e "$work/$file" ]; then unlink "$work/$file"; fi
  done
  rmdir "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkfifo "$work/events"
cursor=''
if [ -f "$directory/cursor" ]; then
  cursor=$(cat "$directory/cursor")
  if ! printf '%s\n' "$cursor" | awk 'NR == 1 && length($0) == 46 && substr($0, 1, 13) !~ /[^0-9]/ && substr($0, 14, 1) == "-" && substr($0, 15) !~ /[^a-f0-9]/ { ok = 1 } END { exit !(ok && NR == 1) }'; then
    echo 'amy-watch: invalid saved cursor' >&2
    exit 2
  fi
fi
backoff=1
while :; do
  duration=3600
  [ "$once" -eq 0 ] || duration=30
  set -- --silent --show-error --fail --no-buffer --connect-timeout 5 --max-time "$duration"
  [ -z "$cursor" ] || set -- "$@" -H "Last-Event-ID: $cursor"
  curl "$@" "$endpoint/v1/events" >"$work/events" &
  curl_pid=$!
  event=''
  event_id=''
  data=''
  delivered=0
  failed=0
  while IFS= read -r line; do
    if [ "${#line}" -gt 131072 ]; then
      echo 'amy-watch: oversized event; retaining cursor' >&2
      failed=1
      break
    fi
    # curl preserves SSE CRLF. Strip just the framing CR, never JSON bytes.
    line=${line%"$(printf '\r')"}
    case $line in
    ': heartbeat') backoff=1 ;;
    'event: '*) event=${line#'event: '} ;;
    'id: '*) event_id=${line#'id: '} ;;
    'data: '*) data=${line#'data: '} ;;
    '')
      if [ "$event" = message ]; then
        printf '%s\n' "$data" >"$work/event.json"
        if ! awk -v out="$work" -f "$helper" "$work/event.json"; then
          echo 'amy-watch: invalid message event; retaining cursor' >&2
          failed=1
          break
        fi
        id=$(cat "$work/id")
        from=$(cat "$work/from")
        if [ "$event_id" != "$id" ]; then
          echo 'amy-watch: event id mismatch; retaining cursor' >&2
          failed=1
          break
        fi
        if [ ! -f "$directory/processed/$id" ]; then
          if [ -n "${AMY_MAILBOX_HOOK:-}" ]; then
            # The hook is trusted local configuration. Expansion
            # of $1/$2 happens inside quotes; no body is evaluated.
            if ! sh -c "$AMY_MAILBOX_HOOK \"\$1\" \"\$2\"" amy-mailbox-hook "$id" "$from" <"$work/body"; then
              echo "amy-watch: hook failed for $id; retaining cursor" >&2
              failed=1
              break
            fi
          else
            # Keep the received JSON bytes exact; sanitising is
            # for terminal display, never stored peer data.
            chmod 600 "$work/event.json"
            mv "$work/event.json" "$directory/inbox/$id.json"
          fi
          printf '%s\n' "$id" >"$work/receipt"
          mv "$work/receipt" "$directory/processed/$id"
          printf '%s\n' "$id" >"$work/cursor"
          mv "$work/cursor" "$directory/cursor"
          cursor=$id
          delivered=1
          backoff=1
          [ "$once" -eq 0 ] || break
        fi
      fi
      event=''
      event_id=''
      data=''
      ;;
    esac
  done <"$work/events"
  kill "$curl_pid" 2>/dev/null || true
  if wait "$curl_pid"; then curl_status=0; else curl_status=$?; fi
  curl_pid=''
  if [ "$once" -eq 1 ]; then
    [ "$delivered" -eq 1 ] && [ "$failed" -eq 0 ] && exit 0
    exit 1
  fi
  if [ "$curl_status" -ne 0 ] || [ "$failed" -ne 0 ]; then
    echo "amy-watch: stream unavailable; reconnecting in ${backoff}s" >&2
  fi
  sleep "$backoff"
  backoff=$((backoff * 2))
  [ "$backoff" -le 30 ] || backoff=30
done
