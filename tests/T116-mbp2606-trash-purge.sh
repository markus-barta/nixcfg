#!/usr/bin/env bash
# The grep patterns are literal shell text from the module, not expansions.
# shellcheck disable=SC2016
# OPS-489 mbp2606 Trash purge contract. Evaluates the launchd agent from the module and runs its
# script against a sandbox: ssh runs the remote part locally, /Users/mba becomes a temp dir,
# `date +%s` is the test's clock, the selection must be a find pinned to the Trash (its -ctime +3
# is simulated with -mtime +3, because ctime cannot be backdated), rm refuses anything but a
# 10-digit batch inside the pinned hold, and mv can refill a name right before the move (Put Back,
# then a fresh item trashed under the same name). Documents must end every case unchanged. Known
# harmful mutants of the script must fail the same checks.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mod="${repo}/hosts/mbp2607/mbp2606-trash-purge.nix"
home="${repo}/hosts/mbp2607/home.nix"

nix-instantiate --parse "${mod}" >/dev/null
grep -Fq './mbp2606-trash-purge.nix' "${home}"
# Only direct children of the Trash older than 3 days are held, a batch is held 3 days, and the
# module has one rm -rf.
[ "$(grep -cF -- '-mindepth 1 -maxdepth 1 -ctime +3' "${mod}")" -eq 1 ]
[ "$(grep -cF -- '-ctime' "${mod}")" -eq 1 ]
[ "$(grep -cF 'rm -rf' "${mod}")" -eq 1 ]
grep -Fxq '    HOLD_S=259200' "${mod}"

# Resolved: the script pins with cd -P and compares pwd -P, and macOS temp dirs sit behind /var -> /private/var.
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
log = "/home/t116/Library/Logs/mbp2606-trash-purge.log"
assert agent["enable"] is True, agent
assert cfg["StartCalendarInterval"] == [{"Weekday": 0, "Hour": 4, "Minute": 30}], cfg
assert cfg["RunAtLoad"] is False, cfg
assert cfg["StandardOutPath"] == log and cfg["StandardErrorPath"] == log, cfg
assert set(cfg) == {"ProgramArguments", "StartCalendarInterval", "RunAtLoad", "StandardOutPath", "StandardErrorPath"}, sorted(cfg)
assert len(cfg["ProgramArguments"]) == 1, cfg["ProgramArguments"]
open(sys.argv[2], "w").write(cfg["ProgramArguments"][0])
PYTHON
script="${work}/purge.sh"
grep -Fq "/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=20 -o HostKeyAlias=mbp2606.local" "${script}"
grep -Fq "mba@mbp2606.lan 'bash -s'" "${script}"
[ "$(grep -cF '/usr/bin/ssh' "${script}")" -eq 1 ]
[ "$(grep -cF 'T=/Users/mba/.Trash' "${script}")" -eq 1 ]

# Stubs. Every call outside the contract lands in violations and fails with 97.
stubs="${work}/stubs"
mkdir -p "${stubs}"
real_find=$(command -v find)
real_rm=$(command -v rm)
real_mv=$(command -v mv)
real_date=$(command -v date)
# ssh: runs the remote part locally; T116_PREAMBLE is prepended to it (used to swap directories).
cat >"${stubs}/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${T116_LOG}/ssh.args"
[ "${SSH_FAIL:-0}" = 1 ] && { echo "ssh: connect to host mbp2606.lan port 22: Operation timed out" >&2; exit 255; }
{ printf '%s\n' "${T116_PREAMBLE:-}"; cat; } | bash -s
STUB
cat >"${stubs}/date" <<STUB
#!/usr/bin/env bash
if [ "\$*" = +%s ] && [ -n "\${T116_NOW:-}" ]; then echo "\${T116_NOW}"; exit 0; fi
exec ${real_date} "\$@"
STUB
# find: the selection (the only -ctime) runs in the pinned Trash on its direct children, older
# than 3 days; no other find may act on what it finds.
cat >"${stubs}/find" <<STUB
#!/usr/bin/env bash
here=\$(pwd -P)
case " \$* " in
  *" -ctime "*)
    [ "\${here}" = "\${T116_TRASH}" ] && [ "\${1:-}" = . ] && [ "\${2:-}" = -mindepth ] && [ "\${3:-}" = 1 ] \
      && [ "\${4:-}" = -maxdepth ] && [ "\${5:-}" = 1 ] \
      || { echo "find in \${here}: \$*" >>"\${T116_LOG}/violations"; exit 97; }
    ;;
  *" -exec "* | *" -execdir "* | *" -ok "* | *" -delete "*)
    echo "find acts outside the selection: \$*" >>"\${T116_LOG}/violations"; exit 97
    ;;
