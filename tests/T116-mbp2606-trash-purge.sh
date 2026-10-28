#!/usr/bin/env bash
# The grep patterns are literal shell text from the module, not expansions.
# shellcheck disable=SC2016
# OPS-489 mbp2606 Trash purge contract. Evaluates the launchd agent from the module and runs its
# script against a sandbox: ssh runs the remote part locally, /Users/mba becomes a temp dir, find
# must be called on the pinned Trash (its -ctime +3 is simulated with -mtime +3, because ctime
# cannot be backdated), and rm refuses anything but a direct child of the Trash. Known harmful
# mutants of the script must fail the same checks.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mod="${repo}/hosts/mbp2607/mbp2606-trash-purge.nix"
home="${repo}/hosts/mbp2607/home.nix"

nix-instantiate --parse "${mod}" >/dev/null
grep -Fq './mbp2606-trash-purge.nix' "${home}"
# Only direct children of the Trash, only older than 3 days; one rm in the whole module.
[ "$(grep -cF 'find . -mindepth 1 -maxdepth 1 -ctime +3' "${mod}")" -eq 2 ]
[ "$(grep -cF 'rm -rf' "${mod}")" -eq 1 ]

# Resolved: the script pins the Trash with cd -P and compares pwd -P, and macOS temp dirs sit behind /var -> /private/var.
work=$(cd "$(mktemp -d)" && pwd -P)
trap 'chmod -R u+w "${work}" 2>/dev/null; rm -rf "${work}"' EXIT

# The agent as Home Manager gets it; writeShellScript is stubbed to hand back the script text.
nix-instantiate --eval --strict --json -E "
  (import ${mod} {
    config.home.homeDirectory = \"/home/t116\";
    pkgs.writeShellScript = _name: text: text;
  }).launchd.agents.mbp2606-trash-purge" >"${work}/agent.json"
python3 - "${work}/agent.json" "${work}/purge.sh" <<'PYTHON'
import json, sys
agent = json.load(open(sys.argv[1]))
cfg = agent["config"]
assert agent["enable"] is True, agent
assert cfg["StartCalendarInterval"] == [{"Weekday": 0, "Hour": 4, "Minute": 30}], cfg
assert cfg["RunAtLoad"] is False, cfg
assert cfg["StandardOutPath"] == "/home/t116/Library/Logs/mbp2606-trash-purge.log", cfg
assert set(cfg) == {"ProgramArguments", "StartCalendarInterval", "RunAtLoad", "StandardOutPath", "StandardErrorPath"}, sorted(cfg)
assert len(cfg["ProgramArguments"]) == 1, cfg["ProgramArguments"]
open(sys.argv[2], "w").write(cfg["ProgramArguments"][0])
PYTHON
script="${work}/purge.sh"
grep -Fq "/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=20 -o HostKeyAlias=mbp2606.local" "${script}"
grep -Fq "mba@mbp2606.lan 'bash -s'" "${script}"
[ "$(grep -cF '/usr/bin/ssh' "${script}")" -eq 1 ]
[ "$(grep -cF 'T=/Users/mba/.Trash' "${script}")" -eq 1 ]

# Stubs. VIOLATIONS collects every call outside the contract.
stubs="${work}/stubs"
mkdir -p "${stubs}"
real_find=$(command -v find)
real_rm=$(command -v rm)
cat >"${stubs}/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${T116_LOG}/ssh.args"
[ "${SSH_FAIL:-0}" = 1 ] && { echo "ssh: connect to host mbp2606.lan port 22: Operation timed out" >&2; exit 255; }
exec bash -s
STUB
cat >"${stubs}/find" <<STUB
#!/usr/bin/env bash
here=\$(pwd -P)
[ "\${here}" = "\${T116_TRASH}" ] && [ "\${1:-}" = . ] && [ "\${2:-}" = -mindepth ] && [ "\${3:-}" = 1 ] \
  && [ "\${4:-}" = -maxdepth ] && [ "\${5:-}" = 1 ] \
  || { echo "find in \${here}: \$*" >>"\${T116_LOG}/violations"; exit 97; }
args=()
while [ \$# -gt 0 ]; do
  case "\$1" in
    -ctime) [ "\${2:-}" = +3 ] || { echo "find age: \$1 \${2:-}" >>"\${T116_LOG}/violations"; exit 97; }
      args+=(-mtime +3); shift 2 ;;
    *) args+=("\$1"); shift ;;
  esac
done
exec ${real_find} "\${args[@]}"
STUB
cat >"${stubs}/rm" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in -*) continue ;; esac
  parent=\$(cd "\$(dirname -- "\$a")" && pwd -P)
  if [ "\${parent}" != "\${T116_TRASH}" ]; then echo "rm \$a (in \${parent})" >>"\${T116_LOG}/violations"; exit 97; fi
  if [ "\$(basename -- "\$a")" = "\${RM_FAIL_NAME:-}" ]; then echo "rm: \$a: Operation not permitted" >&2; exit 1; fi
