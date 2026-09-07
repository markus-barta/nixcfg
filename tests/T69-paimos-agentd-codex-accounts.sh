#!/usr/bin/env bash
# NIX-436 — optional Home Manager --codex-accounts boundary for paimos-agentd.
# Isolated Darwin module eval with synthetic fixtures only. Does not read the
# operator registry, lifecycle config, credentials, or T56 release pins.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
eval_file="$repo_root/tests/paimos-agentd-codex-accounts-eval.nix"
module="$repo_root/modules/uzumaki/paimos-agentd.nix"
host_home="$repo_root/hosts/mbp2607/home.nix"
t56="$repo_root/tests/T56-paimos-agentd-home-manager.sh"

fail() {
  printf 'T69 failed: %s\n' "$*" >&2
  exit 1
}

nix-instantiate --parse "$module" >/dev/null
nix-instantiate --parse "$eval_file" >/dev/null

eval_case() {
  nix eval --impure --json --expr "import ${eval_file} { root = ${repo_root}; $1; }"
}

assert_no_private_tokens() {
  if printf '%s' "$1" | grep -Fqe 'FIXTURE_CODEX_HOME_TOKEN' || printf '%s' "$1" | grep -Fqe 'FIXTURE_CODEX_EMAIL_TOKEN'; then
    fail "$2 leaked synthetic registry contents"
  fi
}

python3 - "$module" "$host_home" "$t56" <<'PY' || fail 'source contract drifted'
import pathlib, sys

module, host_home, t56 = (pathlib.Path(p).read_text(encoding="utf-8") for p in sys.argv[1:])
assert "codexAccountsFile" in module
assert "--codex-accounts" in module
assert "default = null" in module
assert "serve accepts `--codex-accounts`" in module
assert "Paimos validates registry semantics" in module
assert "Do not unset, override, or source registry text here." in module
assert "export PATH=" in module
assert "CODEX_HOME" in module
assert "codexAccountsFile =" not in host_home
assert "26.09.07.11.41" in t56
assert '"--codex-accounts"' not in t56
assert "v26.09.07.11.41" in t56
PY

default_json=$(eval_case "accountsFile = null")
enabled_path="/Users/fixture-user/Library/Application Support/paimos/agentd/codex-accounts.json"
enabled_json=$(eval_case "accountsFile = \"${enabled_path}\"")

eval_must_fail() {
  attr=$1
  label=$2
  err=$(mktemp "${TMPDIR:-/tmp}/nix436-eval.XXXXXX")
  if eval_case "$attr" >"$err.out" 2>"$err"; then
    fail "isolated eval accepted $label"
  fi
  grep -Fq 'uzumaki.paimosAgentd codexAccountsFile requires an absolute path outside the Nix store' "$err" || fail "$label did not fail closed"
  assert_no_private_tokens "$(cat "$err")" "$label eval"
  assert_no_private_tokens "$(cat "$err.out")" "$label eval output"
  /usr/bin/trash "$err" "$err.out"
}

eval_must_fail "accountsFile = \"relative-codex-accounts.json\"" "relative path"
eval_must_fail "accountsFile = \"/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-codex-accounts.json\"" "store path"

python3 - "$default_json" "$enabled_json" "$enabled_path" <<'PY' || fail 'isolated eval contract failed'
import json, sys

default, enabled, enabled_path = sys.argv[1:]
default = json.loads(default)
enabled = json.loads(enabled)

def flag_count(args, flag):
    return args.count(flag)

assert default["failedAssertionMessages"] == [], default
assert default["codexAccountsValue"] is None, default
assert flag_count(default["programArguments"], "--codex-accounts") == 0, default
assert default["programArguments"][1] == "serve", default
assert "--instance" in default["programArguments"], default
assert default["environmentVariables"] is None, default
assert default["lifecycleConfigValue"] is None, default
assert "FIXTURE_CODEX_HOME_TOKEN" not in json.dumps(default)
assert "FIXTURE_CODEX_EMAIL_TOKEN" not in json.dumps(default)

assert enabled["failedAssertionMessages"] == [], enabled
assert enabled["codexAccountsValue"] == enabled_path, enabled
assert flag_count(enabled["programArguments"], "--codex-accounts") == 1, enabled
idx = enabled["programArguments"].index("--codex-accounts")
assert enabled["programArguments"][idx + 1] == enabled_path, enabled
assert enabled["environmentVariables"] is None, enabled
assert enabled_path in enabled["activation"], enabled
assert "FIXTURE_CODEX_HOME_TOKEN" not in json.dumps(enabled)
assert "FIXTURE_CODEX_EMAIL_TOKEN" not in json.dumps(enabled)
assert "source " not in enabled["activation"]
assert "eval " not in enabled["activation"]
PY

