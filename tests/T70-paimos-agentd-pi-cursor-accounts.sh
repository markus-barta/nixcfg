#!/usr/bin/env bash
# NIX-439 — optional Home Manager Pi/Cursor path+registry boundary for paimos-agentd.
# Isolated Darwin module eval with synthetic fixtures only. Does not read operator
# registries, lifecycle config, credentials, or T56 release pins. Does not enable
# host settings against the current Paimos pin.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
eval_file="$repo_root/tests/paimos-agentd-codex-accounts-eval.nix"
module="$repo_root/modules/uzumaki/paimos-agentd.nix"

fail() {
  printf 'T70 failed: %s\n' "$*" >&2
  exit 1
}

nix-instantiate --parse "$module" >/dev/null
nix-instantiate --parse "$eval_file" >/dev/null

eval_case() {
  nix eval --impure --json --expr "import ${eval_file} { root = ${repo_root}; $1; }"
}

assert_no_private_tokens() {
  if printf '%s' "$1" | grep -Fqe 'FIXTURE_PI_HOME_TOKEN' ||
    printf '%s' "$1" | grep -Fqe 'FIXTURE_PI_EMAIL_TOKEN' ||
    printf '%s' "$1" | grep -Fqe 'FIXTURE_CURSOR_HOME_TOKEN' ||
    printf '%s' "$1" | grep -Fqe 'FIXTURE_CURSOR_EMAIL_TOKEN'; then
    fail "$2 leaked synthetic registry contents"
  fi
}

python3 - "$module" <<'PY' || fail 'source contract drifted'
import pathlib, sys

module = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
for needle in (
    "piPath",
    "piAccountsFile",
    "cursorPath",
    "cursorAccountsFile",
    "--pi-path",
    "--pi-accounts",
    "--cursor-path",
    "--cursor-accounts",
    "serve accepts `--pi-path` and `--pi-accounts`",
    "serve accepts `--cursor-path`",
    "`--cursor-accounts`",
    "Paimos validates registry semantics",
    "do not enable against older pins",
    "does not wrap them, copy auth directories, or start login",
):
    assert needle in module, needle
assert "lib.types.nullOr lib.types.str" in module
assert "lib.types.path" not in module
assert "builtins.readFile" not in module
assert "readFile cfg.piAccountsFile" not in module
assert "readFile cfg.cursorAccountsFile" not in module
PY

pi_cli="/Users/fixture-user/.npm-global/bin/pi"
pi_cli_spaces="/Users/fixture-user/Local Apps/pi"
cursor_cli="/Users/fixture-user/.local/bin/cursor-agent"
pi_accounts="/Users/fixture-user/Library/Application Support/paimos/agentd/pi-accounts.json"
cursor_accounts="/Users/fixture-user/Library/Application Support/paimos/agentd/cursor-accounts.json"
codex_accounts="/Users/fixture-user/Library/Application Support/paimos/agentd/codex-accounts.json"
lifecycle_path="/Users/fixture-user/Library/Application Support/paimos/agentd/lifecycle.json"

default_json=$(eval_case "accountsFile = null")
pi_json=$(eval_case "piPath = \"${pi_cli}\"; piAccountsFile = \"${pi_accounts}\"")
cursor_json=$(eval_case "cursorPath = \"${cursor_cli}\"; cursorAccountsFile = \"${cursor_accounts}\"")
both_json=$(eval_case "piPath = \"${pi_cli}\"; piAccountsFile = \"${pi_accounts}\"; cursorPath = \"${cursor_cli}\"; cursorAccountsFile = \"${cursor_accounts}\"")
spaces_json=$(eval_case "piPath = \"${pi_cli_spaces}\"; piAccountsFile = \"${pi_accounts}\"")
reporting_json=$(eval_case "reporting = true; lifecycleFile = \"${lifecycle_path}\"")
pi_reporting_json=$(eval_case "reporting = true; lifecycleFile = \"${lifecycle_path}\"; piPath = \"${pi_cli}\"; piAccountsFile = \"${pi_accounts}\"")
cursor_codex_json=$(eval_case "accountsFile = \"${codex_accounts}\"; cursorPath = \"${cursor_cli}\"; cursorAccountsFile = \"${cursor_accounts}\"")

