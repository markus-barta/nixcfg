#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host="${repo}/hosts/csb1/configuration.nix"
module="${repo}/hosts/csb1/hausv-next.nix"
compose="${repo}/hosts/csb1/docker/hausv-next/compose.yml"
fixture="${repo}/hosts/csb1/docker/hausv-next/fixture.conf"
dockerfile="${repo}/hosts/csb1/docker/hausv-next/Dockerfile"
command="${repo}/hosts/csb1/scripts/hausv-next.sh"
backup="${repo}/hosts/csb1/docker/restic-cron/hetzner/run_backup.sh"

nix-instantiate --parse "${host}" >/dev/null
nix-instantiate --parse "${module}" >/dev/null
bash -n "${command}"

grep -Fq './hausv-next.nix # NIX-368 / HAUSV-513' "${host}"
grep -Fq 'host_ip: 100.64.0.4' "${compose}"
grep -Fq 'published: "8099"' "${compose}"
grep -Fq 'internal: true' "${compose}"
grep -Fq 'device: /var/lib/hausv-next/data' "${compose}"
grep -Fq 'hausv-next-data:/data' "${compose}"
grep -Fq 'network_mode: service:app' "${compose}"
grep -Fq 'traefik.enable=false' "${compose}"
grep -Fq 'read_only: true' "${compose}"
grep -Fq 'no-new-privileges:true' "${compose}"
grep -Fq 'dockerfile: Dockerfile.preview' "${compose}"

if grep -Eq '(^|[^0-9])0\.0\.0\.0:|traefik\.enable=true|csb1_hausv|hausv-proxy|hausv-egress|/run/agenix|/var/lib/csb1-docker/hausv-org' "${compose}"; then
  echo 'FAIL: preview compose crosses a public, secret or production boundary' >&2
  exit 1
fi

grep -Fq 'LOCAL_DEV_LOGIN=true' "${fixture}"
grep -Fq 'SESSION_KEY=snapshot-harness-fixed-key-not-a-secret-000' "${fixture}"
grep -Fq 'HA_BASE_URL=' "${fixture}"
grep -Fq 'HA_TOKEN=' "${fixture}"
grep -Fq 'SMTP_HOST=' "${fixture}"
grep -Fq 'OIDC_CLIENT_SECRET=' "${fixture}"
grep -Fq 'TELEGRAM_BOT_TOKEN=' "${fixture}"
if grep -Eq '/run/agenix|/var/lib/csb1-docker/hausv-org|postgres|hausv\.org/healthz' "${fixture}"; then
  echo 'FAIL: fixture environment references production state or services' >&2
  exit 1
fi

grep -Fq 'trusted build recipe for unreviewed preview refs' "${dockerfile}"
grep -Fq 'readonly remote=https://github.com/inspr-at/hausv-org.git' "${command}"
grep -Fq "readonly tailnet_ip=100.64.0.4" "${command}"
grep -Fq "readonly port=8099" "${command}"
grep -Fq 'tailscale0 does not own' "${command}"
# The next strings are literal shell-source contracts.
# shellcheck disable=SC2016
grep -Fq 'tailnet port ${port} is already owned by another process' "${command}"
# shellcheck disable=SC2016
grep -Fq 'install -m 0444 "${trusted_dockerfile}" "${staging}/Dockerfile.preview"' "${command}"
grep -Fq 'down --remove-orphans --volumes' "${command}"
# shellcheck disable=SC2016
grep -Fq 'mv "${data_dir}" "${previous_data}"' "${command}"
grep -Fq "sudo hausv-next deploy <branch-or-commit>" "${command}"
grep -Fq "sudo hausv-next reset" "${command}"

# Production remains on its original private project and original paths. The
# preview is outside the Restic source tree, so no backup rule changes are due.
grep -Fq 'hausvComposeDir = "/home/mba/Code/hausv-jhw22";' "${host}"
grep -Fq 'source_dir=/var/lib/csb1-docker/hausv-org' "${host}"
grep -Fq -- "--exclude '/backup/var/lib/csb1-docker/hausv-org'" "${backup}"
if grep -Fq '/var/lib/hausv-next' "${backup}"; then
  echo 'FAIL: fixture preview must not join the production backup set' >&2
  exit 1
fi

echo 'T41 HAUSV tailnet fixture preview contract OK'
