#!/usr/bin/env bash
#
# review-cursor-agent-bump.sh - prepare an evidence bundle for the manual
# Cursor CLI update re-review. It does not change the pin and does not decide
# whether a release is safe to ship.
# shellcheck disable=SC2016 # Markdown code spans in the report's printf formats are literal backticks
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
review_script=$repo_root/pkgs/cursor-agent/review-auto-update.mjs
sources_file=$repo_root/pkgs/cursor-agent/sources.json
update_script=$repo_root/scripts/update-cursor-agent.sh

usage() {
  cat <<'EOF' >&2
usage:
  review-cursor-agent-bump.sh [release] [--out directory]
  review-cursor-agent-bump.sh --from-bundles old-bundle new-bundle [--old-version version] [--new-version version] [--out directory]
EOF
  exit 2
}

die() {
  printf 'cursor-review: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found on PATH"
}

valid_version() {
  [[ $1 =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9a-f]{7,40}$ ]]
}

release=''
old_bundle=''
new_bundle=''
old_version=''
new_version=''
out_request=''
offline=0

while [ "$#" -gt 0 ]; do
  case "$1" in
  --from-bundles)
    [ "$offline" = 0 ] && [ -z "$release" ] && [ "$#" -ge 3 ] || usage
    offline=1
    old_bundle=$2
    new_bundle=$3
    shift 3
    ;;
  --old-version)
    [ "$#" -ge 2 ] || usage
    old_version=$2
    shift 2
    ;;
  --new-version)
    [ "$#" -ge 2 ] || usage
    new_version=$2
    shift 2
    ;;
  --out)
    [ "$#" -ge 2 ] || usage
    out_request=$2
    shift 2
    ;;
  -*)
    usage
    ;;
  *)
    [ "$offline" = 0 ] && [ -z "$release" ] || usage
    release=$1
    shift
    ;;
  esac
done

[ -f "$review_script" ] || die "review scanner is missing: $review_script"
require_tool git
require_tool jq
require_tool shasum

if [ "$offline" = 0 ]; then
  [ -f "$sources_file" ] || die "pin file is missing: $sources_file"
  [ -x "$update_script" ] || die "vendor check is missing or not executable: $update_script"
  current_version=$(jq -er '.version' "$sources_file") || die "pin file has no version"
  valid_version "$current_version" || die "pin has an unexpected release format: $current_version"

  if [ -z "$release" ]; then
    if check_output=$("$update_script" --check 2>&1); then
      check_status=0
    else
      check_status=$?
    fi
    if [[ $check_output =~ cursor-agent:[[:space:]]pin[[:space:]]([^[:space:]]+)[[:space:]]is[[:space:]]current ]]; then
      printf 'cursor-review: nothing to review (pin %s is current)\n' "${BASH_REMATCH[1]}"
      exit 0
    fi
    if [[ $check_output =~ cursor-agent:[[:space:]]pin[[:space:]]([^[:space:]]+)[[:space:]]is[[:space:]]behind[[:space:]]vendor[[:space:]]([^[:space:]]+) ]]; then
      release=${BASH_REMATCH[2]}
    else
      die "vendor check failed (exit $check_status): $check_output"
    fi
  fi
  valid_version "$release" || die "release has an unexpected format: $release"
  old_version=$current_version
  new_version=$release
else
  [ -d "$old_bundle" ] || die "old bundle is not a directory: $old_bundle"
  [ -d "$new_bundle" ] || die "new bundle is not a directory: $new_bundle"
  if [ -n "$old_version" ] && ! valid_version "$old_version"; then
    die "old version has an unexpected release format: $old_version"
  fi
  if [ -n "$new_version" ] && ! valid_version "$new_version"; then
    die "new version has an unexpected release format: $new_version"
  fi
fi