eval_must_fail() {
  attr=$1
  closed=$2
  label=$3
  python3 - "$eval_file" "$repo_root" "$attr" "$closed" "$label" <<'PY' || fail "isolated eval did not fail closed for $label"
import pathlib, subprocess, sys, tempfile

eval_file, repo_root, attr, closed, label = sys.argv[1:]
expr = f"import {eval_file} {{ root = {repo_root}; {attr}; }}"
private = (
    "FIXTURE_PI_HOME_TOKEN",
    "FIXTURE_PI_EMAIL_TOKEN",
    "FIXTURE_CURSOR_HOME_TOKEN",
    "FIXTURE_CURSOR_EMAIL_TOKEN",
)
with tempfile.TemporaryDirectory(prefix="nix439-eval.") as tmp:
    err_path = pathlib.Path(tmp) / "err"
    out_path = pathlib.Path(tmp) / "out"
    with out_path.open("w", encoding="utf-8") as out_handle, err_path.open("w", encoding="utf-8") as err_handle:
        completed = subprocess.run(
            ["nix", "eval", "--impure", "--json", "--expr", expr],
            stdout=out_handle,
            stderr=err_handle,
            check=False,
        )
    err_text = err_path.read_text(encoding="utf-8")
    out_text = out_path.read_text(encoding="utf-8")
if completed.returncode == 0:
    print(f"{label} was accepted", file=sys.stderr)
    raise SystemExit(1)
if closed not in err_text:
    print(f"{label} did not fail closed", file=sys.stderr)
    raise SystemExit(1)
if any(token in err_text or token in out_text for token in private):
    print(f"{label} leaked synthetic registry contents", file=sys.stderr)
    raise SystemExit(1)
PY
}

eval_must_fail "piPath = \"${pi_cli}\"" "uzumaki.paimosAgentd Pi requires piPath and piAccountsFile together" "pi path without accounts"
eval_must_fail "piAccountsFile = \"${pi_accounts}\"" "uzumaki.paimosAgentd Pi requires piPath and piAccountsFile together" "pi accounts without path"
eval_must_fail "cursorPath = \"${cursor_cli}\"" "uzumaki.paimosAgentd Cursor requires cursorPath and cursorAccountsFile together" "cursor path without accounts"
eval_must_fail "cursorAccountsFile = \"${cursor_accounts}\"" "uzumaki.paimosAgentd Cursor requires cursorPath and cursorAccountsFile together" "cursor accounts without path"
eval_must_fail "piPath = \"relative-pi\"; piAccountsFile = \"${pi_accounts}\"" "uzumaki.paimosAgentd vendor CLI paths must be absolute" "relative pi CLI path"
eval_must_fail "cursorPath = \"relative-cursor-agent\"; cursorAccountsFile = \"${cursor_accounts}\"" "uzumaki.paimosAgentd vendor CLI paths must be absolute" "relative cursor CLI path"
eval_must_fail "piPath = \"${pi_cli}\"; piAccountsFile = \"relative-pi-accounts.json\"" "uzumaki.paimosAgentd piAccountsFile requires an absolute path outside the Nix store" "relative pi registry"
eval_must_fail "cursorPath = \"${cursor_cli}\"; cursorAccountsFile = \"relative-cursor-accounts.json\"" "uzumaki.paimosAgentd cursorAccountsFile requires an absolute path outside the Nix store" "relative cursor registry"
eval_must_fail "piPath = \"${pi_cli}\"; piAccountsFile = \"/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-pi-accounts.json\"" "uzumaki.paimosAgentd piAccountsFile requires an absolute path outside the Nix store" "store pi registry"
eval_must_fail "cursorPath = \"${cursor_cli}\"; cursorAccountsFile = \"/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-cursor-accounts.json\"" "uzumaki.paimosAgentd cursorAccountsFile requires an absolute path outside the Nix store" "store cursor registry"

