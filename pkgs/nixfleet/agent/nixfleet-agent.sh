#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                           NIXFLEET AGENT                                     ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Polls the NixFleet dashboard for commands and executes them.
# Supports both NixOS (nixos-rebuild) and macOS (home-manager).
#
# Usage: nixfleet-agent.sh
#
# Environment:
#   NIXFLEET_URL      - Dashboard URL (default: https://fleet.barta.cm)
#   NIXFLEET_TOKEN    - API authentication token (required in production)
#   NIXFLEET_NIXCFG   - Path to nixcfg repository (default: ~/Code/nixcfg)
#   NIXFLEET_INTERVAL - Poll interval in seconds (default: 60)
#
# Requirements:
#   - curl
#   - jq (for JSON parsing)
#   - git
#   - nixos-rebuild (NixOS) or home-manager (macOS)

set -euo pipefail

# ════════════════════════════════════════════════════════════════════════════════
# Configuration
# ════════════════════════════════════════════════════════════════════════════════

readonly NIXFLEET_URL="${NIXFLEET_URL:-https://fleet.barta.cm}"
readonly NIXFLEET_TOKEN="${NIXFLEET_TOKEN:-}"
readonly NIXFLEET_NIXCFG="${NIXFLEET_NIXCFG:-$HOME/Code/nixcfg}"
readonly NIXFLEET_INTERVAL="${NIXFLEET_INTERVAL:-60}"

# Host detection - always get short hostname (strip domain)
DETECTED_HOSTNAME="$(hostname -s 2>/dev/null || hostname)"
# Strip any domain suffix if hostname -s didn't work
readonly HOST_ID="${DETECTED_HOSTNAME%%.*}"
readonly HOSTNAME="${HOST_ID}" # For backwards compatibility

# ════════════════════════════════════════════════════════════════════════════════
# Host Type Detection
# ════════════════════════════════════════════════════════════════════════════════

detect_host_type() {
  if [[ -f /etc/NIXOS ]]; then
    echo "nixos"
  elif [[ "$(uname)" == "Darwin" ]]; then
    echo "macos"
  else
    echo "linux"
  fi
}

detect_location() {
  case "$HOSTNAME" in
  hsb* | gpc* | imac*) echo "home" ;;
  csb*) echo "cloud" ;;
  mba-*-work) echo "work" ;;
  *) echo "" ;;
  esac
}

detect_criticality() {
  case "$HOSTNAME" in
  hsb0 | csb0) echo "high" ;;
  hsb1 | hsb8 | csb1) echo "medium" ;;
  *) echo "low" ;;
  esac
}

HOST_TYPE="$(detect_host_type)"
readonly HOST_TYPE
LOCATION="$(detect_location)"
readonly LOCATION
CRITICALITY="$(detect_criticality)"
readonly CRITICALITY

# ════════════════════════════════════════════════════════════════════════════════
# Logging
# ════════════════════════════════════════════════════════════════════════════════