make_output_dir() {
  local label=$1 parent base candidate tmp_base
  label=${label//[^A-Za-z0-9._-]/_}
  [ -n "$label" ] || label=offline
  if [ -z "$out_request" ]; then
    tmp_base=${TMPDIR:-/tmp}
    [ -d "$tmp_base" ] || die "TMPDIR is not a directory: $tmp_base"
    output_dir=$(mktemp -d "$tmp_base/cursor-review-$label.XXXXXX") || die "cannot create output directory"
    return
  fi

  case "$out_request" in
  /*) ;;
  *) die "--out must be an absolute directory outside the repository" ;;
  esac
  parent=$(cd -- "$(dirname -- "$out_request")" && pwd -P) || die "--out parent does not exist: $(dirname -- "$out_request")"
  base=$(basename -- "$out_request")
  [ "$base" != . ] && [ "$base" != .. ] || die "--out must name a new directory"
  candidate=$parent/$base
  case "$candidate" in
  "$repo_root" | "$repo_root"/*) die "--out must stay outside the repository" ;;
  esac
  mkdir "$candidate" 2>/dev/null || die "--out must name a new directory: $candidate"
  output_dir=$(cd -- "$candidate" && pwd -P) || die "cannot resolve output directory: $candidate"
}

hash_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

truncate_tail() {
  local file=$1 drop=$2 size keep trimmed
  size=$(wc -c <"$file" | tr -d ' ')
  [ "$size" -ge "$drop" ] || die "scanner output ended before a complete region"
  keep=$((size - drop))
  trimmed=$file.trim
  head -c "$keep" "$file" >"$trimmed"
  mv "$trimmed" "$file"
}

region_headers=()
region_kinds=()
region_files=()

split_regions() {
  local input=$1 destination=$2 line current=-1 body=''
  local region_header_regex='^---[[:space:]]+([^@[:space:]]+)@[0-9]+[[:space:]]+\(([^)]*)\)$'
  region_headers=()
  region_kinds=()
  region_files=()
  mkdir "$destination"

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ $region_header_regex ]]; then
      if [ "$current" -ge 0 ]; then
        truncate_tail "$body" 2
      fi
      current=${#region_files[@]}
      body=$destination/$current.txt
      : >"$body"
      region_headers+=("$line")
      region_kinds+=("${BASH_REMATCH[2]}")
      region_files+=("$body")
    elif [ "$current" -ge 0 ]; then
      printf '%s\n' "$line" >>"$body"
    fi
  done <"$input"

  [ "$current" -ge 0 ] || die "scanner found no review regions in $input"
  truncate_tail "$body" 1
}

node_for_bundle() {
  local bundle=$1
  if [ -n "${CURSOR_REVIEW_NODE-}" ]; then
    printf '%s\n' "$CURSOR_REVIEW_NODE"
  elif [ -x "$bundle/node" ]; then
    printf '%s\n' "$bundle/node"
  else
    command -v node || die "node not found on PATH and $bundle/node is not executable"
  fi
}

scan_bundle() {
  local bundle=$1 hashes=$2 regions=$3 node_bin
  node_bin=$(node_for_bundle "$bundle")
  (
    cd -- "$bundle"
    "$node_bin" "$review_script" >"$hashes" 2>"$regions"
  ) || die "scan failed for $bundle"
  jq -e '(.occurrences | type == "object") and (.modules | type == "object")' "$hashes" >/dev/null ||
    die "scanner did not return hashes for $bundle"
}

count_in_javascript() {
  local bundle=$1 needle=$2 file found file_count count=0
  while IFS= read -r -d '' file; do
    found=$(LC_ALL=C grep -o -F -- "$needle" "$file" 2>/dev/null || true)
    if [ -n "$found" ]; then
      file_count=$(printf '%s\n' "$found" | wc -l | tr -d ' ')
      count=$((count + file_count))
    fi
  done < <(find "$bundle" -type f -name '*.js' -print0)
  printf '%s\n' "$count"
}

extract_export_names() {
  perl -0777 -ne '
    while (/\.d\([^,]+,\{([^}]*)\}\)/g) {
      for (split /,/, $1) {
        print "$1\n" if /^\s*([A-Za-z_\$][A-Za-z0-9_\$]*)\s*:/;
      }
    }
  ' "$1"
}

write_command_names() {
  local bundle=$1 destination=$2
  {
    grep -oE '\.command\("[^"]+' "$bundle/index.js" 2>/dev/null || true
  } | sed -E 's/^\.command\("//' | LC_ALL=C sort -u >"$destination"
}

write_scan_diagnostics() {
  local label=$1 regions=$2
  if grep -q '^problem:' "$regions"; then
    printf -- '- %s:\n' "$label" >>"$report"
    sed -n 's/^problem:/  - /p' "$regions" >>"$report"
  else
    printf -- '- %s: none\n' "$label" >>"$report"
  fi
}

write_wider_scan() {
  local old_export_file=$output_dir/.exports-old.txt new_export_file=$output_dir/.exports-new.txt
  local old_commands=$output_dir/.commands-old.txt new_commands=$output_dir/.commands-new.txt
  local added_commands=$output_dir/.commands-added.txt removed_commands=$output_dir/.commands-removed.txt
  local name old_count new_count status file

  {
    for file in "${old_files[@]}"; do
      extract_export_names "$file"
    done
  } | LC_ALL=C sort -u >"$old_export_file"
  {
    for file in "${new_files[@]}"; do
      extract_export_names "$file"
    done
  } | LC_ALL=C sort -u >"$new_export_file"
  {
    sed -n 'p' "$old_export_file"
    sed -n 'p' "$new_export_file"
  } | LC_ALL=C sort -u >"$output_dir/.exports-all.txt"

  printf '\n## Wider scan\n\n' >>"$report"
  printf '| name | old | new | status |\n| --- | ---: | ---: | --- |\n' >>"$report"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    old_count=$(count_in_javascript "$old_bundle" "$name")
    new_count=$(count_in_javascript "$new_bundle" "$name")
    status=unchanged
    [ "$old_count" = "$new_count" ] || status='COUNT CHANGED'
    printf '| `%s` | %s | %s | %s |\n' "$name" "$old_count" "$new_count" "$status" >>"$report"
  done <"$output_dir/.exports-all.txt"
  for name in isAutoUpdate .local/share/cursor-agent .local/bin process.argv; do
    old_count=$(count_in_javascript "$old_bundle" "$name")
    new_count=$(count_in_javascript "$new_bundle" "$name")
    status=unchanged
    [ "$old_count" = "$new_count" ] || status='COUNT CHANGED'
    printf '| `%s` | %s | %s | %s |\n' "$name" "$old_count" "$new_count" "$status" >>"$report"
  done

  write_command_names "$old_bundle" "$old_commands"
  write_command_names "$new_bundle" "$new_commands"
  LC_ALL=C comm -13 "$old_commands" "$new_commands" >"$added_commands"
  LC_ALL=C comm -23 "$old_commands" "$new_commands" >"$removed_commands"
  printf '\nCommand names in `index.js`:\n\n' >>"$report"
  if [ -s "$added_commands" ]; then
    printf '%s\n' 'Added:' >>"$report"
    sed 's/^/- `/' "$added_commands" | sed 's/$/`/' >>"$report"
  else
    printf '%s\n' 'Added: none' >>"$report"
  fi
  if [ -s "$removed_commands" ]; then
    printf '%s\n' 'Removed:' >>"$report"
    sed 's/^/- `/' "$removed_commands" | sed 's/$/`/' >>"$report"
  else
    printf '%s\n' 'Removed: none' >>"$report"
  fi
}

if [ "$offline" = 0 ]; then
  require_tool nix
  require_tool nix-prefetch-url
  system=$(nix eval --impure --raw --expr builtins.currentSystem) || die "cannot determine current Nix system"
  case "$system" in
  '' | *[!A-Za-z0-9_-]*) die "unexpected Nix system: $system" ;;
  esac
  asset=$(jq -er --arg system "$system" '.assets[$system]' "$sources_file") ||
    die "no Cursor asset for current system: $system"
  os=$(jq -er '.os' <<<"$asset") || die "asset has no operating system"
  arch=$(jq -er '.arch' <<<"$asset") || die "asset has no architecture"
  url=https://downloads.cursor.com/lab/$release/$os/$arch/agent-cli-package.tar.gz
  prefetched_hash=$(nix-prefetch-url "$url") || die "prefetch failed for $url"
  sri=$(nix hash convert --hash-algo sha256 --to sri "$prefetched_hash") || die "cannot convert prefetched hash to SRI"
  nix_root=$(printf '%s' "$repo_root" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  review_expr="let f = builtins.getFlake (toString \"$nix_root\"); pkgs = f.inputs.nixpkgs.legacyPackages.$system; in f.packages.$system.cursor-agent.overrideAttrs (o: { version = \"$release\"; src = pkgs.fetchurl { url = \"$url\"; hash = \"$sri\"; }; doInstallCheck = false; })"
  new_tree=$(nix build --impure --no-link --print-out-paths --expr "$review_expr") || die "review build failed for $release"
  old_tree=$(nix build --no-link --print-out-paths "$repo_root#packages.$system.cursor-agent") || die "pinned package build failed"
  old_bundle=$old_tree/share/cursor-agent
  new_bundle=$new_tree/share/cursor-agent
  [ -d "$old_bundle" ] || die "pinned package did not contain a Cursor bundle: $old_bundle"
  [ -d "$new_bundle" ] || die "review build did not contain a Cursor bundle: $new_bundle"
fi

make_output_dir "${new_version:-offline}"
report=$output_dir/report.md
hashes_new=$output_dir/hashes-new.json
regions_old=$output_dir/regions-old.txt
regions_new=$output_dir/regions-new.txt
hashes_old=$output_dir/.hashes-old.json

scan_bundle "$old_bundle" "$hashes_old" "$regions_old"
scan_bundle "$new_bundle" "$hashes_new" "$regions_new"
split_regions "$regions_old" "$output_dir/.regions-old"
old_headers=("${region_headers[@]}")
old_kinds=("${region_kinds[@]}")
old_files=("${region_files[@]}")
split_regions "$regions_new" "$output_dir/.regions-new"
new_headers=("${region_headers[@]}")
new_kinds=("${region_kinds[@]}")
new_files=("${region_files[@]}")

candidate_version=${new_version:-unknown}
jq --arg reviewed "$candidate_version" \
  --arg review 'PENDING REVIEW: replace with the reviewer'\''s findings' \
  '{ reviewed: $reviewed, review: $review, occurrences: .occurrences, modules: .modules }' \
  "$hashes_new" >"$output_dir/candidate-review.json" || die "cannot write candidate review"

old_total=${#old_files[@]}
new_total=${#new_files[@]}
old_used=()
for ((index = 0; index < old_total; index++)); do
  old_used[index]=0
done

{
  printf '# Cursor CLI bump re-review\n\n'
  printf 'This report is review evidence, not a safety verdict.\n\n'
  printf -- '- Old bundle: `%s`\n' "$old_bundle"
  printf -- '- New bundle: `%s`\n' "$new_bundle"
  printf -- '- Old version: `%s`\n' "${old_version:-not supplied}"
  printf -- '- New version: `%s`\n' "${new_version:-not supplied}"
  printf -- '- Candidate review: `candidate-review.json`\n'
  printf '\n## Scanner diagnostics\n\n'
} >"$report"
write_scan_diagnostics old "$regions_old"
write_scan_diagnostics new "$regions_new"

printf '\n## Region totals\n\n' >>"$report"
{
  printf '%s\n' "${old_kinds[@]}"
  printf '%s\n' "${new_kinds[@]}"
} | LC_ALL=C sort -u >"$output_dir/.kinds.txt"
while IFS= read -r kind; do
  [ -n "$kind" ] || continue
  old_kind_count=0
  new_kind_count=0
  for value in "${old_kinds[@]}"; do
    [ "$value" = "$kind" ] && old_kind_count=$((old_kind_count + 1))
  done
  for value in "${new_kinds[@]}"; do
    [ "$value" = "$kind" ] && new_kind_count=$((new_kind_count + 1))
  done
  kind_status=unchanged
  [ "$old_kind_count" = "$new_kind_count" ] || kind_status='COUNT CHANGED'
  printf -- '- `%s`: old %s, new %s, %s\n' "$kind" "$old_kind_count" "$new_kind_count" "$kind_status" >>"$report"
done <"$output_dir/.kinds.txt"
printf -- '- Total regions: old %s, new %s\n' "$old_total" "$new_total" >>"$report"

printf '\n## Region comparison\n' >>"$report"
word_regex='[A-Za-z0-9_$]+|[^[:space:]]'
changed_total=0
reference_total=0
identical_references=0
module_total=0
identical_modules=0
version_only_modules=0
new_unpaired=0

for ((new_index = 0; new_index < new_total; new_index++)); do
  new_kind=${new_kinds[new_index]}
  new_file=${new_files[new_index]}
  match=-1
  for ((old_index = 0; old_index < old_total; old_index++)); do
    [ "${old_used[old_index]}" = 0 ] || continue
    [ "${old_kinds[old_index]}" = "$new_kind" ] || continue
    if cmp -s "${old_files[old_index]}" "$new_file"; then
      match=$old_index
      break
    fi
  done

  comparison=identical
  if [ "$match" -lt 0 ]; then
    best_size=-1
    for ((old_index = 0; old_index < old_total; old_index++)); do
      [ "${old_used[old_index]}" = 0 ] || continue
      [ "${old_kinds[old_index]}" = "$new_kind" ] || continue
      candidate_diff=$output_dir/.word-diff-$new_index-$old_index.porcelain
      if git diff --no-index --word-diff=porcelain --word-diff-regex="$word_regex" \
        "${old_files[old_index]}" "$new_file" >"$candidate_diff"; then
        diff_status=0
      else
        diff_status=$?
      fi
      [ "$diff_status" -le 1 ] || die "cannot compare ${old_headers[old_index]} and ${new_headers[new_index]}"
      candidate_size=$(wc -c <"$candidate_diff" | tr -d ' ')
      if [ "$best_size" -lt 0 ] || [ "$candidate_size" -lt "$best_size" ]; then
        best_size=$candidate_size
        match=$old_index
      fi
    done
    if [ "$match" -ge 0 ]; then
      comparison=changed
    else
      comparison=unpaired
    fi
  fi

  printf '\n### `%s`\n\n' "${new_headers[new_index]}" >>"$report"
  if [ "$match" -lt 0 ]; then
    printf '%s\n' '- status: unpaired new region' >>"$report"
    new_unpaired=$((new_unpaired + 1))
    continue
  fi

  old_used[match]=1
  printf -- '- Old: `%s`\n' "${old_headers[match]}" >>"$report"
  printf -- '- New: `%s`\n' "${new_headers[new_index]}" >>"$report"
  if [ "$comparison" = identical ]; then
    region_hash=$(hash_file "$new_file")
    if jq -e --arg hash "$region_hash" '(.occurrences[$hash] // 0) + (.modules[$hash] // 0) > 0' "$hashes_old" >/dev/null; then
      printf -- '- status: identical (old scan hash `%s`)\n' "$region_hash" >>"$report"
    else
      printf -- '- status: identical (hash `%s` was not found in the old scan output)\n' "$region_hash" >>"$report"
    fi
  else
    printf '%s\n' '- status: changed; closest remaining old region of the same kind' >>"$report"
    printf '\n```diff\n' >>"$report"
    # Keep report headers relative to the output directory, not its temp root.
    if git -C "$output_dir" diff --no-index --word-diff=plain --word-diff-regex="$word_regex" \
      -- "${old_files[match]#"$output_dir/"}" "${new_file#"$output_dir/"}" >>"$report"; then
      diff_status=0
    else
      diff_status=$?
    fi
    [ "$diff_status" -le 1 ] || die "cannot write word diff for ${new_headers[new_index]}"
    printf '```\n' >>"$report"
    changed_total=$((changed_total + 1))
  fi

  if [ "$new_kind" = 'updater module' ]; then
    module_total=$((module_total + 1))
    [ "$comparison" = identical ] && identical_modules=$((identical_modules + 1))
    if [ -n "$old_version" ] && [ -n "$new_version" ]; then
      version_candidate=$output_dir/.version-only-$new_index.txt
      version_literal_count=$(grep -o -F -- "$old_version" "${old_files[match]}" 2>/dev/null | wc -l | tr -d ' ' || true)
      OLD="$old_version" NEW="$new_version" perl -pe 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "${old_files[match]}" >"$version_candidate"
      if cmp -s "$version_candidate" "$new_file"; then
        printf -- '- version literals only: true (%s old-version literals)\n' "$version_literal_count" >>"$report"
        version_only_modules=$((version_only_modules + 1))
      else
        printf -- '- version literals only: false (%s old-version literals)\n' "$version_literal_count" >>"$report"
      fi
    else
      printf '%s\n' '- version literals only: not assessed (versions not supplied)' >>"$report"
    fi
  else
    reference_total=$((reference_total + 1))
    [ "$comparison" = identical ] && identical_references=$((identical_references + 1))
  fi
done

old_unpaired=0
for ((old_index = 0; old_index < old_total; old_index++)); do
  [ "${old_used[old_index]}" = 1 ] && continue
  old_unpaired=$((old_unpaired + 1))
  printf '\n### `%s`\n\n- status: unpaired old region\n' "${old_headers[old_index]}" >>"$report"
done

write_wider_scan

cat >>"$report" <<'EOF'

## Reviewer checklist

- [ ] The option is defined once, with default false.
- [ ] The option is forwarded unchanged.
- [ ] Every automatic update is behind the `disableAutoUpdate` guard with the forwarded value.
- [ ] Explicit updater calls set `isAutoUpdate` false.
- [ ] Update-core copies do not invoke their updater.
- [ ] Wrapper argv assumptions still hold: raw argv readers keyed on `argv[2]` and the chat entry points.
- [ ] There is no new update or write path.

## Pin steps after owner approval

1. Write the reviewer findings into `candidate-review.json`.
2. Copy it to `pkgs/cursor-agent/auto-update-review.json`.
3. Run `scripts/update-cursor-agent.sh`.
4. Run T85 and gate as usual.
5. Keep the manual re-review: it remains the owner decision recorded on NIX-523.
EOF

printf 'cursor-review: output directory %s\n' "$output_dir"
printf 'cursor-review: %s old regions, %s new; %s/%s references identical, %s/%s modules identical, %s/%s modules version literals only; %s changed, %s new unpaired, %s old unpaired\n' \
  "$old_total" "$new_total" "$identical_references" "$reference_total" "$identical_modules" "$module_total" \
  "$version_only_modules" "$module_total" "$changed_total" "$new_unpaired" "$old_unpaired"
printf 'cursor-review: read %s, complete the checklist, then decide manually; this report is advisory.\n' "$report"
