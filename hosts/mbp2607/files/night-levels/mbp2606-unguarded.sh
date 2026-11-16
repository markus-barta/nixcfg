#!/bin/bash
# OPS-300 follow-up (Markus 2026-10-11 "Detect + report"): runs ON mbp2606 as mba via `ssh … bash -s`.
# Lists heavy test processes (Playwright/Chromium, go test binaries, vitest, node --test) that are NOT part of
# a guarded run: a process is guarded when it or any ancestor (10 levels) works under LEAD's run dirs
# (~/ci.noindex/aeon-runs/<id>, shared ~/ci.noindex/aeon-nm). That also covers ci-static's merge tree in
# /private/tmp/nix-shell.*/aeon-ci-static-* (TMPDIR from nix develop; AEON-LEAD 2026-10-11).
# Output: one line per unguarded process "pid|cwd|command", nothing when clean. Read-only.
OK1=/Users/mba/ci.noindex/aeon-runs/
OK2=/Users/mba/ci.noindex/aeon-nm/
# AIT's remote lane honours ~mba/.aeon-remote-policy since 2026-10-13 09:23 (AIT confirmed; OPS-300 contract).
OK3=/Users/mba/ci.noindex/aithema-runs/
cwd_of() { lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1; }
guarded() { # 0 = guarded, 1 = unguarded, 2 = unknown (a process vanished mid-walk: never report)
  local p=$1 i c
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -z "$p" ] && return 2
    [ "$p" -le 1 ] && return 1
    c=$(cwd_of "$p")
    [ -z "$c" ] && return 2
    case "$c/" in "$OK1"* | "$OK2"* | "$OK3"*) return 0 ;; esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
  return 1
}
ps -u mba -o pid=,command= 2>/dev/null | grep -E 'chrome-headless-shell|playwright|/go test|go-build[0-9]+/b[0-9]+/[^ ]+\.test|vitest|node --test|--experimental-strip-types --test' | grep -v -E 'grep -E|mbp2606-unguarded' |
  while read -r pid cmd; do
    own=$(cwd_of "$pid")
    [ -z "$own" ] && continue # exited between ps and lsof
    guarded "$pid"
    [ $? -ne 1 ] && continue
    sleep 1
    guarded "$pid"
    [ $? -ne 1 ] && continue # re-check: short-lived parents race the walk
    printf '%s|%s|%s\n' "$pid" "$own" "${cmd:0:120}"
  done