log() {
  local level="$1"
  shift
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >&2
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# ════════════════════════════════════════════════════════════════════════════════
# Prerequisites Check
# ════════════════════════════════════════════════════════════════════════════════

check_prerequisites() {
  local missing=()

  command -v curl &>/dev/null || missing+=("curl")
  command -v jq &>/dev/null || missing+=("jq")
  command -v git &>/dev/null || missing+=("git")

  if [[ "$HOST_TYPE" == "nixos" ]]; then
    command -v nixos-rebuild &>/dev/null || missing+=("nixos-rebuild")
  elif [[ "$HOST_TYPE" == "macos" ]]; then
    command -v home-manager &>/dev/null || missing+=("home-manager")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required commands: ${missing[*]}"
    exit 1
  fi

  if [[ ! -d "$NIXFLEET_NIXCFG" ]]; then
    log_error "nixcfg directory not found: $NIXFLEET_NIXCFG"
    exit 1
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
# API Helpers
# ════════════════════════════════════════════════════════════════════════════════

api_call() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  local args=(-sf -X "$method")
  args+=(-H "Content-Type: application/json")

  if [[ -n "$NIXFLEET_TOKEN" ]]; then
    args+=(-H "Authorization: Bearer $NIXFLEET_TOKEN")
  fi

  if [[ -n "$data" ]]; then
    args+=(-d "$data")
  fi

  curl "${args[@]}" "${NIXFLEET_URL}${endpoint}" 2>/dev/null
}

# ════════════════════════════════════════════════════════════════════════════════
# Host Information (with caching)
# ════════════════════════════════════════════════════════════════════════════════

# Cache file for git hash (avoid calling git every poll)
readonly GIT_HASH_CACHE="/tmp/nixfleet-git-hash-${HOST_ID}"

refresh_git_hash() {
  # Fetch git hash and update cache - call after pull/switch
  local hash
  # Use -c to bypass safe.directory check (root running on user-owned repo)
  if hash=$(git -c safe.directory="$NIXFLEET_NIXCFG" -C "$NIXFLEET_NIXCFG" rev-parse HEAD 2>/dev/null); then
    :
  else
    hash="unknown"
  fi
  echo "$hash" >"$GIT_HASH_CACHE"
  echo "$hash"
}

get_git_hash() {
  # Read from cache, or refresh if cache doesn't exist
  if [[ -f "$GIT_HASH_CACHE" ]]; then
    cat "$GIT_HASH_CACHE"
  else
    refresh_git_hash
  fi
}

get_generation() {
  # Return current git hash
  get_git_hash
}

get_test_status() {
  local test_dir="$NIXFLEET_NIXCFG/hosts/$HOSTNAME/tests"

  if [[ ! -d "$test_dir" ]]; then
    echo "no tests"
    return
  fi

  local count=0
  for script in "$test_dir"/T*.sh; do
    [[ -f "$script" ]] && ((count++))
  done

  if [[ $count -eq 0 ]]; then
    echo "no tests"
  else
    echo "$count tests"
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
# Registration
# ════════════════════════════════════════════════════════════════════════════════

register() {
  local gen
  gen="$(get_generation)"

  log_info "Registering: $HOSTNAME ($HOST_TYPE, $LOCATION, $CRITICALITY)"

  local payload
  payload=$(jq -n \
    --arg hostname "$HOSTNAME" \
    --arg host_type "$HOST_TYPE" \
    --arg location "$LOCATION" \
    --arg criticality "$CRITICALITY" \
    --arg generation "$gen" \
    --arg config_repo "$NIXFLEET_NIXCFG" \
    '{
            hostname: $hostname,
            host_type: $host_type,
            location: $location,
            criticality: $criticality,
            current_generation: $generation,
            config_repo: $config_repo
        }')

  if api_call POST "/api/hosts/${HOST_ID}/register" "$payload" >/dev/null; then
    log_info "Registration successful"
  else
    log_warn "Registration failed (will retry)"
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
# Polling
# ════════════════════════════════════════════════════════════════════════════════

poll_command() {
  local response
  response=$(api_call GET "/api/hosts/${HOST_ID}/poll" || echo '{"command": null}')

  # Use jq for robust JSON parsing
  echo "$response" | jq -r '.command // empty'
}

# ════════════════════════════════════════════════════════════════════════════════
# Status Reporting
# ════════════════════════════════════════════════════════════════════════════════

report_status() {
  local status="$1"
  local gen="$2"
  local output="${3:-}"
  local test_status="${4:-}"

  # Truncate output to 10KB and escape for JSON
  local truncated_output
  truncated_output=$(echo "$output" | head -c 10000)

  local payload
  payload=$(jq -n \
    --arg status "$status" \
    --arg generation "$gen" \
    --arg output "$truncated_output" \
    --arg test_status "$test_status" \
    '{
            status: $status,
            current_generation: $generation,
            output: (if $output == "" then null else $output end),
            test_status: (if $test_status == "" then null else $test_status end)
        }')

  if api_call POST "/api/hosts/${HOST_ID}/status" "$payload" >/dev/null; then
    log_info "Status reported: $status"
  else
    log_warn "Failed to report status"
  fi
}

report_test_progress() {
  local current="$1"
  local total="$2"
  local passed="$3"
  local running="$4"
  local result="${5:-}"
  local comment="${6:-}"

  local payload
  payload=$(jq -n \
    --argjson current "$current" \
    --argjson total "$total" \
    --argjson passed "$passed" \
    --argjson running "$running" \
    --arg result "$result" \
    --arg comment "$comment" \
    '{
            current: $current,
            total: $total,
            passed: $passed,
            running: $running,
            result: (if $result == "" then null else $result end),
            comment: (if $comment == "" then null else $comment end)
        }')

  api_call POST "/api/hosts/${HOST_ID}/test-progress" "$payload" >/dev/null 2>&1 || true
}

# ════════════════════════════════════════════════════════════════════════════════
# Command Execution
# ════════════════════════════════════════════════════════════════════════════════

do_pull() {
  log_info "Executing: git pull"
  cd "$NIXFLEET_NIXCFG"

  local output
  # Use -c safe.directory to allow root to access user-owned repo
  if output=$(git -c safe.directory="$NIXFLEET_NIXCFG" pull 2>&1); then
    log_info "Pull successful"
    refresh_git_hash >/dev/null # Update cached hash after pull
    report_status "ok" "$(get_generation)" "$output"
    return 0
  else
    log_error "Pull failed"
    report_status "error" "$(get_generation)" "$output"
    return 1
  fi
}

do_switch() {
  log_info "Executing: switch ($HOST_TYPE)"
  cd "$NIXFLEET_NIXCFG"

  local output
  local exit_code=0

  if [[ "$HOST_TYPE" == "nixos" ]]; then
    if output=$(sudo nixos-rebuild switch --flake ".#${HOSTNAME}" 2>&1); then
      log_info "Switch successful"
    else
      exit_code=1
      log_error "Switch failed"
    fi
  else
    local user="${USER:-$(whoami)}"
    if output=$(home-manager switch --flake ".#${user}@${HOSTNAME}" 2>&1); then
      log_info "Switch successful"
    else
      exit_code=1
      log_error "Switch failed"
    fi
  fi

  local gen
  gen="$(get_generation)"

  if [[ $exit_code -eq 0 ]]; then
    report_status "ok" "$gen" "$output"
  else
    report_status "error" "$gen" "$output"
  fi

  return $exit_code
}

do_test() {
  log_info "Executing: test suite"
  cd "$NIXFLEET_NIXCFG"

  local test_dir="hosts/$HOSTNAME/tests"

  if [[ ! -d "$test_dir" ]]; then
    log_info "No tests directory"
    report_test_progress 0 0 0 false "no tests"
    report_status "ok" "$(get_generation)" "No tests found" "no tests"
    return 0
  fi

  # Count total tests first
  local total=0
  for script in "$test_dir"/T*.sh; do
    [[ -f "$script" ]] && ((total++))
  done

  local current=0 passed=0 failed=0
  local output=""
  local fail_comment=""

  # Report initial progress
  report_test_progress 0 "$total" 0 true

  for script in "$test_dir"/T*.sh; do
    [[ -f "$script" ]] || continue
    ((current++))

    local name
    name=$(basename "$script" .sh)
    log_info "Running $name..."

    # Report progress before running test
    report_test_progress "$current" "$total" "$passed" true

    local result
    if result=$("$script" 2>&1); then
      ((passed++))
      output+="✅ $name"$'\n'
    else
      ((failed++))
      output+="❌ $name: ${result:0:100}"$'\n'
      [[ -z "$fail_comment" ]] && fail_comment="$name failed"
    fi
  done

  local test_status="$passed/$total pass"
  [[ $failed -gt 0 ]] && test_status="$passed/$total pass, $failed fail"

  log_info "Tests complete: $test_status"

  # Report final progress (running=false)
  report_test_progress "$total" "$total" "$passed" false "$test_status" "$fail_comment"

  if [[ $failed -eq 0 ]]; then
    report_status "ok" "$(get_generation)" "$output" "$test_status"
  else
    report_status "error" "$(get_generation)" "$output" "$test_status"
  fi

  return $failed
}

# ════════════════════════════════════════════════════════════════════════════════
# Main Loop
# ════════════════════════════════════════════════════════════════════════════════

main() {
  log_info "╔══════════════════════════════════════════════════════════════╗"
  log_info "║                    NixFleet Agent Starting                   ║"
  log_info "╚══════════════════════════════════════════════════════════════╝"
  log_info "URL:         $NIXFLEET_URL"
  log_info "Host:        $HOSTNAME ($HOST_TYPE)"
  log_info "Location:    ${LOCATION:-unknown}"
  log_info "Criticality: $CRITICALITY"
  log_info "nixcfg:      $NIXFLEET_NIXCFG"
  log_info "Interval:    ${NIXFLEET_INTERVAL}s"

  check_prerequisites

  # Cache git hash at startup (avoids repeated git calls)
  refresh_git_hash >/dev/null

  register

  while true; do
    local command
    command=$(poll_command)

    if [[ -n "$command" ]]; then
      log_info "Received command: $command"

      case "$command" in
      pull)
        do_pull || true
        ;;
      switch)
        do_switch || true
        ;;
      pull-switch)
        if do_pull; then
          do_switch || true
        fi
        ;;
      test)
        do_test || true
        ;;
      *)
        log_warn "Unknown command: $command"
        report_status "error" "$(get_generation)" "Unknown command: $command"
        ;;
      esac
    fi

    sleep "$NIXFLEET_INTERVAL"
  done
}

# Run
main "$@"
