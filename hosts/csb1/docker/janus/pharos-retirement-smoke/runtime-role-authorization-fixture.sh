#!/usr/bin/env bash
# Isolated non-production role posture for the NIX-433 retirement smoke only.
# render-sidecars.sh accepts this contract only together with every retirement
# fixture guard (non-production contract, volume, scope, authority root and
# broker name), so production can never select it accidentally.

# shellcheck disable=SC2034
JANUS_ROLE_AUTHORIZATION_ARGS=(-e JANUS_ROLE_AUTHORIZATION_MODE=unsafe_disabled_dev)