done
exec ${real_rm} "\$@"
STUB
chmod +x "${stubs}"/*

old() { touch -h -t 202601010000 "$@"; }
# entries <dir>: the names in a directory, sorted, "|"-terminated.
entries() { find "$1" -mindepth 1 -maxdepth 1 | sed "s#^$1/##" | sort | tr '\n' '|'; }

# box <dir>: a fake /Users/mba with old and fresh Trash entries and old canaries outside the Trash.
box() {
  local b=$1
  mkdir -p "${b}/.Trash" "${b}/Documents"
  echo keep >"${b}/Documents/old-doc"
  old "${b}/Documents/old-doc"
  echo old >"${b}/.Trash/old file"
  echo dash >"${b}/.Trash/-rf"
  mkdir -p "${b}/.Trash/dir
with newline/sub"
  echo x >"${b}/.Trash/dir
with newline/sub/f"
  ln -s "${b}/Documents" "${b}/.Trash/link-to-documents"
  old "${b}/.Trash/old file" "${b}/.Trash/-rf" "${b}/.Trash/dir
with newline/sub/f" "${b}/.Trash/dir
with newline/sub" "${b}/.Trash/dir
with newline" "${b}/.Trash/link-to-documents"
  echo fresh >"${b}/.Trash/fresh"
}

# run <script> <box> [VAR=value ...]: runs the sandboxed script, sets RC and OUT.
run() {
  local s=$1 b=$2
  shift 2
  local log="${b}.log"
  mkdir -p "${log}"
  : >"${log}/violations"
  sed -e "s#/usr/bin/ssh#${stubs}/ssh#" -e "s#/Users/mba#${b}#g" "${s}" >"${b}.sh"
  RC=0
  OUT=$(env "$@" PATH="${stubs}:${PATH}" T116_LOG="${log}" T116_TRASH="$(cd "${b}" && pwd -P)/.Trash" bash "${b}.sh" 2>&1) || RC=$?
  VIOL=$(cat "${log}/violations")
}

# check <script> <tag>: 0 when every case behaves; prints the first broken case.
check() {
  local s=$1 t=$2 b
  b="${work}/${t}-ok"
  box "${b}"
  run "${s}" "${b}"
  [ "${RC}" = 0 ] || {
    echo "${t}: normal run rc=${RC}: ${OUT}"
    return 1
  }
  [ -z "${VIOL}" ] || {
    echo "${t}: ${VIOL}"
    return 1
  }
  [ "$(entries "${b}/.Trash")" = "fresh|" ] || {
    echo "${t}: trash left: $(entries "${b}/.Trash")"
    return 1
  }
  [ -f "${b}/Documents/old-doc" ] || {
    echo "${t}: deleted outside the Trash"
    return 1
  }
  case "${OUT}" in *"selected=4 failed=0 rc=0 left=1 "*) ;; *)
    echo "${t}: log line: ${OUT}"
    return 1
    ;;
  esac
  grep -Fxq -- "-o BatchMode=yes -o ConnectTimeout=20 -o HostKeyAlias=mbp2606.local mba@mbp2606.lan bash -s" "${b}.log/ssh.args" ||
    {
      echo "${t}: ssh args: $(cat "${b}.log/ssh.args")"
      return 1
    }

  b="${work}/${t}-link"
  mkdir -p "${b}/Documents"
  echo keep >"${b}/Documents/old-doc"
  old "${b}/Documents/old-doc"
  ln -s "${b}/Documents" "${b}/.Trash"
  run "${s}" "${b}"
  [ "${RC}" = 3 ] && [ -f "${b}/Documents/old-doc" ] && [ -z "${VIOL}" ] ||
    {
      echo "${t}: symlinked Trash: rc=${RC} ${VIOL} ${OUT}"
      return 1
    }

  b="${work}/${t}-ssh"
  box "${b}"
  run "${s}" "${b}" SSH_FAIL=1
  [ "${RC}" = 255 ] && [ -f "${b}/.Trash/old file" ] || {
    echo "${t}: ssh failure: rc=${RC} ${OUT}"
    return 1
  }

  b="${work}/${t}-rm"
  box "${b}"
  run "${s}" "${b}" RM_FAIL_NAME="old file"
  [ "${RC}" != 0 ] && [ -z "${VIOL}" ] || {
    echo "${t}: failed rm: rc=${RC} ${VIOL}"
    return 1
  }
  case "${OUT}" in *"failed=1 rc=1 "*) ;; *)
    echo "${t}: failed rm log: ${OUT}"
    return 1
    ;;
  esac
  [ "$(entries "${b}/.Trash")" = "fresh|old file|" ] || {
    echo "${t}: failed rm left: $(entries "${b}/.Trash")"
    return 1
  }
}

check "${script}" agent || exit 1

# Harmful mutants must be caught by the same checks.
mutant() {
  local tag=$1 expr=$2 m="${work}/mutant-$1.sh"
  sed -e "${expr}" "${script}" >"${m}"
  if cmp -s "${m}" "${script}"; then
    echo "T116: mutant ${tag} did not apply" >&2
    exit 1
  fi
  if check "${m}" "m-${tag}" >/dev/null; then
    echo "T116: mutant ${tag} passed the checks" >&2
    exit 1
  fi
}
mutant documents '/^T=\/Users\/mba\/.Trash$/a\
T=/Users/mba/Documents'
mutant exit0 's/exit \$rc/exit 0/'
mutant age0 's/-ctime +3/-ctime +0/'
mutant unpinned 's/failed=\$(find \. /failed=$(find "$T" /'
mutant depth 's/-maxdepth 1 -ctime +3 !/-ctime +3 !/'
mutant unchecked 's/ || \[ -L "\$T" \]//;/pwd -P)" != "\$T"/d'
echo "T116 ok"
