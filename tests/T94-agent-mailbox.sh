#!/usr/bin/env bash
# OPS-272 — tailnet mailbox API and declared hsb0 security contract.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
module="$repo_root/modules/agent-mailbox"
nix_module="$module/default.nix"
host="$repo_root/hosts/hsb0/configuration.nix"
docs="$repo_root/hosts/hsb0/docs/IB-GATEWAY.md"
workflow="$repo_root/.github/workflows/check.yml"

node --test "$module"/*.test.mjs

grep -Fq '../../modules/agent-mailbox' "$host"
grep -Fq 'nixcfg.agentMailbox.enable = true' "$host"
grep -Fq 'services.agent-mailbox = config.nixcfg.agentMailbox.serviceSpec' "$host"
grep -Fq 'default = "100.64.0.6"' "$nix_module"
grep -Fq 'default = 8471' "$nix_module"
grep -Fq '"100.64.0.10" = "amy"' "$nix_module"
grep -Fq '"100.64.0.14" = "ops"' "$nix_module"
grep -Fq 'lib.all tailnetAddress peerAddresses' "$nix_module"
grep -Fq 'portOpen config.networking.firewall' "$nix_module"
grep -Fq 'lib.attrValues config.networking.firewall.interfaces' "$nix_module"
grep -Fq 'peerRules "-I"' "$nix_module"
# shellcheck disable=SC2016
grep -Fq -- '-i tailscale0 -s ${peer} -d ${cfg.listenAddress}' "$nix_module"
# shellcheck disable=SC2016
grep -Fq -- '-t raw -A agent-mailbox-peers -s ${peer} -j RETURN' "$nix_module"
grep -Fq -- '-t raw -A agent-mailbox-peers -j DROP' "$nix_module"
grep -Fq -- '-t raw -I PREROUTING -i tailscale0' "$nix_module"
grep -Fq -- '-t raw -D PREROUTING -i tailscale0' "$nix_module"
grep -Fq 'image = config.nixcfg.paperDeskExecutor.image' "$nix_module"
grep -Fq 'pull_policy = "never"' "$nix_module"
grep -Fq 'autoUpdate.excludeFromPull = [ "agent-mailbox" ]' "$nix_module"
grep -Fq 'network_mode = "host"' "$nix_module"
grep -Fq 'user = "1000:1000"' "$nix_module"
grep -Fq 'read_only = true' "$nix_module"
grep -Fq 'cap_drop = [ "ALL" ]' "$nix_module"
grep -Fq 'no-new-privileges:true' "$nix_module"
grep -Fq 'pids_limit = 64' "$nix_module"
grep -Fq 'mem_limit = "256m"' "$nix_module"
grep -Fq '/tmp:rw,noexec,nosuid,nodev,size=16m,mode=1777' "$nix_module"
# shellcheck disable=SC2016
grep -Fq '"${source}:/mailbox:ro"' "$nix_module"
# shellcheck disable=SC2016
grep -Fq '"${cfg.stateDir}:/state:rw"' "$nix_module"
grep -Fq '0700 1000 1000' "$nix_module"
grep -Fq 'traefik.enable=false' "$nix_module"
grep -Fq 'com.centurylinklabs.watchtower.enable=false' "$nix_module"
grep -Fq 'X-Mailbox-Policy' "$module/server.mjs"
grep -Fq '## Agent mailbox (OPS-272)' "$docs"
grep -Fq 'tests/T94-agent-mailbox.sh' "$workflow"

if grep -Eq 'docker[.]sock|extraGroups.*docker|age[.]secrets|ConditionPathExists|ports =|allowedTCPPorts =' "$nix_module"; then
  printf 'T94 failed: mailbox must not gain Docker/secrets or publish an interface-wide port\n' >&2
  exit 1
fi
if grep -Fq '8471' "$host"; then
  printf 'T94 failed: port 8471 must not appear in the host-wide firewall list\n' >&2
  exit 1
fi

printf 'T94 passed: mailbox API, IP identity, private storage and tailnet hardening are wired\n'