assert_no_private_tokens "$default_json" "default eval"
assert_no_private_tokens "$enabled_json" "enabled eval"

launcher=$(
  python3 - "$enabled_json" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["codexLauncher"])
PY
)
[ -n "$launcher" ] || fail 'isolated eval did not produce a Codex launcher path'

current_system=$(nix eval --impure --raw --expr builtins.currentSystem)
if [ "$current_system" = aarch64-darwin ]; then
  launcher_text=$(
    nix eval --impure --raw --expr "builtins.readFile ((import ${eval_file} { root = ${repo_root}; accountsFile = \"${enabled_path}\"; }).codexLauncher)"
  )
  printf '%s\n' "$launcher_text" | grep -Eq '^export PATH=/nix/store/[^/]+-nodejs-[^/]+/bin:/usr/bin:/bin:/usr/sbin:/sbin$' || fail 'Codex launcher does not set PATH only'
  printf '%s\n' "$launcher_text" | grep -Fq 'exec ' || fail 'Codex launcher does not exec the operator CLI'
  if printf '%s\n' "$launcher_text" | grep -Eq 'CODEX_HOME|source |eval '; then
    fail 'Codex launcher mutates CODEX_HOME or evaluates registry text'
  fi
  assert_no_private_tokens "$launcher_text" "Codex launcher"

  activation=$(
    python3 - "$enabled_json" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["activation"])
PY
  )
  printf '%s' "$activation" | grep -oE '/nix/store/[0-9a-z]{32}-[^/"[:space:]]+' | sort -u | while IFS= read -r store_path; do
    nix-store --realise "$store_path" >/dev/null
  done

  fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/nix436-codex-accounts.XXXXXX")
  chmod 0700 "$fixture_root"
  trap '/usr/bin/trash "$fixture_root"' EXIT
  valid="$fixture_root/registry.json"
  printf '%s' '{"accounts":[{"key":"fixture-key","home":"FIXTURE_CODEX_HOME_TOKEN","email":"FIXTURE_CODEX_EMAIL_TOKEN"}]}' >"$valid"
  chmod 0600 "$valid"

  run_activation() {
    target=$1
    python3 - "$activation" "$target" <<'PY'
import pathlib, sys
script = sys.argv[1].replace("/Users/fixture-user/Library/Application Support/paimos/agentd/codex-accounts.json", sys.argv[2], 1)
path = pathlib.Path(sys.argv[2]).parent / "activation.sh"
path.write_text(script, encoding="utf-8")
print(path)
PY
  }

  expect_activation_failure() {
    target=$1
    reason=$2
    err="$fixture_root/$reason.err"
    if /bin/bash "$(run_activation "$target")" >"$err" 2>&1; then
      fail "activation accepted $reason"
    fi
    assert_no_private_tokens "$(cat "$err")" "$reason error"
  }

  activation_script=$(run_activation "$valid")
  /bin/bash "$activation_script" || fail 'activation rejected a valid owner-only JSON object'
  assert_no_private_tokens "$(cat "$activation_script")" "activation script"

  symlink="$fixture_root/symlink.json"
  ln -s "$valid" "$symlink"
  expect_activation_failure "$symlink" symlink

  mode="$fixture_root/mode.json"
  cp "$valid" "$mode"
  chmod 0644 "$mode"
  expect_activation_failure "$mode" mode

  hard="$fixture_root/hard.json"
  cp "$valid" "$hard"
  chmod 0600 "$hard"
  ln "$hard" "$fixture_root/hard-link.json"
  expect_activation_failure "$hard" hardlink

  oversize="$fixture_root/oversize.json"
  python3 - "$oversize" <<'PY'
import sys
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write("x" * 65537)
PY
  chmod 0600 "$oversize"
  expect_activation_failure "$oversize" oversize

  invalid="$fixture_root/invalid.json"
  printf '%s' 'not-a-json-object' >"$invalid"
  chmod 0600 "$invalid"
  expect_activation_failure "$invalid" invalid-json

  owner_probe="$fixture_root/owner.json"
  cp "$valid" "$owner_probe"
  chmod 0600 "$owner_probe"
  grep -Fq 'id -u' <<<"$activation" || fail 'activation does not check the current user owner'
  grep -Fq 'paimos-agentd Codex account registry ownership, mode or link count is unsafe' <<<"$activation" || fail 'activation lacks the owner/mode/link failure'
  if [ "$(/usr/bin/stat -f '%u' "$owner_probe")" != "$(id -u)" ]; then
    fail 'valid fixture is not owned by the current user'
  fi
  /bin/bash "$(run_activation "$owner_probe")" || fail 'activation rejected a current-user-owned 0600 file'
fi

printf 'T69 passed: isolated paimos-agentd Codex accounts boundary keeps the default argv and validates an external owner-only JSON path\n'
