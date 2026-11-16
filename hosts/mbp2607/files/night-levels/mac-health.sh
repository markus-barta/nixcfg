#!/bin/bash
# OPS: one-line Mac health snapshot (disk Data + Nix volumes, memory pressure, swap, load, thermal). Read-only.
h=$(hostname -s)
cores=$(sysctl -n hw.ncpu)
d=$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2{printf "%d %d", $4/1048576, $5}')
n=$(df -k /nix 2>/dev/null | awk 'NR==2{printf "%d %d", $4/1048576, $5}')
mp=$(memory_pressure 2>/dev/null)
mf=$(awk -F': ' '/free percentage/{gsub("%","",$2); print $2}' <<<"$mp")
# 2026-10-21: cumulative swapouts (pages) so the level rule can tell active swapping from residual swap.
so=$(awk -F': ' '/^Swapouts/{gsub(" ","",$2); print $2+0}' <<<"$mp")
sw=$(sysctl -n vm.swapusage 2>/dev/null | awk '{gsub("M","",$6); print int($6)}')
ld=$(sysctl -n vm.loadavg | awk '{print $2, $3, $4}')
th=$(pmset -g therm 2>/dev/null | awk -F'= ' '/CPU_Speed_Limit/{print $2}')
# Battery (2026-10-11: mbp2606 drained 100 -> 6 % on a weak charger). batt=-1 means no battery / unreadable.
bl=$(pmset -g batt 2>/dev/null | grep -o -E "[0-9]+%; [a-zA-Z ]+" | head -1)
bp=${bl%%%*}
bs=$(echo "${bl#*; }" | tr -d " ")
[ -z "$bp" ] && bp=-1 && bs=none
echo "$h cores=$cores data_free_gb=${d% *} data_used_pct=${d#* } nix_free_gb=${n% *} mem_free_pct=$mf swap_used_mb=${sw:-0} load=\"$ld\" cpu_speed_limit=${th:-100} batt_pct=$bp batt_state=$bs swapouts=${so:--1}"