esac
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
# rm: only a 10-digit batch directly inside the pinned hold; RM_FAIL_FIRST fails the first rm -rf.
cat >"${stubs}/rm" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in -*) continue ;; esac
  parent=\$(cd "\$(dirname -- "\$a")" && pwd -P)
  case "\${parent}|\$(basename -- "\$a")" in
    "\${T116_TRASH}/.ops489-hold|"[1-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *) echo "rm \$a (in \${parent})" >>"\${T116_LOG}/violations"; exit 97 ;;
  esac
done
if [ "\${RM_FAIL_FIRST:-0}" = 1 ] && [ "\${1:-}" = -rf ] && [ ! -e "\${T116_LOG}/rm-failed" ]; then
  : >"\${T116_LOG}/rm-failed"; echo "rm: Operation not permitted" >&2; exit 1
fi
exec ${real_rm} "\$@"
STUB
# mv: with RACE_NAME, the move of that entry finds its name refilled: the old item was put back
# (to Documents/put-back) and a fresh one trashed under the same name.
cat >"${stubs}/mv" <<STUB
#!/usr/bin/env bash
src=""
for a in "\$@"; do case "\$a" in -*) ;; *) src=\$a; break ;; esac; done
if [ -n "\${RACE_NAME:-}" ] && [ "\$(basename -- "\${src}")" = "\${RACE_NAME}" ] && [ ! -e "\${T116_LOG}/raced" ]; then
  : >"\${T116_LOG}/raced"
  ${real_mv} -- "\${src}" "\${T116_TRASH}/../Documents/put-back"
  echo fresh >"\${src}"
