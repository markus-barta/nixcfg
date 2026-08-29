#!/usr/bin/env bash
# T53-start-github-runner.sh
# Description: Keep the dedicated START runner and its registration token fail closed.
# Related PPM issue: NIX-378

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mutation="${1:-}"
if [[ $# -gt 1 ]]; then
  printf 'start_runner_contract=failed reason=invalid_argument\n' >&2
  exit 1
fi
nixpkgs_path=$(nix eval --raw --no-update-lock-file \
  "$repo_root#nixosConfigurations.csb1.pkgs.path")
runner_service_module="$nixpkgs_path/nixos/modules/services/continuous-integration/github-runner/service.nix"
enabled_eval=$(nix-instantiate --eval --strict --json \
  "$repo_root/tests/start-runner-enabled-eval.nix" \
  --argstr nixpkgsPath "$nixpkgs_path" \
  --argstr runnerModulePath "$repo_root/hosts/csb1/start-github-runner.nix")
jq -e '
  .runner == {
    "enable": true,
    "extraLabels": ["csb1-start"],
    "group": "users",
    "name": "csb1-start",
    "tokenFile": "/run/agenix/csb1-start-github-runner",
    "url": "https://github.com/augmentoring-team/start-agm-com",
    "user": "mba"
  }
  and .service.User == "mba"
  and .service.NoNewPrivileges == true
  and (.service.InaccessiblePaths | index("-/run/agenix/csb1-start-github-runner") != null)
  and (.service.InaccessiblePaths | index("/var/lib/github-runner/csb1-start/.current-token") != null)
' <<<"$enabled_eval" >/dev/null || {
  printf 'start_runner_contract=failed reason=enabled_evaluation\n' >&2
  exit 1
}

python3 - \
  "$mutation" \
  "$repo_root/hosts/csb1/start-github-runner.nix" \
  "$repo_root/hosts/csb1/configuration.nix" \
  "$repo_root/secrets/secrets.nix" \
  "$repo_root/.github/workflows/check.yml" \
  "$runner_service_module" <<'PY'
import pathlib
import re
import sys

mutation = sys.argv[1]
module_path = pathlib.Path(sys.argv[2])
host_path = pathlib.Path(sys.argv[3])
secrets_path = pathlib.Path(sys.argv[4])
workflow_path = pathlib.Path(sys.argv[5])
nixpkgs_service_path = pathlib.Path(sys.argv[6])

module = module_path.read_text(encoding="utf-8")
host = host_path.read_text(encoding="utf-8")
secrets = secrets_path.read_text(encoding="utf-8")
workflow = workflow_path.read_text(encoding="utf-8")
nixpkgs_service = nixpkgs_service_path.read_text(encoding="utf-8")

if mutation == "visible-token":
    module += '\nInaccessiblePaths = lib.mkForce [ "/tmp/copied-token" ];\n'
elif mutation == "missing-label":
    module = module.replace('        extraLabels = [ "csb1-start" ];\n', "")
elif mutation == "sudo-expansion":
    module += "\nNoNewPrivileges = lib.mkForce false;\n"
elif mutation == "missing-secret-gate":
    module = module.replace(
        "lib.mkIf (builtins.pathExists ../../secrets/csb1-start-github-runner.age)",
        "lib.mkIf true",
    )
elif mutation:
    raise SystemExit("start_runner_contract=failed reason=invalid_mutation")


def require_exact(text: str, needle: str, count: int, reason: str) -> None:
    if text.count(needle) != count:
        raise SystemExit(f"start_runner_contract=failed reason={reason}")


require_exact(
    host,
    "    ./start-github-runner.nix # NIX-378: GitHub Actions runner for augmentoring-team/start-agm-com",
    1,
    "module_import",
)
require_exact(module, "services.github-runners.csb1-start =", 1, "runner_definition")
require_exact(
    module,
    "lib.mkIf (builtins.pathExists ../../secrets/csb1-start-github-runner.age)",
    1,
    "runner_secret_gate",
)
for needle, reason in (
    ('        url = "https://github.com/augmentoring-team/start-agm-com";', "repository"),
    ('        name = "csb1-start";', "runner_name"),
    ('        extraLabels = [ "csb1-start" ];', "runner_label"),
    ("        replace = true;", "replacement_policy"),
    (
        "        tokenFile = config.age.secrets.csb1-start-github-runner.path;",
        "token_projection",
    ),
    ('        user = "mba";', "runner_user"),
    ('        group = "users";', "runner_group"),
    ('            "docker"', "docker_group"),
    ("          ProtectHome = false;", "deploy_home_access"),
    ("          nodejs_24", "node_runtime"),
):
    require_exact(module, needle, 1, reason)

for forbidden, reason in (
    ("InaccessiblePaths =", "token_source_visibility_override"),
    ("NoNewPrivileges =", "no_new_privileges_override"),
    ("PrivateUsers =", "private_users_override"),
    ("CapabilityBoundingSet =", "capability_expansion"),
    ("/run/wrappers/bin/sudo", "sudo_wrapper"),
):
    if forbidden in module:
        raise SystemExit(f"start_runner_contract=failed reason={reason}")

for default_boundary, reason in (
    ('"-${cfg.tokenFile}"', "nixpkgs_token_source_boundary"),
    (
        '"${stateDir}/${currentConfigTokenFilename}"',
        "nixpkgs_copied_token_boundary",
    ),
):
    require_exact(nixpkgs_service, default_boundary, 1, reason)

require_exact(
    host,
    "age.secrets.csb1-start-github-runner =",
    1,
    "secret_projection",
)
require_exact(
    host,
    "lib.mkIf (builtins.pathExists ../../secrets/csb1-start-github-runner.age)",
    1,
    "secret_projection_gate",
)
secret_match = re.search(
    r"^  age\.secrets\.csb1-start-github-runner =\n"
    r"(?P<body>.*?)^      \};$",
    host,
    re.MULTILINE | re.DOTALL,
)
if not secret_match:
    raise SystemExit("start_runner_contract=failed reason=secret_projection_shape")
secret_block = secret_match.group("body")
for needle, reason in (
    ("file = ../../secrets/csb1-start-github-runner.age;", "secret_file"),
    ('path = "/run/agenix/csb1-start-github-runner";', "secret_path"),
    ('owner = "root";', "secret_owner"),
    ('group = "users";', "secret_group"),
    ('mode = "0440";', "secret_mode"),
):
    if secret_block.count(needle) != 1:
        raise SystemExit(f"start_runner_contract=failed reason={reason}")

require_exact(
    secrets,
    '"csb1-start-github-runner.age".publicKeys = markus ++ csb1;',
    1,
    "secret_recipients",
)
require_exact(
    workflow,
    "run: tests/T53-start-github-runner.sh",
    1,
    "workflow_wiring",
)

print("start_runner_contract=passed runner=csb1-start token_visible_to_jobs=false")
PY

if [[ -z "$mutation" ]]; then
  for fixture in \
    visible-token:token_source_visibility_override \
    missing-label:runner_label \
    sudo-expansion:no_new_privileges_override \
    missing-secret-gate:runner_secret_gate; do
    case_name=${fixture%%:*}
    expected_reason=${fixture#*:}
    mutation_output=""
    if mutation_output=$(bash "$0" "$case_name" 2>&1); then
      printf 'start_runner_contract=failed reason=mutation_accepted mutation=%s\n' \
        "$case_name" >&2
      exit 1
    fi
    if [[ "$mutation_output" != "start_runner_contract=failed reason=$expected_reason" ]]; then
      printf 'start_runner_contract=failed reason=mutation_wrong_verdict mutation=%s\n' \
        "$case_name" >&2
      exit 1
    fi
    printf 'start_runner_mutation=passed mutation=%s verdict=%s\n' \
      "$case_name" "$expected_reason"
  done
fi
