#!/usr/bin/env bash
# OPS-271 / AEON-455: generate the phone push VAPID key pair for PAIMOS AEON once.
# Called by aeon-secrets.service with the target path inside /var/lib/aeon-secrets
# (0700 root). The key never leaves csb1: no output, no git, no agenix.
# Format read by AEON (internal/config/phone_push.go): one JSON object with
# public_key (base64url, uncompressed P-256 point), private_key (base64url,
# 32-byte scalar) and subject (https: URL of this instance).
set -euo pipefail

out=$1
dir=$(dirname "$out")
tmp=$(mktemp -d "$dir/.vapid.XXXXXX")
trap 'rm -f "$tmp/k.der" "$out.tmp"; rmdir "$tmp"' EXIT
umask 0277

openssl ecparam -name prime256v1 -genkey -noout -outform DER -out "$tmp/k.der"
# SEC1 ECPrivateKey for P-256 with named curve and public key: 121 bytes,
# 30 77 02 01 01 04 20 <32-byte scalar> a0 0a <oid> a1 44 03 42 00 <65-byte point>.
if [ "$(wc -c <"$tmp/k.der")" -ne 121 ]; then
  echo "aeon-phone-push-vapid: unexpected key size" >&2
  exit 1
fi
if [ "$(head -c 7 "$tmp/k.der" | od -An -tx1 | tr -d ' \n')" != 30770201010420 ]; then
  echo "aeon-phone-push-vapid: unexpected key layout" >&2
  exit 1
fi
# The scalar and the embedded public point must form a valid key pair
# (pkey -check recomputes the point; ec -pubout would only copy it).
if ! openssl pkey -inform DER -in "$tmp/k.der" -check -noout >/dev/null 2>&1; then
  echo "aeon-phone-push-vapid: key pair check failed" >&2
  exit 1
fi

b64url() { base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='; }
priv=$(head -c 39 "$tmp/k.der" | tail -c 32 | b64url)
pub=$(tail -c 65 "$tmp/k.der" | b64url)
if [ ${#priv} -ne 43 ] || [ ${#pub} -ne 87 ]; then
  echo "aeon-phone-push-vapid: unexpected encoded length" >&2
  exit 1
fi

printf '{"public_key":"%s","private_key":"%s","subject":"https://aeon.barta.cm"}\n' "$pub" "$priv" >"$out.tmp"
chmod 0444 "$out.tmp"
mv "$out.tmp" "$out"