fi
exec ${real_mv} "\$@"
STUB
chmod +x "${stubs}"/*

old() { touch -h -t 202601010000 "$@"; }
# entries <dir>: the names in a directory, sorted, "|"-terminated.
entries() { find "$1" -mindepth 1 -maxdepth 1 | sed "s#^$1/##" | LC_ALL=C sort | tr '\n' '|'; }
# count <dir>: its direct children, NUL-counted (names may hold newlines).
count() { find "$1" -mindepth 1 -maxdepth 1 -print0 | tr -dc '\000' | wc -c | tr -d ' '; }

# box <dir>: a fake /Users/mba with old and fresh Trash entries and old canaries in Documents,
# one named like a batch.
box() {
  local b=$1
  mkdir -p "${b}/.Trash" "${b}/Documents/1600000000"
  echo keep >"${b}/Documents/old-doc"
  echo keep >"${b}/Documents/1600000000/keep"
  old "${b}/Documents/old-doc" "${b}/Documents/1600000000/keep" "${b}/Documents/1600000000"
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
docs="1600000000|old-doc|"

# run <script> <box> [VAR=value...]: the agent's script with /Users/mba -> box and the stubbed ssh.
run() {
  local s=$1 b=$2 log
  shift 2
  log="${b}.log"
  mkdir -p "${log}"
  : >"${log}/violations"
  sed -e "s#/usr/bin/ssh#${stubs}/ssh#" -e "s#/Users/mba#${b}#g" "${s}" >"${b}.sh"
  RC=0
  OUT=$(env "$@" PATH="${stubs}:${PATH}" T116_LOG="${log}" T116_TRASH="${b}/.Trash" bash "${b}.sh" 2>&1) || RC=$?
  VIOL=$(cat "${log}/violations")
}

# expect <label> <box> <rc> <log fragment> [documents]: the last run's rc and log line, no
# violation, and Documents exactly as before.
expect() {
  [ "${RC}" = "$3" ] && [ -z "${VIOL}" ] || {
    echo "$1: rc=${RC} ${VIOL} ${OUT}"
    return 1
  }
  case "${OUT}" in *"$4"*) ;; *)
    echo "$1: log: ${OUT}"
    return 1
    ;;
  esac
  [ "$(entries "$2/Documents")" = "${5:-${docs}}" ] && [ -f "$2/Documents/1600000000/keep" ] || {
    echo "$1: Documents changed: $(entries "$2/Documents")"
    return 1
  }
}

# Directories swapped for a symlink to Documents right before the script changes into them.
swap_trash='cd() { case "$1|${2:-}" in "-P|/"*) mv "$2" "$2.real" && ln -s "$(dirname "$2")/Documents" "$2" ;; esac; builtin cd "$@"; }'
swap_hold='cd() { case "$1|${2:-}" in "-P|.ops489-hold") mv .ops489-hold .ops489-hold.real && ln -s ../Documents .ops489-hold ;; esac; builtin cd "$@"; }'

# check <script> <tag>: 0 when every case behaves; prints the first broken case.
check() {
  local s=$1 t=$2 b h
  local n0=1800000000
  local n1=$((n0 + 604800))

  # Run 1 holds the four old entries and deletes nothing.
  b="${work}/${t}-ok"
  h="${b}/.Trash/.ops489-hold"
  box "${b}"
  run "${s}" "${b}" T116_NOW="${n0}"
  expect "${t}: run 1" "${b}" 0 "held=4 purged=0 batches=0 failed=0 rc=0 left=1 " || return 1
  [ "$(entries "${b}/.Trash")" = ".ops489-hold|fresh|" ] && [ "$(count "${h}/${n0}")" = 4 ] &&
    [ -f "${h}/${n0}/old file" ] && [ -L "${h}/${n0}/link-to-documents" ] || {
    echo "${t}: run 1 left the Trash as $(entries "${b}/.Trash") and the hold as $(entries "${h}")"
    return 1
  }
  grep -Fxq -- "-o BatchMode=yes -o ConnectTimeout=20 -o HostKeyAlias=mbp2606.local mba@mbp2606.lan bash -s" "${b}.log/ssh.args" || {
    echo "${t}: ssh args: $(cat "${b}.log/ssh.args")"
    return 1
  }
  # Run 2, a week later: that batch goes (the symlink in it, not Documents), and fresh, old by now, is held.
  old "${b}/.Trash/fresh"
  run "${s}" "${b}" T116_NOW="${n1}"
  expect "${t}: run 2" "${b}" 0 "held=1 purged=4 batches=1 failed=0 rc=0 left=0 " || return 1
  [ "$(entries "${h}")" = "${n1}|" ] && [ -f "${h}/${n1}/fresh" ] || {
    echo "${t}: run 2 left the hold as $(entries "${h}")"
    return 1
  }
  # Run 3, the same day: this week's batch stays.
  run "${s}" "${b}" T116_NOW="$((n1 + 60))"
  expect "${t}: run 3" "${b}" 0 "held=0 purged=0 batches=0 failed=0 rc=0 left=0 " || return 1
  [ -f "${h}/${n1}/fresh" ] || {
    echo "${t}: run 3 deleted a batch held for 60 s"
    return 1
  }

  # A fresh item takes an old entry's name right before the move: it is held, not deleted.
  b="${work}/${t}-race"
  h="${b}/.Trash/.ops489-hold"
  box "${b}"
  run "${s}" "${b}" T116_NOW="${n0}" RACE_NAME="old file"
  expect "${t}: race" "${b}" 0 "held=4 purged=0 batches=0 failed=0 rc=0 left=1 " "1600000000|old-doc|put-back|" || return 1
  [ "$(cat "${h}/${n0}/old file")" = fresh ] && [ "$(cat "${b}/Documents/put-back")" = old ] || {
    echo "${t}: race: the fresh entry under the old name was not held"
    return 1
  }

  # Leftovers in the hold: an old batch from a crashed run goes, so does an old batch-named
  # symlink (the link only); a younger batch and anything not named like a batch stay.
  b="${work}/${t}-left"
  h="${b}/.Trash/.ops489-hold"
  box "${b}"
  mkdir -p "${h}/$((n0 - 345600))" "${h}/$((n0 - 86400))" "${h}/notes" "${h}/123456789"
  echo x >"${h}/$((n0 - 345600))/crashed"
  echo x >"${h}/$((n0 - 86400))/recent"
  echo x >"${h}/notes/n"
  echo x >"${h}/123456789/n"
  ln -s "${b}/Documents" "${h}/1700000000"
  run "${s}" "${b}" T116_NOW="${n0}"
  expect "${t}: leftovers" "${b}" 0 "held=4 purged=1 batches=2 failed=0 rc=0 left=1 " || return 1
  [ "$(entries "${h}")" = "123456789|$((n0 - 86400))|${n0}|notes|" ] || {
    echo "${t}: leftovers: the hold is $(entries "${h}")"
    return 1
  }

  b="${work}/${t}-link"
  mkdir -p "${b}/Documents/1600000000"
  echo keep >"${b}/Documents/old-doc"
  echo keep >"${b}/Documents/1600000000/keep"
  old "${b}/Documents/old-doc" "${b}/Documents/1600000000"
  ln -s "${b}/Documents" "${b}/.Trash"
  run "${s}" "${b}" T116_NOW="${n0}"
  expect "${t}: symlinked Trash" "${b}" 3 "no trash dir" || return 1

  b="${work}/${t}-swap"
  box "${b}"
  run "${s}" "${b}" T116_NOW="${n0}" T116_PREAMBLE="${swap_trash}"
  expect "${t}: Trash swapped before cd" "${b}" 3 "trash dir resolved elsewhere" || return 1
  [ -f "${b}/.Trash.real/old file" ] || {
    echo "${t}: Trash swapped before cd: the Trash was touched"
    return 1
  }

  b="${work}/${t}-holdlink"
  box "${b}"
  ln -s ../Documents "${b}/.Trash/.ops489-hold"
  run "${s}" "${b}" T116_NOW="${n0}"
  expect "${t}: symlinked hold" "${b}" 3 "is a symlink" || return 1
  [ -f "${b}/.Trash/old file" ] || {
    echo "${t}: symlinked hold: the Trash was touched"
    return 1
  }

  b="${work}/${t}-holdswap"
  box "${b}"
  mkdir "${b}/.Trash/.ops489-hold"
  run "${s}" "${b}" T116_NOW="${n0}" T116_PREAMBLE="${swap_hold}"
  expect "${t}: hold swapped before cd" "${b}" 3 "hold dir resolved elsewhere" || return 1

  b="${work}/${t}-ssh"
  box "${b}"
  run "${s}" "${b}" T116_NOW="${n0}" SSH_FAIL=1
  [ "${RC}" = 255 ] && [ -f "${b}/.Trash/old file" ] || {
    echo "${t}: ssh failure: rc=${RC} ${OUT}"
    return 1
  }

  b="${work}/${t}-rm"
  h="${b}/.Trash/.ops489-hold"
  box "${b}"
  mkdir -p "${h}/$((n0 - 345600))"
  echo x >"${h}/$((n0 - 345600))/crashed"
  run "${s}" "${b}" T116_NOW="${n0}" RM_FAIL_FIRST=1
  expect "${t}: failed rm" "${b}" 1 "held=4 purged=0 batches=0 failed=1 rc=1 left=1 " || return 1
  [ -f "${h}/$((n0 - 345600))/crashed" ] || {
    echo "${t}: failed rm: the batch is gone"
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
mutant hold0 's/^HOLD_S=259200$/HOLD_S=0/'
mutant unpinned 's/^find \. -mindepth 1 -maxdepth 1 -ctime +3/find "$T" -mindepth 1 -maxdepth 1 -ctime +3/'
mutant depth 's/-maxdepth 1 -ctime +3 !/-ctime +3 !/'
mutant unchecked 's/ || \[ -L "\$T" \]//;/trash dir resolved elsewhere/d'
mutant nopwd '/trash dir resolved elsewhere/d'
mutant noholdpwd '/hold dir resolved elsewhere/d'
mutant holdunchecked '/is a symlink"; exit 3; fi$/d;/hold dir resolved elsewhere/d'
mutant anyname '/^  case "\$b" in (\[1-9\]/d'
mutant nohold 's/-exec mv -n -- {} "\$H\/\$now\/" \\;/-exec rm -rf -- {} \\;/'
echo "T116 ok"
