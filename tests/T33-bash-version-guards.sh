#!/usr/bin/env bash
# T33 — every test that relies on set -e to enforce a bare [[ ]] must
# guard its bash version.
#
# WHY: macOS ships bash 3.2.57, where set -e does NOT abort on a failing
# bare [[ ]] command. Proof:
#
#   bash -c 'set -euo pipefail; v=6; [[ "$v" == 7 ]]; echo reached'
#   -> prints "reached", exits 0
#
# CI runs bash 5 and aborts correctly. So a test written that way passes
# silently on a macOS workstation no matter what its assertions say. That
# is worse than a failing test: it manufactures false confidence. It hid a
# real T22 break (hard-coded fleet size) during the 2026-07 gpc0 teardown.
#
# This meta-test fails if any tests/*.sh combines set -e with a bare
# [[ ]] assertion but lacks a BASH_VERSINFO guard.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tests_dir="$repo_root/tests"
self=${BASH_SOURCE[0]##*/}

unguarded=()
for script in "$tests_dir"/*.sh; do
  name=${script##*/}
  [ "$name" != "$self" ] || continue

  # Only scripts that both enable errexit and use a bare [[ ]] at the
  # start of a line are exposed. `[[ ]] || fail` forms are explicit and safe.
  grep -qE '^set -[a-zA-Z]*e' "$script" || continue
  grep -qE '^[[:space:]]*\[\[ ' "$script" || continue

  grep -q 'BASH_VERSINFO' "$script" || unguarded+=("$name")
done

if [ ${#unguarded[@]} -gt 0 ]; then
  printf 'bash_version_guards=failed\n' >&2
  printf '\nThese tests rely on "set -e" to enforce a bare [[ ]] but do not guard\n' >&2
  printf 'their bash version, so they FALSELY PASS on macOS bash 3.2:\n\n' >&2
  printf '  %s\n' "${unguarded[@]}" >&2
  printf '\nAdd after the set- line:\n\n' >&2
  cat >&2 <<'SNIPPET'
  if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    printf '%s: bash %s is too old -- set -e does not abort on a failing [[ ]], so this test would FALSELY PASS. Run under bash 5: nix run nixpkgs#bash -- %s\n' \
      "${0##*/}" "$BASH_VERSION" "$0" >&2
    exit 2
  fi
SNIPPET
  printf '\n...or make the assertion explicit instead: [[ a == b ]] || fail "..."\n' >&2
  exit 1
fi

# --- OPS-188: a test that cannot run is not a guard ------------------------
# Two ways a test silently stops guarding anything, both found on 2026-08-21:
# it loses its executable bit (CI's `run: tests/Tnn.sh` then exits 126), or it
# is never referenced by a workflow at all. 18 of 47 tests were in the second
# state; three of those had been incapable of failing for months.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
not_executable=()
checked=()
for test_file in "$repo_root"/tests/T*.sh; do
  name="$(basename "$test_file")"
  checked+=("$name")
  [ -x "$test_file" ] || not_executable+=("$name")
done

# OPS-354: these interpreted tests also guard the deployment/rollback path.
# They are invoked with their runtimes, so executable bits are not required.
for name in T100-joedesk-release.py T101-joedesk-operations.mjs T102-joedesk-host-gate.mjs; do
  checked+=("$name")
done

# OPS-434: inspect executable steps, not comments or incidental workflow text.
# Every contract must run exactly once, including across parallel shards.
# Ruby/Psych is already required by T27's action-pin guard.
ruby - "$repo_root/.github/workflows" "${checked[@]}" <<'RUBY'
require "psych"

workflow_dir = ARGV.shift
# These two existing contracts belong to their specialized workflows; moving
# them into check.yml would expand the suite rather than shard it.
specialized = {
  "T05-hostdash-manifest.sh" => "pharos-host-settings.yml",
  "T16-pharos-host-removal.sh" => "pharos-host-removal.yml",
}
locations = Hash.new { |hash, name| hash[name] = [] }
["check.yml", *specialized.values].each do |filename|
  Psych.load_file(File.join(workflow_dir, filename)).fetch("jobs").each do |job_id, job|
    job.fetch("steps", []).each_with_index do |step, index|
      # T91 is executed and then shellchecked in the same run block. Count
      # wiring once per step, so lint arguments are not duplicate executions.
      step.fetch("run", "").scan(%r{\btests/(T[\w.-]+\.(?:sh|py|mjs))\b}).flatten.uniq.each do |name|
        next unless filename == specialized.fetch(name, "check.yml")

        locations[name] << "#{filename}:#{job_id}:#{index + 1}"
      end
    end
  end
end
failures = ARGV.map do |name|
  wired = locations[name]
  next if wired.length == 1

  "#{name}: expected exactly one #{specialized.fetch(name, 'check.yml')} step, found #{wired.length} (#{wired.join(', ')})"
end.compact
abort "suite_runnability=failed\n#{failures.join("\n")}" unless failures.empty?
RUBY

if [ ${#not_executable[@]} -gt 0 ]; then
  printf 'suite_runnability=failed\n' >&2
  printf '\nNot executable (CI would exit 126 without running a single assertion):\n' >&2
  printf '  %s\n' "${not_executable[@]}" >&2
  printf '\nFix: chmod +x tests/<name> && git update-index --chmod=+x tests/<name>\n' >&2
  exit 1
fi

printf 'bash_version_guards=passed suite_runnable=%s\n' "${#checked[@]}"
