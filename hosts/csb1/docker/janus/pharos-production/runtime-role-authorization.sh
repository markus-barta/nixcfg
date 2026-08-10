#!/usr/bin/env bash
# Shared enforced role posture for csb1's production Janus subprocesses.
# The host path is private, durable NixOS state; containers see only the
# binding registry and value-free audit evidence, never a secret value.

JANUS_ROLE_HOST_ROOT=${JANUS_ROLE_HOST_ROOT:-/var/lib/janus-role-authorization-csb1/production}
readonly JANUS_ROLE_CONTAINER_ROOT=/var/lib/janus/role-authorization
readonly JANUS_ROLE_BINDINGS_ROOT=${JANUS_ROLE_CONTAINER_ROOT}/bindings
readonly JANUS_ROLE_AUDIT_FILE=${JANUS_ROLE_CONTAINER_ROOT}/audit.jsonl

# Consumed by scripts that source this contract.
# shellcheck disable=SC2034
readonly -a JANUS_ROLE_AUTHORIZATION_ARGS=(
  -e JANUS_ROLE_AUTHORIZATION_MODE=enforced
  -e "JANUS_ROLE_BINDINGS_ROOT=${JANUS_ROLE_BINDINGS_ROOT}"
  -e "JANUS_ROLE_AUDIT_FILE=${JANUS_ROLE_AUDIT_FILE}"
  -v "${JANUS_ROLE_HOST_ROOT}:${JANUS_ROLE_CONTAINER_ROOT}"
)
