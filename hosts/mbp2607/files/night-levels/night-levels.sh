#!/bin/bash
# OPS night protocol (Markus 2026-10-11): mbp2607 + mbp2606 levels every 180 s; writes changes to AEON-LEAD's host-level.sh.
# WEEKEND MODE (Markus 2026-10-11 08:30 via AEON-LEAD, until Mon 2026-10-12 07:00): RED at load>${RED_LOAD:-28}; set RED_LOAD=22 for the normal night protocol.
# GREEN load<=14 (<=12 after YELLOW/RED), mem>=40%, disk>=100GB, swap<=4GB (or <60% mem) | RED load>22, mem<25%, disk<50GB, swap>8GB with mem<40%, throttled, unreachable.
# OPS-595: vendored into nixcfg; launchd sets NL_MAC_HEALTH / NL_UNGUARDED to store paths; SSH server-alive probes bound hung connections to ~30 s.
S=${NL_MAC_HEALTH:-$HOME/.local/share/ops-qa/mac-health.sh}; HL=/Users/markus/.aeon/lead/aeon/host-level.sh
p7=$(awk '$1=="mbp2607"{print $2}' /Users/markus/.aeon/lead/aeon/HOST-LEVEL 2>/dev/null); p7=${p7:-GREEN}
p6=$(awk '$1=="mbp2606"{print $2}' /Users/markus/.aeon/lead/aeon/HOST-LEVEL 2>/dev/null); p6=${p6:-GREEN}
lvl_for(){ local L="$1" last="$2"; case "$L" in *cores=*) ;; *) echo RED; return;; esac
  local df mf sw l1 th gl=14
  df=$(echo "$L" | sed -E 's/.*data_free_gb=([0-9]+).*/\1/'); mf=$(echo "$L" | sed -E 's/.*mem_free_pct=([0-9]+).*/\1/')
  sw=$(echo "$L" | sed -E 's/.*swap_used_mb=([0-9]+).*/\1/'); l1=$(echo "$L" | sed -E 's/.*load="([0-9.]+).*/\1/')
  th=$(echo "$L" | sed -E 's/.*cpu_speed_limit=([0-9]+).*/\1/'); [ "$last" != GREEN ] && gl=12
  local bp bs; bp=$(echo "$L" | sed -nE 's/.*batt_pct=(-?[0-9]+).*/\1/p'); bs=$(echo "$L" | sed -nE 's/.*batt_state=([a-z]+).*/\1/p')
  # Battery: falling charge counts even when pmset says AC (weak charger under load, 2026-10-11 mbp2606).
  local hn pf pb falling=0; hn=${L%% *}; pf="$HOME/.local/share/ops-qa/state/batt-$hn"; mkdir -p "${pf%/*}"
  # 2026-11-02 (Markus via LEAD, OPS-535): "i have 18 cores. load 100-135 seems fine". mbp2607 only: load up to 135 blocks nothing,
  # with no lower recovery threshold. mbp2606 and its guard keep RED_LOAD and the 14/12 limits.
  local rl=${RED_LOAD:-28}; [ "$hn" = mbp2607 ] && { rl=135; gl=135; }
  pb=$(cat "$pf" 2>/dev/null); [ "${bp:--1}" -ge 0 ] && echo "$bp" > "$pf"
  { [ "${bs:-none}" = discharging ] || { [ -n "$pb" ] && [ "${bp:--1}" -ge 0 ] && [ "$bp" -lt "$pb" ]; }; } && falling=1
  if [ $falling = 1 ] && [ "${bp:--1}" -ge 0 ] && [ "$bp" -lt 15 ]; then echo RED; return; fi
  if [ $falling = 1 ] && [ "${bp:--1}" -ge 0 ] && [ "$bp" -lt 40 ]; then echo YELLOW; return; fi
  # 2026-10-19 (LEAD ask): swap >8 GB is RED only while memory is also tight (<40 % free); otherwise it falls to YELLOW below
  # (still blocks mbp2606 remote runs). mbp2606 12:40: swap 9.0 GB residual, mem 50 % free, load ~4 -> false RED.
  local sm=45; [ "$last" != GREEN ] && sm=55  # swap-rule hysteresis (see the YELLOW branch)
  # 2026-10-21 (LEAD, r138 capacity): residual swap alone no longer holds YELLOW. mbp2606 kept 31.8 GB of another user's
  # idle swap at 47-49 % free and could never leave YELLOW (needs >55 %). The swap rule now also needs ACTIVE swapping:
  # swapouts grew by more than 4096 pages (64 MiB) since the last tick, or the counter is unknown/reset (conservative).
  # The free-memory limits (YELLOW <40 %, RED <25 %) and the RED swap rule are unchanged.
  local so sp sf act=1; so=$(echo "$L" | sed -nE 's/.*swapouts=(-?[0-9]+).*/\1/p'); sf="$HOME/.local/share/ops-qa/state/swapouts-$hn"
  sp=$(cat "$sf" 2>/dev/null); [ "${so:--1}" -ge 0 ] && echo "$so" > "$sf"
  if [ "${so:--1}" -ge 0 ] && [ -n "$sp" ] && [ "$so" -ge "$sp" ] && [ $((so - sp)) -le 4096 ]; then act=0; fi
  if [ "$df" -lt 50 ] || [ "$mf" -lt 25 ] || { [ "$sw" -gt 8192 ] && [ "$mf" -lt 40 ]; } || awk "BEGIN{exit !($l1 > $rl)}" || [ "$th" -lt 100 ]; then echo RED
  # 2026-10-18: swap >4 GB alone is YELLOW only while memory is also tight (<60 % free). macOS keeps residual swap for hours
  # after a load peak (mbp2606 17:29Z: swap 4.6 GB, mem 79 % free, load 1.3, pool idle -> false YELLOW stopped all starts).
  # 2026-10-20 (LEAD: AEON-1460/AIT-395 waited): 60 -> 50. mbp2606 07:40: swap 17 GB residual, mem 57 % free, load 1.3,
  # pool idle -> false YELLOW for 5 h blocked every remote start. RED limits unchanged.
  # 2026-10-21 (LEAD): hysteresis on the swap rule. mbp2606 sat at 49-51 % free with 32 GB residual swap (another user's
  # idle session) and flapped YELLOW/GREEN every few minutes, restarting LEAD's start hold each time. Enter YELLOW below
  # 45 % free (from GREEN), leave only above 55 % (from YELLOW/RED). Other YELLOW/RED limits unchanged.
  elif [ "$df" -lt 100 ] || [ "$mf" -lt 40 ] || { [ "$sw" -gt 4096 ] && [ "$mf" -lt $sm ] && [ "$act" = 1 ]; } || awk "BEGIN{exit !($l1 > $gl)}"; then echo YELLOW; else echo GREEN; fi; }
