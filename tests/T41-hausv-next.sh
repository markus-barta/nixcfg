#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host="${repo}/hosts/csb1/configuration.nix"
module="${repo}/hosts/csb1/hausv-next.nix"
compose="${repo}/hosts/csb1/docker/hausv-next/compose.yml"
fixture="${repo}/hosts/csb1/docker/hausv-next/fixture.conf"
dockerfile="${repo}/hosts/csb1/docker/hausv-next/Dockerfile"
command="${repo}/hosts/csb1/scripts/hausv-next.sh"
runbook="${repo}/hosts/csb1/docs/RUNBOOK.md"
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

grep -Fq 'trusted build recipe for operator-supplied preview archives' "${dockerfile}"
grep -Fq "readonly tailnet_ip=100.64.0.4" "${command}"
grep -Fq "readonly port=8099" "${command}"
grep -Fq 'tailscale0 does not own' "${command}"
grep -Fq 'validate_label()' "${command}"
grep -Fq 'deploy requires a tar archive on stdin' "${command}"
# shellcheck disable=SC2016
grep -Fq 'cat >"${archive}"' "${command}"
# shellcheck disable=SC2016
grep -Fq 'validate_archive "${archive}"' "${command}"
grep -Fq 'the archive contains an unsafe path' "${command}"
grep -Fq 'the archive contains a device, fifo or hard link' "${command}"
# shellcheck disable=SC2016
grep -Fq 'tar --extract --file "${archive}" --directory "${context}"' "${command}"
grep -Fq -- '--no-same-owner --no-same-permissions --delay-directory-restore' "${command}"
# The next strings are literal shell-source contracts.
# shellcheck disable=SC2016
grep -Fq 'tailnet port ${port} is already owned by another process' "${command}"
# shellcheck disable=SC2016
grep -Fq 'install -m 0444 "${trusted_dockerfile}" "${context}/Dockerfile.preview"' "${command}"
grep -Fq 'down --remove-orphans --volumes' "${command}"
# shellcheck disable=SC2016
grep -Fq 'mv "${data_dir}" "${previous_data}"' "${command}"
grep -Fq "git archive --format=tar <ref> | ssh csb1 sudo hausv-next deploy <label>" "${command}"
grep -Fq "sudo hausv-next reset" "${command}"
grep -Fq 'http://100.64.0.4:8099' "${command}"
grep -Fq 'git archive --format=tar <ref> | ssh csb1 sudo hausv-next deploy <ref>' "${runbook}"
grep -Fq 'http://100.64.0.4:8099' "${runbook}"

if grep -Eq 'git clone|clone --mirror|refresh_mirror|github\.com/inspr-at/hausv-org|git -C|git fetch|rev-parse|validate_ref' "${command}"; then
  echo 'FAIL: preview deploy must consume stdin and never clone or fetch' >&2
  exit 1
fi
if grep -Fq 'git' "${module}"; then
  echo 'FAIL: hausv-next must not retain a git runtime dependency' >&2
  exit 1
fi

# Production remains on its original private project and original paths. The
# preview is outside the Restic source tree, so no backup rule changes are due.
grep -Fq 'hausvComposeDir = "/home/mba/Code/hausv-jhw22";' "${host}"
grep -Fq 'source_dir=/var/lib/csb1-docker/hausv-org' "${host}"
grep -Fq -- "--exclude '/backup/var/lib/csb1-docker/hausv-org'" "${backup}"
if grep -Fq '/var/lib/hausv-next' "${backup}"; then
  echo 'FAIL: fixture preview must not join the production backup set' >&2
  exit 1
fi

# The slot binds directly with no proxy, so BASE_URL is public by the
# application's own test and TRUSTED_PROXY_CIDRS becomes mandatory. Without it
# the container crash-loops on "TRUSTED_PROXY_CIDRS is required when BASE_URL is
# public" and the slot silently never serves anything (NIX-370).
grep -Eq '^TRUSTED_PROXY_CIDRS=.+' "${fixture}" || {
  echo 'FAIL: the preview fixture must set TRUSTED_PROXY_CIDRS; its BASE_URL is public' >&2
  exit 1
}
if grep -E '^TRUSTED_PROXY_CIDRS=' "${fixture}" | grep -qE '0\.0\.0\.0/0|::/0'; then
  echo 'FAIL: the preview slot must not trust the entire address space' >&2
  exit 1
fi

# An internal Docker network silently disables host port publishing: the binding
# is accepted, never established, and the container still reports healthy. The
# slot is useless in that state and nothing surfaces the cause (NIX-370).
if grep -Eq '^[[:space:]]*internal:[[:space:]]*true' "${compose}"; then
  echo 'FAIL: the preview network must not be internal; that disables port publishing' >&2
  exit 1
fi

# Symlinks must be judged, not banned. The source repository legitimately
# contains them (.claude/commands/*.md point into the vendored doctrine
# submodule) and a blanket ban made every deploy fail the moment that landed.
# The property that matters is that a link cannot reach outside the archive.
grep -Fq 'the archive contains a symlink pointing outside it' "${command}" || {
  echo 'FAIL: the archive validator must reject escaping symlinks specifically' >&2
  exit 1
}
if grep -Fq 'the archive contains a link or special file' "${command}"; then
  echo 'FAIL: blanket symlink ban reintroduced; it breaks every deploy of this repo' >&2
  exit 1
fi

echo 'T41 HAUSV tailnet fixture preview contract OK'