python3 - "$default_json" "$pi_json" "$cursor_json" "$both_json" "$spaces_json" "$reporting_json" "$pi_reporting_json" "$cursor_codex_json" "$pi_cli" "$pi_cli_spaces" "$pi_accounts" "$cursor_cli" "$cursor_accounts" "$codex_accounts" "$lifecycle_path" <<'PY' || fail 'isolated eval contract failed'
import json, sys

(
    default,
    pi,
    cursor,
    both,
    spaces,
    reporting,
    pi_reporting,
    cursor_codex,
    pi_cli,
    pi_cli_spaces,
    pi_accounts,
    cursor_cli,
    cursor_accounts,
    codex_accounts,
    lifecycle_path,
) = sys.argv[1:]
default = json.loads(default)
pi = json.loads(pi)
cursor = json.loads(cursor)
both = json.loads(both)
spaces = json.loads(spaces)
reporting = json.loads(reporting)
pi_reporting = json.loads(pi_reporting)
cursor_codex = json.loads(cursor_codex)
private = (
    "FIXTURE_PI_HOME_TOKEN",
    "FIXTURE_PI_EMAIL_TOKEN",
    "FIXTURE_CURSOR_HOME_TOKEN",
    "FIXTURE_CURSOR_EMAIL_TOKEN",
)
native_flags = ("--pi-path", "--pi-accounts", "--cursor-path", "--cursor-accounts")


def flag_count(args, flag):
    return args.count(flag)


def flag_value(args, flag):
    return args[args.index(flag) + 1]


def refute_private(payload, label):
    blob = json.dumps(payload)
    for token in private:
        assert token not in blob, (label, token)
    for phrase in ("source ", "eval "):
        assert phrase not in payload.get("piActivation", "")
        assert phrase not in payload.get("cursorActivation", "")


for payload, label in (
    (default, "default"),
    (pi, "pi"),
    (cursor, "cursor"),
    (both, "both"),
    (spaces, "spaces"),
    (reporting, "reporting"),
    (pi_reporting, "pi-reporting"),
    (cursor_codex, "cursor-codex"),
):
    assert payload["failedAssertionMessages"] == [], (label, payload)
    assert payload["environmentVariables"] is None, (label, payload)
    refute_private(payload, label)

for flag in native_flags:
    assert flag_count(default["programArguments"], flag) == 0, (flag, default)
assert default["piPathValue"] is None and default["piAccountsValue"] is None, default
assert default["cursorPathValue"] is None and default["cursorAccountsValue"] is None, default
assert default["programArguments"][1] == "serve", default
assert "--instance" in default["programArguments"], default
assert "--codex-path" in default["programArguments"], default
assert "--claude-path" in default["programArguments"], default

assert pi["piPathValue"] == pi_cli, pi
assert pi["piAccountsValue"] == pi_accounts, pi
assert pi["cursorPathValue"] is None, pi
assert flag_count(pi["programArguments"], "--pi-path") == 1, pi
assert flag_count(pi["programArguments"], "--pi-accounts") == 1, pi
assert flag_count(pi["programArguments"], "--cursor-path") == 0, pi
assert pi["programArguments"] == default["programArguments"] + ["--pi-path", pi_cli, "--pi-accounts", pi_accounts], pi
assert pi_accounts in pi["piActivation"], pi
assert "paimos-agentd Pi account registry must be an existing regular non-symlink file" in pi["piActivation"], pi

assert cursor["cursorPathValue"] == cursor_cli, cursor
assert cursor["cursorAccountsValue"] == cursor_accounts, cursor
assert cursor["piPathValue"] is None, cursor
assert flag_count(cursor["programArguments"], "--cursor-path") == 1, cursor
assert flag_count(cursor["programArguments"], "--cursor-accounts") == 1, cursor
assert flag_count(cursor["programArguments"], "--pi-path") == 0, cursor
assert cursor["programArguments"] == default["programArguments"] + [
    "--cursor-path",
    cursor_cli,
    "--cursor-accounts",
    cursor_accounts,
], cursor
assert cursor_accounts in cursor["cursorActivation"], cursor
assert "paimos-agentd Cursor account registry must be an existing regular non-symlink file" in cursor["cursorActivation"], cursor