while true; do
  A=$($S 2>&1); obs7=$(date +%s); B=$(ssh -o ConnectTimeout=8 -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -o HostKeyAlias=mbp2606.local mba@100.64.0.13 'bash -s' < $S 2>&1 | tail -1)
  l7=$(lvl_for "$A" "$p7"); l6=$(lvl_for "$B" "$p6")
  # Hold (2026-10-12): ~mba/.hold-mbp2606 means the machine is reserved (e.g. Mailina gaming); report RED until released.
  ssh -o ConnectTimeout=8 -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -o HostKeyAlias=mbp2606.local mba@100.64.0.13 "test -e .hold-mbp2606" </dev/null 2>/dev/null && l6=RED
  # Hold (2026-10-31): ~/.hold-mbp2607 reserves this Mac (e.g. gaming); same meaning. The 10-31 20:04 leak: a local ci-static ran here because mbp2607 still read GREEN.
  [ -e "$HOME/.hold-mbp2607" ] && l7=RED
  # OPS-300: mirror the mbp2606 policy for its host-side remote-run guard (~mba/.aeon-remote-policy; stale after 900 s).
  if [ -f /Users/markus/.aeon/lead/aeon/WEEKEND-MODE ]; then ml=${RED_LOAD:-28}; [ "$l6" = RED ] && bl=1 || bl=0; else ml=12; [ "$l6" = GREEN ] && bl=0 || bl=1; fi
  # OPS-341 ramp override (2026-10-16, time-boxed): state/mbp2606-ramp-override = "maxload=N until=EPOCH". While valid, the
  # remote-run guard gets that maxload and blocks only on RED or mem < 40 % (a load-only YELLOW is the ramp itself). The
  # host level reported to LEAD is unchanged, so LEAD's pool still sees YELLOW and backs off. Expired or absent = normal.
  ro=$HOME/.local/share/ops-qa/state/mbp2606-ramp-override
  if [ -f "$ro" ]; then read -r rkv ukv < "$ro"; rml=${rkv#maxload=}; ru=${ukv#until=}
    if [[ "$rml" =~ ^[0-9]+$ ]] && [[ "$ru" =~ ^[0-9]+$ ]] && [ "$(date +%s)" -lt "$ru" ]; then
      mf6=$(echo "$B" | sed -nE 's/.*mem_free_pct=([0-9]+).*/\1/p'); ml=$rml
      if [ "$l6" = RED ] || [ "${mf6:-0}" -lt 40 ]; then bl=1; else bl=0; fi
    fi
  fi
  # OPS-385 (b), AEON-1490 (Markus go 2026-10-18 via AEON-LEAD): a remote-run budget per level instead of a flat 1.
  # GREEN + load<=8 + mem>=50 % -> 3; other GREEN -> 2; YELLOW (not blocked, e.g. ramp override) -> 1; blocked -> 0.
  # Three or more busy pool slots (4 x 4 CPU) cap it at 1, two cap it at 2. maxruns is written to ~/.aeon-remote-maxruns (see below).
  ps6=$(ssh -o ConnectTimeout=8 -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -o HostKeyAlias=mbp2606.local ci@100.64.0.13 '$HOME/.nix-profile/bin/aeon-builder status 2>/dev/null | grep -E "^(mode|slots):"' </dev/null 2>/dev/null)
  busy6=$(echo "$ps6" | sed -nE 's/^slots: +([0-9]+)\/.*/\1/p'); busy6=${busy6:-4}
  l1n=$(echo "$B" | sed -nE 's/.*load="([0-9.]+).*/\1/p'); mfn=$(echo "$B" | sed -nE 's/.*mem_free_pct=([0-9]+).*/\1/p')
  mr=0
  if [ "$bl" = 0 ]; then
    # 2026-10-23 19:3x (LEAD + OPS): three concurrent static (st-*) runs admitted at load <= 8 drove mbp2606 to load 35
    # at 19:26. Now 3 runs only when GREEN, load <= 4, mem >= 50 %, at most 1 pool slot busy and NO static run active;
    # otherwise 2. An unreadable static count counts as active (conservative).
    # Only a successful enumeration counts: the remote prints "st=N" only when the run directory exists and find succeeded.
    st6r=$(ssh -o ConnectTimeout=8 -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -o HostKeyAlias=mbp2606.local mba@100.64.0.13 'bash -s' 2>/dev/null <<'STEOF'
set -o pipefail
d=$HOME/ci.noindex/aeon-runs
[ -d "$d" ] || exit 1
n=$(find "$d" -mindepth 1 -maxdepth 1 -type d -name 'st-*' | wc -l) || exit 1
echo "st=$((n + 0))"
STEOF
); strc=$?
    st6=1
    if [ "$strc" = 0 ]; then case "$st6r" in st= | st=*[!0-9]*) ;; st=*) st6=${st6r#st=} ;; esac; fi
    if [ "$l6" = GREEN ]; then mr=2; awk "BEGIN{exit !(${l1n:-99} <= 4)}" && [ "${mfn:-0}" -ge 50 ] && [ "$busy6" -le 1 ] && [ "$st6" -eq 0 ] && mr=3; else mr=1; fi
    # 2026-10-18 14:55Z (LEAD: follow real headroom; 18 cores, pool slot = 4 CPU): 3+ busy slots cap at 1, 2 busy cap at 2.
    [ "$busy6" -ge 3 ] && [ "$mr" -gt 1 ] && mr=1
    [ "$busy6" -eq 2 ] && [ "$mr" -gt 2 ] && mr=2
    # 2026-10-22 02:2x (OPS): heavy swap on mbp2606 (>32 GB) with <50 % free caps concurrent remote runs at 1. The night's
    # RED flips (01:17, 01:32, 02:03) came from swap bursts while 2 runs were admitted; swap rose 32 -> 38 GB.
    sw6n=$(echo "$B" | sed -nE 's/.*swap_used_mb=([0-9]+).*/\1/p'); [ "${sw6n:-0}" -gt 32768 ] && [ "${mfn:-0}" -lt 50 ] && [ "$mr" -gt 1 ] && mr=1
    # LEAD 2026-11-02 15:4x on Markus's "no waiting": state/mbp2606-maxruns-override = "maxruns=N", no time box, until Markus says otherwise. Delete the file to end it.
    # Inside bl=0 on purpose: a hold, RED or any other block still writes 0. It sets only this number; policy, level and maxload stay as computed.
    mro=$(cat "$HOME/.local/share/ops-qa/state/mbp2606-maxruns-override" 2>/dev/null); mre='^maxruns=([1-9])$'; [[ "$mro" =~ $mre ]] && mr=${BASH_REMATCH[1]}
  fi
  # 2026-10-18 12:15Z: the deployed aeon-remote-guard accepts ONLY 'block= maxload= level= epoch=' (one line); an extra
  # maxruns field made it treat the policy as malformed and ignore block=1 + maxload. maxruns goes to its own file until
  # the guard enforces it host-side (OPS-385, LEAD design 12:10Z).
  ts=$(date +%s)
  if printf 'block=%s maxload=%s level=%s epoch=%s\nmaxruns=%s epoch=%s\n' "$bl" "$ml" "$l6" "$ts" "$mr" "$ts" | ssh -o ConnectTimeout=8 -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -o HostKeyAlias=mbp2606.local mba@100.64.0.13 "sh -c 'IFS= read -r p && IFS= read -r m && printf \"%s\\n\" \"\$p\" > .aeon-remote-policy.tmp && printf \"%s\\n\" \"\$m\" > .aeon-remote-maxruns.tmp && mv -f .aeon-remote-policy.tmp .aeon-remote-policy && mv -f .aeon-remote-maxruns.tmp .aeon-remote-maxruns'" 2>/dev/null; then pw=ok; else [ "${pw:-ok}" = ok ] && echo "$(date +%T) WARN policy write to mbp2606 failed (guard falls back to maxload 12 after 900 s)"; pw=fail; fi
  # OPS-300 follow-up (Markus 2026-10-11 "Detect + report"): heavy mba test runs outside LEAD's guarded run dirs.
  U=$(ssh -o ConnectTimeout=8 -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -o HostKeyAlias=mbp2606.local mba@100.64.0.13 'bash -s' < ${NL_UNGUARDED:-$HOME/.local/share/ops-qa/mbp2606-unguarded.sh} 2>/dev/null)
  if [ -n "$U" ]; then newp=$(echo "$U" | cut -d'|' -f1 | sort | comm -23 - <(printf '%s\n' $seen_unguarded | sort)); [ -n "$newp" ] && echo "$(date +%T) UNGUARDED on mbp2606 (load $(echo "$B" | sed -E 's/.*load="([0-9.]+).*/\1/')): $(echo "$U" | cut -d'|' -f2 | sort | uniq -c | tr '\n' ';')"; seen_unguarded=$(echo "$U" | cut -d'|' -f1 | tr '\n' ' '); else seen_unguarded=""; fi
  # OPS-321 (2026-10-13): a paused mbp2606 pool went unnoticed 1.5 h; report the transition once.
  pm=$(echo "$ps6" | grep "^mode:")  # OPS-385: reuses the status read above
  case "$pm" in *paused*) [ "$pool_paused" != 1 ] && echo "$(date +%T) POOL PAUSED on mbp2606: $(echo "$pm" | sed -E 's/^mode: +//' | cut -c1-200)"; pool_paused=1;; *mode:*) [ "$pool_paused" = 1 ] && echo "$(date +%T) pool on mbp2606 no longer paused: $(echo "$pm" | sed -E 's/^mode: +//' | cut -c1-80)"; pool_paused=0;; esac
  if [ "$l7" != "$p7" ] || [ "$l6" != "$p6" ]; then
    res=$("$HL" "mbp2607=$l7" "mbp2606=$l6" 2>&1); rc=$?
    case "$l7$l6$p7$p6" in *RED*) show=1;; *) show=${SHOW_ALL:-0};; esac; [ $rc -ne 0 ] && show=1
    [ "$show" = 1 ] && echo "$(date +%T) mbp2607=$l7 mbp2606=$l6 host-level rc=$rc -> $res | 2607: $(echo "$A" | cut -d' ' -f3-8) | 2606: $(echo "$B" | cut -d' ' -f3-8)"
    [ $rc -eq 0 ] && { p7=$l7; p6=$l6; }
  fi
  # 2026-10-19 (AIT-363 cut): HOST-LEVEL changes only on a level change, so its mtime cannot prove freshness. Every cycle
  # writes the live levels with their epoch; consumers check the epoch age (the RC9 cut aborted on a 622 s old HOST-LEVEL).
  # The epoch is mbp2607's observation time (obs7, taken right after its local measurement, before any ssh), so a stalled
  # ssh later in the cycle cannot give an old sample a fresh epoch.
  printf 'epoch=%s mbp2607=%s mbp2606=%s\n' "$obs7" "$l7" "$l6" > /Users/markus/.aeon/lead/aeon/HOST-LEVEL.heartbeat.tmp \
    && mv -f /Users/markus/.aeon/lead/aeon/HOST-LEVEL.heartbeat.tmp /Users/markus/.aeon/lead/aeon/HOST-LEVEL.heartbeat
  sleep 180
done
