#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image='ghcr.io/markus-barta/pharos/pharosd:0.1.23'
collector_path='PHAROS_CURRENT_KERNEL_MODULES_DIR=/host/run/current-system/kernel-modules/lib/modules'
collector_mount='/run/current-system/kernel-modules/lib/modules:/host/run/current-system/kernel-modules/lib/modules:ro'

assert_count() {
  local expected=$1
  local needle=$2
  local file=$3
  [[ "$(grep -Fc -- "$needle" "$file")" == "$expected" ]]
}

csb0="$repo_root/hosts/csb0/docker/docker-compose.yml"
csb1="$repo_root/hosts/csb1/docker/docker-compose.yml"
hsb0="$repo_root/hosts/hsb0/docker/docker-compose.yml"
hsb1="$repo_root/hosts/hsb1/docker/docker-compose.yml"
hsb8="$repo_root/hosts/hsb8/docker/docker-compose.yml"
hsb9="$repo_root/hosts/hsb9/docker/docker-compose.yml"

assert_count 1 "image: $image" "$csb0"
assert_count 1 "$collector_path" "$csb0"
assert_count 1 "$collector_mount" "$csb0"

assert_count 2 "image: $image" "$csb1"
assert_count 1 "$collector_path" "$csb1"
assert_count 1 "$collector_mount" "$csb1"

assert_count 1 "image: $image" "$hsb0"
assert_count 1 "$collector_path" "$hsb0"
assert_count 1 "$collector_mount" "$hsb0"

assert_count 1 "image: $image" "$hsb1"
assert_count 1 "$collector_path" "$hsb1"
assert_count 1 "$collector_mount" "$hsb1"

assert_count 1 "image: $image" "$hsb8"
assert_count 1 "$collector_path" "$hsb8"
assert_count 1 "$collector_mount" "$hsb8"

assert_count 1 "image: $image" "$hsb9"
assert_count 1 "$collector_path" "$hsb9"
assert_count 1 "$collector_mount" "$hsb9"

echo "pharos_kernel_posture=passed"
