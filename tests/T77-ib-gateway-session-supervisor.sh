#!/usr/bin/env bash
# HOSTD-58 paper IB Gateway session supervisor contract.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
module="${repo}/modules/ib-gateway-session/default.nix"
helper="${repo}/modules/ib-gateway-session/supervisor.py"
host="${repo}/hosts/hsb0/configuration.nix"
compose="${repo}/hosts/hsb0/docker/compose-spec.nix"
docs="${repo}/hosts/hsb0/docs/IB-GATEWAY.md"

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  discover -s "${repo}/tests" -p 'test_ib_gateway_session_supervisor.py' -v
nix-instantiate --parse "${module}" >/dev/null

grep -Fq '../../modules/ib-gateway-session' "${host}"
grep -Fq 'nixcfg.ibGatewaySession' "${host}"
grep -Fq 'alert.enable = false' "${host}"
grep -Fq 'alert.transport = "none"' "${host}"
grep -Fq 'ib-gateway-session' "${module}"
grep -Fq 'OnUnitActiveSec = "5m"' "${module}"
# Match literal Nix interpolation, not a shell variable.
# shellcheck disable=SC2016
grep -Fq '/run/lock/compose-${stack.stackName}.lock' "${module}"
grep -Fq 'notificationEnvFile' "${module}"
grep -Fq 'IBGSS_NOTIFICATION_ENV' "${module}"
grep -Fq 'ALLOWED_SERVICE = "ib-gateway"' "${helper}"
grep -Fq '"--no-deps"' "${helper}"
grep -Fq 'PORT_API = 4002' "${helper}"
grep -Fq 'PORT_RELAY = 4004' "${helper}"
grep -Fq 'execute_reserved_restart' "${helper}"
grep -Fq 'construct_declared_sender' "${helper}"
grep -Fq 'observed_at' "${helper}"
grep -Fq 'LISTEN_STATE = "0A"' "${helper}"
grep -Fq 'format_container_generation' "${helper}"
grep -Fq 'fsync_directory' "${helper}"
grep -Fq '/proc/1/stat' "${helper}"
grep -Fq '{{.ID}}' "${helper}"
grep -Fq 'Do not label' "${docs}"
grep -Fq '100.64.0.6:4002' "${compose}"
grep -Fq 'TRADING_MODE=paper' "${compose}"
grep -Fq '0fa2' "${compose}"
# Match the literal awk field expression in the declared healthcheck.
# shellcheck disable=SC2016
grep -Fq 'toupper($4)' "${compose}"

if grep -Fq "grep -qi ':0fa2 '" "${compose}"; then
  printf 'ib-gateway healthcheck must not naive-grep :0fa2 (matches TIME_WAIT/remote)\n' >&2
  exit 1
fi
if grep -Fq '100.64.0.6:4001' "${compose}"; then
  printf 'ib-gateway must not publish live 4001\n' >&2
  exit 1
fi
if grep -Eq 'docker-compose up|compose up -d' "${helper}"; then
  printf 'supervisor must not raw compose up\n' >&2
  exit 1
fi
if grep -Fq '_parse_docker_up_since' "${helper}"; then
  printf 'must not derive generation from rounded docker ps Status age\n' >&2
  exit 1
fi
if grep -Fq 'docker inspect' "${helper}"; then
  printf 'supervisor must not docker inspect\n' >&2
  exit 1
fi
if grep -Fq 'telegram://' "${module}" "${helper}" "${host}"; then
  printf 'must not invent a telegram endpoint\n' >&2
  exit 1
fi

printf 'HOSTD-58 ib-gateway session supervisor contract: OK\n'
