#!/usr/bin/env bash
# The grep patterns are literal shell text from the module, not expansions.
# shellcheck disable=SC2016
# OPS-489 mbp2606 Trash purge contract: scope, age and schedule of the mbp2607 launchd agent.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mod="${repo}/hosts/mbp2607/mbp2606-trash-purge.nix"
home="${repo}/hosts/mbp2607/home.nix"

nix-instantiate --parse "${mod}" >/dev/null
grep -Fq './mbp2606-trash-purge.nix' "${home}"
grep -Fq 'launchd.agents.mbp2606-trash-purge' "${mod}"
grep -Fq 'T=/Users/mba/.Trash' "${mod}"
grep -Fq 'mba@mbp2606.lan' "${mod}"
grep -Fq 'HostKeyAlias=mbp2606.local' "${mod}"
grep -Fq 'BatchMode=yes' "${mod}"
grep -Fq '[ -L "$T" ]' "${mod}"
grep -Fq 'Weekday = 0;' "${mod}"
grep -Fq 'Hour = 4;' "${mod}"
grep -Fq 'Minute = 30;' "${mod}"
grep -Fq 'RunAtLoad = false;' "${mod}"
# Only direct children of the Trash, only older than 3 days, and nothing else is ever deleted.
[ "$(grep -cF 'find "$T" -mindepth 1 -maxdepth 1 -ctime +3' "${mod}")" -eq 2 ]
[ "$(grep -cF 'rm -rf' "${mod}")" -eq 1 ]
grep -Fq 'find "$T" -mindepth 1 -maxdepth 1 -ctime +3 -print0 | xargs -0 rm -rf' "${mod}"
if grep -nE 'rm -r[f]? +[^-]|ctime \+[012]([^0-9]|$)' "${mod}"; then
  echo "T116: unexpected delete in ${mod}" >&2
  exit 1
fi
echo "T116 ok"