assert both["programArguments"] == default["programArguments"] + [
    "--pi-path",
    pi_cli,
    "--pi-accounts",
    pi_accounts,
    "--cursor-path",
    cursor_cli,
    "--cursor-accounts",
    cursor_accounts,
], both
for flag in native_flags:
    assert flag_count(both["programArguments"], flag) == 1, (flag, both)

assert spaces["piPathValue"] == pi_cli_spaces, spaces
assert flag_value(spaces["programArguments"], "--pi-path") == pi_cli_spaces, spaces
assert flag_value(spaces["programArguments"], "--pi-accounts") == pi_accounts, spaces
assert "Local Apps" in json.dumps(spaces)

assert reporting["piPathValue"] is None and reporting["cursorPathValue"] is None, reporting
assert flag_value(reporting["programArguments"], "--lifecycle-config") == lifecycle_path, reporting
for flag in native_flags:
    assert flag_count(reporting["programArguments"], flag) == 0, (flag, reporting)

assert pi_reporting["programArguments"] == reporting["programArguments"] + [
    "--pi-path",
    pi_cli,
    "--pi-accounts",
    pi_accounts,
], pi_reporting
assert flag_count(pi_reporting["programArguments"], "--cursor-path") == 0, pi_reporting
assert flag_count(pi_reporting["programArguments"], "--lifecycle-config") == 1, pi_reporting

assert flag_value(cursor_codex["programArguments"], "--codex-accounts") == codex_accounts, cursor_codex
assert cursor_codex["programArguments"][-4:] == [
    "--cursor-path",
    cursor_cli,
    "--cursor-accounts",
    cursor_accounts,
], cursor_codex
assert flag_count(cursor_codex["programArguments"], "--codex-accounts") == 1, cursor_codex
assert flag_count(cursor_codex["programArguments"], "--pi-path") == 0, cursor_codex
PY

for payload in "$default_json" "$pi_json" "$cursor_json" "$both_json" "$spaces_json" "$reporting_json" "$pi_reporting_json" "$cursor_codex_json"; do
  assert_no_private_tokens "$payload" "eval json"
done

current_system=$(nix eval --impure --raw --expr builtins.currentSystem)
if [ "$current_system" = aarch64-darwin ]; then
  pi_activation=$(
    python3 - "$pi_json" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["piActivation"])
PY
  )
  cursor_activation=$(
    python3 - "$cursor_json" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["cursorActivation"])
