#!/usr/bin/env bash
# fritz-tripwire — capture diagnostic snapshot of all fritz mesh devices.
# Invoked by adnanh/webhook on POST to /hooks/fritz-down.
# Args (passed by webhook from JSON payload): $1=ip $2=monitor $3=status
set -uo pipefail

IP="${1:-unknown}"
MONITOR="${2:-unknown}"
STATUS="${3:-}"

# DOWN-only gate (NIX-146): Kuma fires the webhook on BOTH up and down
# transitions. Snapshot only on DOWN. Fail-safe — skip only when status
# clearly indicates UP; anything else (incl. empty/unknown) still captures.
if printf '%s' "$STATUS" | grep -qiE 'up|✅|^1$|true'; then
  echo "fritz-tripwire: skipping non-DOWN event (status='${STATUS}')" >&2
  exit 0
fi

TS=$(date +%Y%m%d-%H%M%S)
DIR="/incidents/fritz-${IP}-${TS}"
mkdir -p "$DIR"

DEVICES=(192.168.1.5 192.168.1.6 192.168.1.7 192.168.1.8 192.168.1.9)

USERNAME=""
PASSWORD=""
if [ -r /secrets/fritz.env ]; then
  set -a
  # shellcheck source=/dev/null
  . /secrets/fritz.env
  set +a
fi

cat >"$DIR/meta.json" <<EOF
{
  "timestamp": "$(date -Iseconds)",
  "trigger_ip": "${IP}",
  "monitor": "${MONITOR}",
  "status": $(printf '%s' "$STATUS" | jq -Rs .)
}
EOF

for ip in "${DEVICES[@]}"; do
  {
    for port in 80 443 49000; do
      if timeout 2 bash -c "</dev/tcp/$ip/$port" 2>/dev/null; then
        echo "$ip:$port OPEN"
      else
        echo "$ip:$port closed"
      fi
    done
  } >"$DIR/tcp-${ip}.txt"

  [ -z "$USERNAME" ] || [ -z "$PASSWORD" ] && continue

  curl -s -k --max-time 5 --anyauth -u "${USERNAME}:${PASSWORD}" \
    "http://${ip}:49000/upnp/control/deviceinfo" \
    -H 'Content-Type: text/xml; charset="utf-8"' \
    -H 'SoapAction: urn:dslforum-org:service:DeviceInfo:1#GetInfo' \
    -d '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetInfo xmlns:u="urn:dslforum-org:service:DeviceInfo:1"/></s:Body></s:Envelope>' \
    >"$DIR/tr064-deviceinfo-${ip}.xml" 2>/dev/null || true

  curl -s -k --max-time 5 --anyauth -u "${USERNAME}:${PASSWORD}" \
    "http://${ip}:49000/upnp/control/deviceinfo" \
    -H 'Content-Type: text/xml; charset="utf-8"' \
    -H 'SoapAction: urn:dslforum-org:service:DeviceInfo:1#GetDeviceLog' \
    -d '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetDeviceLog xmlns:u="urn:dslforum-org:service:DeviceInfo:1"/></s:Body></s:Envelope>' \
    >"$DIR/tr064-devicelog-${ip}.xml" 2>/dev/null || true
done

echo "snapshot: ${DIR}" >&2
