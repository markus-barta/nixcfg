#!/usr/bin/env bash
# Linux collector. systemd owns/creates the directory; readers never write.
# Bash has no rename primitive: mv is the sole child per tick. A private FIFO
# lets read -t supply the fractional wait without a second child for sleep.
set -euo pipefail

INTERVAL_MS=${1:-2000}
STASYSMO_DIR=${2:-/run/stasysmo}
SAMPLE_COUNT=${3:-0}
PROC_ROOT=${STASYSMO_PROC_ROOT:-/proc}
[[ $INTERVAL_MS =~ ^[0-9]{1,8}$ && $SAMPLE_COUNT =~ ^[0-9]{1,8}$ ]] || exit 2
INTERVAL_MS=$((10#$INTERVAL_MS))
SAMPLE_COUNT=$((10#$SAMPLE_COUNT))
((INTERVAL_MS >= 500)) || INTERVAL_MS=500
((INTERVAL_MS <= 60000)) || INTERVAL_MS=60000
printf -v INTERVAL_S '%d.%03d' "$((INTERVAL_MS / 1000))" "$((INTERVAL_MS % 1000))"
[[ -d $STASYSMO_DIR && ! -L $STASYSMO_DIR && -O $STASYSMO_DIR ]] || exit 1
umask 077
set -C # Unique temporary names never follow planted symlinks or overwrite files.
wait_file="$STASYSMO_DIR/.wait.$$"
mkfifo -- "$wait_file"
exec {wait_fd}<>"$wait_file"
# Bash has no unlink primitive either; one startup child removes the opened FIFO.
unlink -- "$wait_file"
wait_tick() { read -r -t "$1" -u "$wait_fd" _ || :; }

previous_total=0
previous_idle=0
sequence=0
read_cpu() {
  local kind user nice system idle iowait irq softirq steal rest line
  local -a counters
  ncpu=0
  IFS= read -r line <"$PROC_ROOT/stat" || return 1
  read -r kind user nice system idle iowait irq softirq steal rest <<<"$line"
  [[ $kind == cpu ]] || return 1
  counters=("$user" "$nice" "$system" "$idle" "$iowait" "$irq" "$softirq" "$steal")
  for counter in "${counters[@]}"; do
    [[ $counter =~ ^[0-9]{1,15}$ ]] || return 1
  done
  # Values are kernel decimal integers, validated before Bash arithmetic.
  idle_total=$((10#$idle + 10#$iowait))
  total=$((idle_total + 10#$user + 10#$nice + 10#$system + 10#$irq + 10#$softirq + 10#$steal))
  while read -r kind rest; do
    [[ $kind =~ ^cpu[0-9]+$ ]] && ncpu=$((ncpu + 1))
  done <"$PROC_ROOT/stat"
  ((ncpu > 0 && ncpu <= 9999))
}

read_memory() {
  local key value rest mem_total='' mem_available='' swap_total='' swap_free=''
  while read -r key value rest; do
    case "$key" in
    MemTotal: | MemAvailable: | SwapTotal: | SwapFree:)
      [[ $value =~ ^[0-9]{1,15}$ ]] || return 1
      value=$((10#$value))
      case "$key" in
      MemTotal:) mem_total=$value ;;
      MemAvailable:) mem_available=$value ;;
      SwapTotal:) swap_total=$value ;;
      SwapFree:) swap_free=$value ;;
      esac
      ;;
    esac
  done <"$PROC_ROOT/meminfo"
  [[ -n $mem_total && -n $mem_available && -n $swap_total && -n $swap_free ]] || return 1
  ((mem_total > 0 && mem_available <= mem_total && swap_free <= swap_total)) || return 1
  ram=$(((mem_total - mem_available) * 100 / mem_total))
  swap=0
  ((swap_total == 0)) || swap=$(((swap_total - swap_free) * 100 / swap_total))
}

sample() {
  local delta idle_delta
  read_cpu && read_memory || return 1
  read -r load _ <"$PROC_ROOT/loadavg" || return 1
  [[ $load =~ ^(0|[1-9][0-9]{0,3})\.[0-9]{2}$ ]] || return 1
  delta=$((total - previous_total))
  idle_delta=$((idle_total - previous_idle))
  if ((delta <= 0 || idle_delta < 0 || idle_delta > delta)); then
    # Recover after counter resets/hotplug; this generation remains untouched.
    previous_total=$total
    previous_idle=$idle_total
    return 1
  fi
  cpu=$(((delta - idle_delta) * 100 / delta))
  previous_total=$total
  previous_idle=$idle_total
  # %()T is a Bash builtin, including under the pinned Nix Bash.
  printf -v epoch '%(%s)T' -1
  temp="$STASYSMO_DIR/.snapshot.$$.${sequence}"
  printf 'v1 %s %s %s %s %s %s\n' "$epoch" "$cpu" "$ram" "$swap" "$load" "$ncpu" >"$temp" || return 1
  # System metrics are deliberately readable across local accounts, never writable.
  # Open under the right umask instead of spawning chmod after every sample.
  mv -fT -- "$temp" "$STASYSMO_DIR/snapshot"
}

read_cpu || exit 1
previous_total=$total
previous_idle=$idle_total
wait_tick 0.100
umask 022 # /run snapshot is public read-only; Darwin snapshots are 0600.
while :; do
  sample || : # Keep the previous generation on a sampling failure.
  sequence=$((sequence + 1))
  ((SAMPLE_COUNT == 0 || sequence < SAMPLE_COUNT)) || break
  wait_tick "$INTERVAL_S"
done