PY
  )

  store_paths=$(mktemp "${TMPDIR:-/tmp}/nix439-store-paths.XXXXXX")
  printf '%s\n%s' "$pi_activation" "$cursor_activation" |
    grep -oE '/nix/store/[0-9a-z]{32}-[^/"[:space:]]+' | sort -u >"$store_paths"
  while IFS= read -r store_path; do
    nix-store --realise "$store_path" >/dev/null
    if grep -RF -e 'FIXTURE_PI_HOME_TOKEN' -e 'FIXTURE_PI_EMAIL_TOKEN' -e 'FIXTURE_CURSOR_HOME_TOKEN' -e 'FIXTURE_CURSOR_EMAIL_TOKEN' "$store_path" >/dev/null 2>&1; then
      fail 'emitted store closure leaked synthetic registry contents'
    fi
  done <"$store_paths"
  /usr/bin/trash "$store_paths"

  fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/nix439-pi-cursor-accounts.XXXXXX")
  chmod 0700 "$fixture_root"
  trap '/usr/bin/trash "$fixture_root"' EXIT

  run_activation() {
    script_text=$1
    configured=$2
    target=$3
    python3 - "$script_text" "$configured" "$target" <<'PY'
import pathlib, sys
script, configured, target = sys.argv[1:]
script = script.replace(configured, target, 1)
path = pathlib.Path(target).parent / "activation.sh"
path.write_text(script, encoding="utf-8")
print(path)
PY
  }

  expect_activation_failure() {
    script_text=$1
    configured=$2
    target=$3
    reason=$4
    err="$fixture_root/$reason.err"
    if /bin/bash "$(run_activation "$script_text" "$configured" "$target")" >"$err" 2>&1; then
      fail "activation accepted $reason"
    fi
    assert_no_private_tokens "$(cat "$err")" "$reason error"
  }

  exercise_registry() {
    script_text=$1
    configured=$2
    prefix=$3
    token_home=$4
    token_email=$5
    valid="$fixture_root/${prefix}-registry.json"
    printf '%s' "{\"accounts\":[{\"key\":\"fixture-key\",\"home\":\"${token_home}\",\"email\":\"${token_email}\"}]}" >"$valid"
    chmod 0600 "$valid"

    activation_script=$(run_activation "$script_text" "$configured" "$valid")
    /bin/bash "$activation_script" || fail "activation rejected a valid owner-only ${prefix} JSON object"
    assert_no_private_tokens "$(cat "$activation_script")" "${prefix} activation script"

    symlink="$fixture_root/${prefix}-symlink.json"
    ln -s "$valid" "$symlink"
    expect_activation_failure "$script_text" "$configured" "$symlink" "${prefix}-symlink"

    mode="$fixture_root/${prefix}-mode.json"
    cp "$valid" "$mode"
    chmod 0644 "$mode"
    expect_activation_failure "$script_text" "$configured" "$mode" "${prefix}-mode"

    hard="$fixture_root/${prefix}-hard.json"
    cp "$valid" "$hard"
    chmod 0600 "$hard"
    ln "$hard" "$fixture_root/${prefix}-hard-link.json"
    expect_activation_failure "$script_text" "$configured" "$hard" "${prefix}-hardlink"

    oversize="$fixture_root/${prefix}-oversize.json"
    python3 - "$oversize" <<'PY'
import sys
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write("x" * 65537)
PY
    chmod 0600 "$oversize"
    expect_activation_failure "$script_text" "$configured" "$oversize" "${prefix}-oversize"

    invalid="$fixture_root/${prefix}-invalid.json"
    printf '%s' 'not-a-json-object' >"$invalid"
    chmod 0600 "$invalid"
    expect_activation_failure "$script_text" "$configured" "$invalid" "${prefix}-invalid-json"

    owner_probe="$fixture_root/${prefix}-owner.json"
    cp "$valid" "$owner_probe"
    chmod 0600 "$owner_probe"
    grep -Fq 'id -u' <<<"$script_text" || fail "${prefix} activation does not check the current user owner"
    grep -Fq "paimos-agentd ${prefix} account registry ownership, mode or link count is unsafe" <<<"$script_text" || fail "${prefix} activation lacks the owner/mode/link failure"
    if [ "$(/usr/bin/stat -f '%u' "$owner_probe")" != "$(id -u)" ]; then
      fail "valid ${prefix} fixture is not owned by the current user"
    fi
    /bin/bash "$(run_activation "$script_text" "$configured" "$owner_probe")" || fail "${prefix} activation rejected a current-user-owned 0600 file"
  }

  exercise_registry "$pi_activation" "$pi_accounts" "Pi" "FIXTURE_PI_HOME_TOKEN" "FIXTURE_PI_EMAIL_TOKEN"
  exercise_registry "$cursor_activation" "$cursor_accounts" "Cursor" "FIXTURE_CURSOR_HOME_TOKEN" "FIXTURE_CURSOR_EMAIL_TOKEN"
fi

printf 'T70 passed: isolated paimos-agentd Pi/Cursor path+registry boundary keeps the default argv and validates paired external owner-only JSON paths\n'
