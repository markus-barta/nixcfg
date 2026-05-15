# Use `just <recipe>` to run a recipe
# https://just.systems/man/en/

import ".shared/common.just"

# By default, run the `--list` command
default:
    @just --list

# Set default shell to bash

set shell := ["bash", "-c"]

# Variables
# Raw hostname from system

[private]
_raw_hostname := `hostname -s`

# Hostname mapping: normalize WiFi/DHCP variants to flake config names
# imac0w → imac0, imac1w → imac1

hostname := if _raw_hostname == "imac0w" { "imac0" } else if _raw_hostname == "imac1w" { "imac1" } else { _raw_hostname }
user := `whoami`

# Aliases

alias s := switch
alias ss := switch-simple
alias hs := home-switch
alias u := upgrade
alias c := cleanup
alias b := build
alias bh := build-on-home01
alias bc := build-on-caliban
alias p := push
alias sp := switch-push
alias fix-command-not-found-error := update-channels
alias options := hokage-options

# Notify the user with neosay
@_notify text:
    if test -f ~/.config/neosay/config.json; then echo "❄️ nixcfg {{ text }}" | neosay; fi

[group('build')]
test:
    sudo nixos-rebuild test --flake .#{{ hostname }} -L

# Careful: This can use a lot of memory on large flakes

# https://nix.dev/manual/nix/2.18/command-ref/new-cli/nix3-flake-check.html
[group('build')]
check-high-memory:
    nix flake check --no-build --keep-going

# Careful: This can use a lot of memory on large flakes
[group('build')]
check-trace-high-memory:
    nix flake check --no-build --show-trace

# Check all hosts configured in the flake.nix
[group('build')]
check-all:
    #!/usr/bin/env bash
    echo "🔍 Checking all hosts configured in flake.nix..."

    # Extract host names from flake.nix nixosConfigurations
    hosts=($(nix eval --raw .#nixosConfigurations --apply 'pkgs: builtins.concatStringsSep " " (builtins.attrNames pkgs)'))

    if [ ${#hosts[@]} -eq 0 ]; then
        echo "❌ No hosts found in flake.nix"
        exit 1
    fi

    echo "📋 Found ${#hosts[@]} hosts: ${hosts[*]}"
    echo ""

    failed_hosts=()
    successful_hosts=()

    for host in "${hosts[@]}"; do
        echo "📋 Checking host: $host"
        if just check-host "$host" > /dev/null 2>&1; then
            echo "✅ $host: OK"
            successful_hosts+=("$host")
        else
            echo "❌ $host: FAILED"
            failed_hosts+=("$host")
        fi
    done

    echo ""
    echo "📊 Summary:"
    echo "✅ Successful hosts (${#successful_hosts[@]}): ${successful_hosts[*]}"
    if [ ${#failed_hosts[@]} -gt 0 ]; then
        echo "❌ Failed hosts (${#failed_hosts[@]}): ${failed_hosts[*]}"
        echo ""
        echo "Run 'just check-host <hostname>' for detailed error information."
        exit 1
    else
        echo "🎉 All hosts checked successfully!"
    fi

# Checks if the configuration of a host can be built
[group('build')]
check-host hostname:
    nix eval .#nixosConfigurations.{{ hostname }}.config.system.build.toplevel.drvPath

# Checks if the current host configuration can be built
[group('build')]
check:
    just check-host {{ hostname }}

[group('build')]
nix-switch:
    sudo nixos-rebuild switch --flake .#{{ hostname }} -L

# Build and switch to the new configuration for the current host (no notification)
[group('build')]
switch-simple:
    nh os switch -H {{ hostname }} .

# Build and switch to the new configuration for the current host (platform-aware)
[group('build')]
switch args='':
    #!/usr/bin/env bash
    # Detect platform and route to appropriate command
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "$(printf '\xef\x85\xb9') Detected macOS - running 🏠 home-manager switch for {{ user }}@{{ hostname }}..."
        start_time=$(date +%s)
        home-manager switch --flake ".#{{ user }}@{{ hostname }}" {{ args }}
        end_time=$(date +%s)
        exit_code=$?
        runtime=$((end_time - start_time))
        if [ $runtime -gt 10 ]; then
          just _notify "home-manager switch finished for {{ user }}@{{ hostname }}, exit code: $exit_code (runtime: ${runtime}s)"
        fi
    else
        echo "$(printf '\xef\x8c\x93') Detected NixOS - running ❄️ nixos-rebuild switch for {{ hostname }}..."
        sudo true
        start_time=$(date +%s)
        nh os switch -H {{ hostname }} . -- {{ args }}
        end_time=$(date +%s)
        exit_code=$?
        runtime=$((end_time - start_time))
        if [ $runtime -gt 10 ]; then
          just _notify "switch finished on {{ hostname }}, exit code: $exit_code (runtime: ${runtime}s)"
        fi
    fi

# NIX-105: Defensive `home-manager switch` wrapper for macOS hosts.
# Catches the conflict pattern that brick'd imac0 on 2026-05-05:
# an imperative `nix profile install` package + the SAME package added
# to home.nix → HM activation aborts mid-tear-down → critical binaries
# (fish, home-manager itself) vanish from ~/.nix-profile/bin → if the
# user's login shell points there, no terminal can open until GUI shell
# reset. See ~/Code/inspr/playbook.md "Day-5 EVENING amendment" for the
# full incident write-up + canonical recovery sequence.
[group('build')]
safe-switch args='':
    #!/usr/bin/env bash
    if [[ "$OSTYPE" != "darwin"* ]]; then
        echo "❌ safe-switch is macOS-only (the conflict pattern is HM-standalone-specific)."
        echo "   For NixOS hosts, use \`just switch\` (failure modes differ)."
        exit 2
    fi

    echo ""
    echo "🔍 Pre-flight checks for home-manager switch on {{ user }}@{{ hostname }} ..."
    echo ""

    # ── Pre-flight 1: imperative `nix profile` entries ──────────────────
    # Detects the exact conflict pattern from the 2026-05-05 incident.
    # Heuristic: just LIST imperative entries + warn. We don't try to
    # statically predict which ones will conflict with the new HM
    # generation — too brittle. User decides whether to proceed.
    echo "  [1/3] Imperative \`nix profile\` entries (potential conflicts) ..."
    # Filter:
    # - Strip ANSI color codes (nix uses bold for entry names)
    # - Drop `home-manager-path` (HM's OWN entry — not a conflict candidate)
    profile_entries=$(nix profile list 2>/dev/null \
        | sed $'s/\x1b\[[0-9;]*m//g' \
        | grep -E "^Name:" \
        | sed 's/^Name:[[:space:]]*//' \
        | grep -v "^home-manager-path$" || true)
    if [[ -z "$profile_entries" ]]; then
        echo "        ✓ no imperative entries — clean profile, no conflict risk"
    else
        echo "        ⚠️  Imperative entries found (alongside home-manager-path):"
        echo "$profile_entries" | sed 's/^/             • /'
        echo ""
        echo "        These MAY conflict if HM is about to install the same package."
        echo "        If yes: \`nix profile remove <name>\` BEFORE the switch to avoid"
        echo "        a half-torn-down profile. (Playbook 2026-05-05 EVENING.)"
    fi
    echo ""

    # ── Pre-flight 2: login shell dependency on Nix profile ─────────────
    # If the login shell points into ~/.nix-profile/bin/ AND a switch
    # tears down the profile, the user loses terminal access until a
    # GUI shell-reset. Surface the risk; don't block.
    echo "  [2/3] Login shell dependency on \$HOME/.nix-profile/bin ..."
    login_shell=$(dscl . -read /Users/{{ user }} UserShell 2>/dev/null | awk '{print $2}')
    if [[ "$login_shell" == "$HOME/.nix-profile/bin/"* ]]; then
        echo "        ⚠️  Your login shell is in the Nix profile:"
        echo "             $login_shell"
        echo "        If this switch tears down the profile, you'll lose terminal access"
        echo "        until you reset shell via System Settings → Users & Groups →"
        echo "        Advanced Options → Login Shell: /bin/zsh → Save → Terminal.app."
    else
        echo "        ✓ login shell is system-managed: $login_shell"
    fi
    echo ""

    # ── Pre-flight 3: confirmation ──────────────────────────────────────
    echo "  [3/3] Continue with home-manager switch? [y/N]"
    if [[ -t 0 ]]; then
        read -r answer
    else
        answer=""
        echo "        (non-interactive shell → aborting by default; use \`just switch\` to bypass)"
    fi
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        echo ""
        echo "❌ Aborted."
        exit 1
    fi
    echo ""

    # ── Actual switch ───────────────────────────────────────────────────
    echo "🚀 Running home-manager switch ..."
    start_time=$(date +%s)
    home-manager switch --flake ".#{{ user }}@{{ hostname }}" {{ args }}
    exit_code=$?
    end_time=$(date +%s)
    runtime=$((end_time - start_time))

    if [[ $exit_code -ne 0 ]]; then
        echo ""
        echo "════════════════════════════════════════════════════════════════════════"
        echo "❌ home-manager switch failed (exit $exit_code, ${runtime}s)."
        echo ""
        echo "If the failure tore down your Nix profile, you may now be missing"
        echo "critical binaries (fish, home-manager itself). Canonical recovery:"
        echo ""
        echo "  1. If your terminal won't open after this:"
        echo "       System Settings → Users & Groups → right-click {{ user }}"
        echo "       → Advanced Options → Login Shell: /bin/zsh → Save"
        echo "     Then open Terminal.app (NOT Ghostty/WezTerm — they inherit"
        echo "     the bricked login shell)."
        echo ""
        echo "  2. nix profile list                          # see what's still there"
        echo "  3. nix profile remove <conflicting>          # the imperative duplicate"
        echo "  4. nix run nixpkgs#home-manager -- \\"
        echo "       switch --flake \".#{{ user }}@{{ hostname }}\""
        echo ""
        echo "  (After success, optionally chsh back to fish:"
        echo "    sudo chsh -s ~/.nix-profile/bin/fish {{ user }})"
        echo ""
        echo "  See ~/Code/inspr/playbook.md \"Day-5 EVENING amendment\" for the"
        echo "  full incident write-up that motivated this wrapper."
        echo "════════════════════════════════════════════════════════════════════════"
        if [[ $runtime -gt 10 ]]; then
            just _notify "safe-switch FAILED for {{ user }}@{{ hostname }}, exit $exit_code"
        fi
        exit $exit_code
    fi

    if [[ $runtime -gt 10 ]]; then
        just _notify "safe-switch finished for {{ user }}@{{ hostname }}, exit 0 (runtime: ${runtime}s)"
    fi
    echo ""
    echo "✅ Activation successful (${runtime}s)."

# NIX-107 Path A: install Homebrew casks/formulae/taps from the declarative
# Brewfile rendered by HM (~/.config/homebrew/Brewfile, sourced from
# macos-common.nix → mkBrewfile via per-host home.nix wire-up).
# ADDITIVE only — installs missing entries, NEVER removes existing ones.
# For destructive cleanup (uninstall casks not in the Brewfile), see
# `just bundle-cleanup` below.
[group('build')]
bundle:
    #!/usr/bin/env bash
    if [[ "$OSTYPE" != "darwin"* ]]; then
        echo "❌ just bundle is macOS-only (Brewfile is a Homebrew concept)."
        exit 2
    fi
    BREWFILE="$HOME/.config/homebrew/Brewfile"
    if [[ ! -f "$BREWFILE" ]]; then
        echo "❌ No Brewfile at $BREWFILE."
        echo "   It's rendered by home-manager — run \`just safe-switch\` (or \`just switch\`)"
        echo "   first to materialize it from macos-common.nix → mkBrewfile."
        exit 1
    fi
    echo "📦 Installing missing entries from $BREWFILE (with --upgrade for outdated) ..."
    # --upgrade: also upgrade outdated formulae listed in Brewfile (otherwise
    #   `bundle check` keeps reporting "needs to be installed or updated" for
    #   stale installs that brew has newer bottles for — observed 2026-05-10).
    # NOTE: --no-lock was removed in newer Homebrew (Brewfile.lock.json gone).
    brew bundle install --file="$BREWFILE" --upgrade --verbose
    exit_code=$?
    echo ""
    if [[ $exit_code -ne 0 ]]; then
        echo "❌ Bundle install FAILED (exit $exit_code). Investigate before re-running."
        exit $exit_code
    fi
    echo "✅ Bundle install complete (additive — nothing removed)."
    echo "   To remove casks not listed in the Brewfile: \`just bundle-cleanup\`"

# NIX-107 Path A — DESTRUCTIVE companion to `just bundle`. Uninstalls any
# Homebrew casks/formulae/taps that are NOT in the Brewfile. Use with care:
# this can remove apps you forgot to add to the per-host extras list.
# Always run `just bundle-check` first to preview.
[group('build')]
bundle-cleanup:
    #!/usr/bin/env bash
    if [[ "$OSTYPE" != "darwin"* ]]; then
        echo "❌ just bundle-cleanup is macOS-only."
        exit 2
    fi
    BREWFILE="$HOME/.config/homebrew/Brewfile"
    if [[ ! -f "$BREWFILE" ]]; then
        echo "❌ No Brewfile at $BREWFILE."
        exit 1
    fi
    echo "⚠️  DESTRUCTIVE: this will uninstall casks/formulae/taps NOT in the Brewfile."
    echo "   Brewfile: $BREWFILE"
    echo ""
    echo "   Preview with \`brew bundle cleanup --file=\"$BREWFILE\"\` (no flags = dry-run)."
    echo "   Continue with actual cleanup? [y/N]"
    if [[ -t 0 ]]; then
        read -r answer
    else
        answer=""
        echo "        (non-interactive shell → aborting by default)"
    fi
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        echo "❌ Aborted."
        exit 1
    fi
    brew bundle cleanup --file="$BREWFILE" --force
    echo "✅ Cleanup complete."

# NIX-107 Path A — preview what `just bundle` would install (no side effects).
[group('build')]
bundle-check:
    #!/usr/bin/env bash
    BREWFILE="$HOME/.config/homebrew/Brewfile"
    if [[ ! -f "$BREWFILE" ]]; then
        echo "❌ No Brewfile at $BREWFILE."
        exit 1
    fi
    echo "🔍 Brewfile vs installed state:"
    brew bundle check --file="$BREWFILE" --verbose || true

# Build and switch home-manager configuration (for macOS/standalone home-manager)
[group('build')]
home-switch args='':
    #!/usr/bin/env bash
    echo "🏠 Running home-manager switch for {{ user }}@{{ hostname }}..."
    start_time=$(date +%s)
    home-manager switch --flake ".#{{ user }}@{{ hostname }}" {{ args }}
    end_time=$(date +%s)
    exit_code=$?
    runtime=$((end_time - start_time))
    if [ $runtime -gt 10 ]; then
      just _notify "home-manager switch finished for {{ user }}@{{ hostname }}, exit code: $exit_code (runtime: ${runtime}s)"
    fi

# Build the current host with nix-rebuild
[group('build')]
nix-build:
    sudo nixos-rebuild build --flake .#{{ hostname }}

# Build a host with nh
[group('build')]
build-host hostname args='':
    nh os build -H {{ hostname }} . -- {{ args }}
    just _notify "build of host {{ hostname }} finished"

# Build a host with nh on another host
[group('build')]
build-host-on buildHost hostname args='':
    nh os build -H {{ hostname }} --build-host omega@{{ buildHost }} . -- {{ args }}
    just _notify "build of host {{ hostname }} on {{ buildHost }} finished"

# Build the current host (platform-aware)
[group('build')]
build args='':
    #!/usr/bin/env bash
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "$(printf '\xef\x85\xb9') Detected macOS - running 🏠 home-manager build for {{ user }}@{{ hostname }}..."
        home-manager build --flake ".#{{ user }}@{{ hostname }}" {{ args }}
    else
        echo "$(printf '\xef\x8c\x93') Detected NixOS - running ❄️ nh os build for {{ hostname }}..."
        nh os build -H {{ hostname }} . -- {{ args }}
        just _notify "build of host {{ hostname }} finished"
    fi

# Build the current host on the Caliban host
[group('build')]
nix-build-on-caliban:
    nixos-rebuild --build-host omega@caliban-1.netbird.cloud --flake .#{{ hostname }} build
    just _notify "build-on-caliban finished on {{ hostname }}"

# Build and deploy the astra host
[group('build')]
build-deploy-astra:
    nh os build -H astra --target-host omega@astra.netbird.cloud .
    just _notify "build-deploy-astra finished on {{ hostname }}"

# Build and deploy the ally2 host
[group('build')]
build-deploy-ally2:
    nh os build -H ally2 --target-host omega@ally2.lan .
    just _notify "build-deploy-ally2 finished on {{ hostname }}"

# Build the current host on the Sinope host
[group('build')]
build-on-sinope:
    nh os build -H {{ hostname }} --build-host omega@sinope.netbird.cloud .
    just _notify "build-on-sinope finished on {{ hostname }}"

# Build with nh on caliban
[group('build')]
build-on-caliban args='':
    nh os build -H {{ hostname }} --build-host omega@caliban-1.netbird.cloud . -- {{ args }}
    just _notify "build-on-caliban finished on {{ hostname }}"

# Build the current host on the Home01 host (use "--max-jobs 1" to restict downloads)
[group('build')]
nix-build-on-home01 args='':
    nixos-rebuild --build-host omega@home01.lan --flake .#{{ hostname }} build {{ args }}
    just _notify "build-on-home01 finished on {{ hostname }}"

# Build with nh on home01
[group('build')]
build-on-home01 args='':
    nh os build -H {{ hostname }} --build-host omega@home01.lan . -- {{ args }}
    just _notify "build-on-home01 finished on {{ hostname }}"

[group('cache')]
switch-push: switch && push

[group('cache')]
switch-push-all: push-all push

# Update the flakes
[group('build')]
update args='':
    #!/usr/bin/env bash
    set -eu
    token=$(gh auth token 2>/dev/null || cat ~/.secrets/github-token 2>/dev/null || true)
    if [ -n "$token" ]; then
      NIX_CONFIG="access-tokens = github.com=$token" nix flake update {{ args }}
    else
      echo "warn: no GitHub token (tried gh auth, ~/.secrets/github-token); running unauthenticated (60 req/hr limit)" >&2
      nix flake update {{ args }}
    fi

# Update the flakes and switch to the new configuration
[group('build')]
upgrade: update build switch

[group('cache')]
upgrade-push: upgrade push

[group('cache')]
upgrade-push-all: upgrade push-all push

[group('cache')]
push:
    -attic push main `which atuin` --no-closure
    -attic push main `which espanso` --no-closure
    -attic push main `which cura` --no-closure
    -attic push main `which ghostty` --no-closure
    -attic push main `which tv` --no-closure
    -attic push qownnotes `which qownnotes` --no-closure
    -attic push qownnotes `which qc` --no-closure
    -attic push qownnotes `which nixbit` --no-closure

[group('cache')]
push-all:
    ./scripts/push-all-to-attic.sh

[group('cache')]
push-local:
    attic push --ignore-upstream-cache-filter cicinas2:nix-store `which phpstorm` --no-closure
    attic push --ignore-upstream-cache-filter cicinas2:nix-store `which clion` --no-closure
    attic push --ignore-upstream-cache-filter cicinas2:nix-store `which goland` --no-closure

# Rekey the agenix secrets using ~/.ssh/agenix
[group('agenix')]
rekey-fallback:
    cd ./secrets && agenix -i ~/.ssh/agenix --rekey

# Rekey the agenix secrets
[group('agenix')]
rekey:
    cd ./secrets && agenix --rekey

# Show ssh keys for agenix
[group('agenix')]
keyscan:
    ssh-keyscan localhost

# Audit drift between secrets/*.age and secrets/secrets.nix declarations
# Usage: just secrets-audit          # Human report; exit 1 on drift
# just secrets-audit --json   # Machine output (requires jq)
[group('agenix')]
secrets-audit *args='':
    ./scripts/secrets-audit.sh {{ args }}

# Edit secrets using agenix (recommended workflow)
# Usage: just edit-secret secrets/SECRETNAME.age

# Example: just edit-secret secrets/static-leases-miniserver99.age
[group('agenix')]
edit-secret secret-file:
    agenix -e {{ secret-file }}

# Encrypt runbook secrets (per-host sysop reference docs)

# Usage: just encrypt-runbook-secrets [host]
[group('runbook-secrets')]
encrypt-runbook-secrets host='':
    nix-shell -p age --run "./scripts/runbook-secrets.sh encrypt {{ host }}"

# Decrypt runbook secrets for editing

# Usage: just decrypt-runbook-secrets [host]
[group('runbook-secrets')]
decrypt-runbook-secrets host='':
    nix-shell -p age --run "./scripts/runbook-secrets.sh decrypt {{ host }}"

# List hosts with runbook secrets
[group('runbook-secrets')]
list-runbook-secrets:
    ./scripts/runbook-secrets.sh list

# Encrypt a workstation secret (Tier 3: personal secrets)
# Usage: just encrypt-secret tapo-c210-living-room
# Prerequisites: ~/Secrets/ directory must exist (manual setup required)
# Encrypt a private secret (Tier 3: personal secrets)
# Usage: just private-encrypt tapo-c210-living-room

# Prerequisites: ~/Secrets/ directory must exist (manual setup required)
[group('private')]
private-encrypt file='':
    cd ~/Secrets && ./scripts/encrypt.sh {{ file }}

# Decrypt a private secret (Tier 3: personal secrets)
# Usage: just private-decrypt tapo-c210-living-room

# Prerequisites: ~/Secrets/ directory must exist (manual setup required)
[group('private')]
private-decrypt file='':
    cd ~/Secrets && ./scripts/decrypt.sh {{ file }}

# Encrypt all private secrets

# Usage: just private-encrypt-all
[group('private')]
private-encrypt-all:
    cd ~/Secrets && ./scripts/encrypt.sh --all

# Decrypt all private secrets

# Usage: just private-decrypt-all
[group('private')]
private-decrypt-all:
    cd ~/Secrets && ./scripts/decrypt.sh --all

# List private secrets status

# Usage: just private-list
[group('private')]
private-list:
    cd ~/Secrets && ./scripts/list.sh

# Encrypt, commit and push all private secrets to git

# Usage: just private-encrypt-commit
[group('private')]
private-encrypt-commit:
    cd ~/Secrets && \
    ./scripts/encrypt.sh --all && \
    git add encrypted/ && \
    git commit -m "Update private secrets" && \
    git push

# Pull and decrypt all private secrets from git

# Usage: just private-pull-decrypt
[group('private')]
private-pull-decrypt:
    cd ~/Secrets && \
    git pull && \
    ./scripts/decrypt.sh --all

@_show-qemu-exit-message:
    echo "Booting VM. To exit, use: Ctrl + A then X"
    echo "Press any key to continue..."
    read -n 1

# Boot the built iso image in QEMU
[group('build')]
boot-iso:
    just _show-qemu-exit-message
    nix-shell -p qemu --run "qemu-system-x86_64 -m 256 -cdrom result/iso/nixos-*.iso"

[group('vm')]
boot-vm:
    just _show-qemu-exit-message
    QEMU_OPTS="-m 4096 -smp 4 -enable-kvm" QEMU_NET_OPTS="hostfwd=tcp::2222-:22" ./result/bin/run-*-vm

[group('vm')]
boot-vm-no-kvm:
    just _show-qemu-exit-message
    QEMU_OPTS="-m 4096 -smp 4" QEMU_NET_OPTS="hostfwd=tcp::2222-:22" ./result/bin/run-*-vm

[group('vm')]
boot-vm-console:
    just _show-qemu-exit-message
    QEMU_OPTS="-nographic -serial mon:stdio" QEMU_KERNEL_PARAMS=console=ttyS0 QEMU_NET_OPTS="hostfwd=tcp::2222-:22" ./result/bin/run-*-vm

[group('vm')]
boot-vm-server-console:
    just _show-qemu-exit-message
    QEMU_OPTS="-nographic -serial mon:stdio" QEMU_KERNEL_PARAMS=console=ttyS0 QEMU_NET_OPTS="hostfwd=tcp::2222-:2222" ./result/bin/run-*-vm

[group('vm')]
ssh-vm-server:
    ssh -p 2222 omega@localhost -t "tmux new-session -A -s pbek"

# Reset the VM
[confirm("Are you sure you want to reset the VM?")]
[group('vm')]
reset-vm:
    rm *.qcow2

[group('vm')]
ssh-vm:
    ssh -p 2222 omega@localhost -t "tmux new-session -A -s pbek"

[group('vm')]
build-vm host:
    nixos-rebuild --flake .#{{ host }} build-vm

# Rebuild the current host
[group('build')]
flake-rebuild-current:
    nh os switch -H {{ hostname }} .

# Update the flakes
[group('build')]
flake-update:
    nix flake update

# Clean up the system to free up space
[confirm("Are you sure you want to clean up the system?")]
[group('maintenance')]
cleanup:
    duf
    sudo journalctl --vacuum-time=3d
    docker system prune -f
    sudo rm -rf ~/.local/share/Trash/*
    sudo nix-collect-garbage -d
    nix-collect-garbage -d
    nix-store --optimise
    duf
    just _notify "Cleanup finished on {{ hostname }}"

# Repair the nix store
[group('maintenance')]
repair-store:
    sudo nix-store --verify --check-contents --repair
    just _notify "Store repaired on {{ hostname }}"

# List the generations
[group('maintenance')]
list-generations:
    nh os info

# Rollback to the previous generation
[group('maintenance')]
rollback:
    nh os rollback

# Garbage collect the nix store to free up space
[group('maintenance')]
optimize-store:
    duf && \
    nix store optimise && \
    duf
    just _notify "Store optimized on {{ hostname }}"

# Do firmware updates
[group('maintenance')]
fwup:
    -fwupdmgr refresh
    fwupdmgr update

# Kill the nixcfg session
[group('maintenance')]
term-kill:
    zellij delete-session nixcfg -f

# Replace the current fish shell with a new one
[group('build')]
fish-replace:
    exec fish

# Use statix to check the nix files
[group('linter')]
linter-check:
    nix-shell -p statix --run "statix check"

# Use statix to fix the nix files
[group('linter')]
linter-fix:
    nix-shell -p statix --run "statix fix"

# Fix "command not found" error
[group('maintenance')]
update-channels:
    sudo nix-channel --update

# Build the Venus host with nix
[group('build')]
nix-build-venus:
    nixos-rebuild --flake .#venus build

# Build the Venus host with nh
[group('build')]
build-venus: (build-host "venus")

# Show home-manager logs
[group('maintenance')]
home-manager-logs:
    sudo journalctl --since today | grep "hm-activate-" | bat

# Show home-manager service status
[group('maintenance')]
home-manager-status:
    systemctl status home-manager-{{ user }}.service

# Restart nix-serve (use on home01)
[group('maintenance')]
home01-restart-nix-serve:
    systemctl restart nix-serve

# Show logs from current boot session
[group('log')]
logs-current-boot:
    journalctl -b -e

# Show logs from previous boot session
[group('log')]
logs-previous-boot:
    journalctl -b-1

# Show logs in real time
[group('log')]
logs-follow:
    journalctl -f

# Edit the QOwnNotes build file
[group('qownnotes')]
edit-qownnotes-build:
    kate ./pkgs/qownnotes/package.nix -l 23 -c 19

# Run a fish shell with all needed tools
[group('maintenance')]
shell:
    nix-shell --run fish

# Get the nix hash of a QOwnNotes release
[group('qownnotes')]
qownnotes-hash:
    #!/usr/bin/env bash
    set -euxo pipefail
    version=$(gum input --placeholder "QOwnNotes version number")
    url="https://github.com/pbek/QOwnNotes/releases/download/v${version}/qownnotes-${version}.tar.xz"
    nix-prefetch-url "$url" | xargs nix hash convert --hash-algo sha256

# Update the QOwnNotes release in the app
[group('qownnotes')]
qownnotes-update-release:
    ./scripts/update-qownnotes-release.sh

# Get the nix hash of a Nixbit release
[group('nixbit')]
nixbit-hash:
    #!/usr/bin/env bash
    set -euxo pipefail
    version=$(gum input --placeholder "Nixbit version number")
    url="https://github.com/pbek/nixbit/archive/refs/tags/v${version}.tar.gz"
    nix-prefetch-url "$url" | xargs nix hash convert --hash-algo sha256

# Update the Nixbit release in the app
[group('nixbit')]
nixbit-update-release:
    ./scripts/update-nixbit-release.sh

# Evaluate a config for a hostname (default current host)
eval-config configPath host=hostname *args:
    nix eval .#nixosConfigurations.{{ host }}.config.{{ configPath }} {{ args }}

# Evaluate a config for a hostname (default current host) as json
eval-config-json configPath host=hostname *args:
    nix eval .#nixosConfigurations.{{ host }}.config.{{ configPath }} --json {{ args }} | jq | bat -l json

whereis-pkg package:
    whereis $(which ${package})

# Show all config options of the hokage service
hokage-options host=hostname:
    nix eval .#nixosConfigurations.{{ host }}.options.hokage --json | jq

# Show all config options of the hokage nix module and get more information about one (WIP)
hokage-options-interactive:
    #!/usr/bin/env bash

    # Get all hokage options using nix eval
    echo "Loading hokage module options..."
    options=$(nix eval .#nixosConfigurations.{{ hostname }}.options.hokage --json | jq -r 'to_entries | .[] | .key' | sort)

    while true; do
        # Use fzf to select an option
        selected=$(echo "$options" | fzf --prompt="Select hokage option > " --height=20)

        # Check if user cancelled with ESC
        if [ -z "$selected" ]; then
            break
        fi

        # Clear screen for better readability
        clear

        echo "Option: hokage.$selected"
        echo "========================================"

        # Show detailed information about the selected option
        nix eval .#nixosConfigurations.{{ hostname }}.options.hokage.$selected --json | jq -r '
        if .description.text then "Description: " + .description.text else "Description: No description available" end,
        if .type.description then "Type: " + .type.description else "Type: Unknown" end,
        if .default.text then "Default: " + .default.text else "Default: No default value" end,
        if .example.text then "Example: " + .example.text else "Example: No example provided" end
        '

        echo "========================================"
        echo "Press any key to select another option, or Ctrl+C to exit"

        # Wait for keypress
        read -n 1

        # Clear screen before showing fzf again
        clear
    done

# ============================================================================
# OpenClaw — Unified host-aware commands
# Works from macOS (explicit host arg), hsb0, and miniserver-bp (auto-detect)
#
# Host routing:
#   hsb0         → container: openclaw-gateway,   compose: hosts/hsb0/docker
#   msbp         → container: openclaw-percaival, compose: hosts/miniserver-bp/docker
#
# Usage from macOS:   just oc-rebuild hsb0 / just oc-rebuild msbp
# Usage on host:      just oc-rebuild          (auto-detects local host)
# ============================================================================
# Helper: run a command on the target OpenClaw host

# host: hsb0 | msbp | (empty = auto-detect from hostname)
[private]
_oc-run host cmd:
    #!/usr/bin/env bash
    set -euo pipefail
    _hostname="$(hostname -s)"

    # Resolve target host
    if [ -n "{{ host }}" ]; then
        _target="{{ host }}"
    elif [ "$_hostname" = "hsb0" ]; then
        _target="hsb0"
    elif [ "$_hostname" = "miniserver-bp" ]; then
        _target="msbp"
    else
        echo "Error: running on macOS (${_hostname}) — specify host: just <recipe> hsb0  OR  just <recipe> msbp" >&2
        exit 1
    fi

    # Route to correct host
    case "$_target" in
        hsb0)
            if [ "$_hostname" = "hsb0" ]; then
                bash -c "{{ cmd }}"
            else
                # From home LAN (imac0, gpc0): use .lan
                # From office/remote: fall back to Tailscale
                if ping -c1 -W3 hsb0.lan &>/dev/null; then
                    ssh mba@hsb0.lan "{{ cmd }}"
                else
                    ssh mba@hsb0.ts.barta.cm "{{ cmd }}"
                fi
            fi
            ;;
        msbp)
            if [ "$_hostname" = "miniserver-bp" ]; then
                bash -c "{{ cmd }}"
            else
                # From office LAN: use direct IP; from anywhere else: use Tailscale
                if ping -c1 -W3 10.17.1.40 &>/dev/null; then
                    ssh -p 2222 mba@10.17.1.40 "{{ cmd }}"
                else
                    ssh -p 2222 mba@miniserver-bp.ts.barta.cm "{{ cmd }}"
                fi
            fi
            ;;
        *)
            echo "Error: unknown host '${_target}'. Use: hsb0 | msbp" >&2
            exit 1
            ;;
    esac

# Helper: resolve container name for a given host target
[private]
_oc-container host:
    #!/usr/bin/env bash
    _hostname="$(hostname -s)"
    _target="{{ host }}"
    if [ -z "$_target" ]; then
        case "$_hostname" in
            hsb0) _target="hsb0" ;;
            miniserver-bp) _target="msbp" ;;
            *) echo "openclaw-gateway" ;; # fallback
        esac
    fi
    case "$_target" in
        hsb0) echo "openclaw-gateway" ;;
        msbp) echo "openclaw-percaival" ;;
        *) echo "openclaw-gateway" ;;
    esac

# Helper: resolve compose dir for a given host target
[private]
_oc-compose-dir host:
    #!/usr/bin/env bash
    _hostname="$(hostname -s)"
    _target="{{ host }}"
    if [ -z "$_target" ]; then
        case "$_hostname" in
            hsb0) _target="hsb0" ;;
            miniserver-bp) _target="msbp" ;;
        esac
    fi
    case "$_target" in
        hsb0) echo "~/Code/nixcfg/hosts/hsb0/docker" ;;
        # msbp lives in BYTEPOETS/bpnixcfg since 2026-05-02 (INSPR-24 Stage 2).
        # On the host, the clone is at ~/Code/bpnixcfg (no BYTEPOETS/ prefix).
        # An OLD stale clone at ~/Code/nixcfg/hosts/miniserver-bp still exists
        # on msbp (frozen at the last commit before removal) — do NOT route
        # there or `oc-rebuild` will silently use stale config.
        msbp) echo "~/Code/bpnixcfg/hosts/miniserver-bp/docker" ;;
        *) echo "~/Code/nixcfg/hosts/hsb0/docker" ;;
    esac

# Rebuild container from scratch — pulls latest openclaw@latest from npm (slow, ~5-15 min)

# Usage: just oc-rebuild [hsb0|msbp]
[group('openclaw')]
oc-rebuild host='':
    #!/usr/bin/env bash
    _hostname="$(hostname -s)"
    _target="{{ host }}"
    if [ -z "$_target" ]; then
        case "$_hostname" in
            hsb0) _target="hsb0" ;;
            miniserver-bp) _target="msbp" ;;
            *) echo "Error: specify host: just oc-rebuild hsb0  OR  just oc-rebuild msbp" >&2; exit 1 ;;
        esac
    fi
    _container="$(just _oc-container $_target)"
    _dir="$(just _oc-compose-dir $_target)"
    just _oc-run "$_target" "cd $_dir && docker compose build --no-cache $_container && docker compose up -d --force-recreate $_container"

# Fast rebuild — uses Docker cache (for config/entrypoint changes, not npm updates)

# Usage: just oc-rebuild-fast [hsb0|msbp]
[group('openclaw')]
oc-rebuild-fast host='':
    #!/usr/bin/env bash
    _hostname="$(hostname -s)"
    _target="{{ host }}"
    if [ -z "$_target" ]; then
        case "$_hostname" in
            hsb0) _target="hsb0" ;;
            miniserver-bp) _target="msbp" ;;
            *) echo "Error: specify host: just oc-rebuild-fast hsb0  OR  just oc-rebuild-fast msbp" >&2; exit 1 ;;
        esac
    fi
    _container="$(just _oc-container $_target)"
    _dir="$(just _oc-compose-dir $_target)"
    just _oc-run "$_target" "cd $_dir && docker compose up -d --build --force-recreate $_container"

# Show container status and recent logs

# Usage: just oc-status [hsb0|msbp]
[group('openclaw')]
oc-status host='':
    #!/usr/bin/env bash
    _hostname="$(hostname -s)"
    _target="{{ host }}"
    if [ -z "$_target" ]; then
        case "$_hostname" in
            hsb0) _target="hsb0" ;;
            miniserver-bp) _target="msbp" ;;
            *) echo "Error: specify host: just oc-status hsb0  OR  just oc-status msbp" >&2; exit 1 ;;
        esac
    fi
    _container="$(just _oc-container $_target)"
    just _oc-run "$_target" "docker ps -f name=$_container --format 'table {{{{.Status}}\t{{{{.Ports}}' && echo '---' && docker logs $_container --tail 30"

# Stop the OpenClaw container

# Usage: just oc-stop [hsb0|msbp]
[group('openclaw')]
oc-stop host='':
    #!/usr/bin/env bash
    _hostname="$(hostname -s)"
    _target="{{ host }}"
    if [ -z "$_target" ]; then
        case "$_hostname" in
            hsb0) _target="hsb0" ;;
            miniserver-bp) _target="msbp" ;;
            *) echo "Error: specify host: just oc-stop hsb0  OR  just oc-stop msbp" >&2; exit 1 ;;
        esac
    fi
    _container="$(just _oc-container $_target)"
    _dir="$(just _oc-compose-dir $_target)"
    just _oc-run "$_target" "cd $_dir && docker compose stop $_container"

# Start the OpenClaw container

# Usage: just oc-start [hsb0|msbp]
[group('openclaw')]
oc-start host='':
    #!/usr/bin/env bash
    _hostname="$(hostname -s)"
    _target="{{ host }}"
    if [ -z "$_target" ]; then
        case "$_hostname" in
            hsb0) _target="hsb0" ;;
            miniserver-bp) _target="msbp" ;;
            *) echo "Error: specify host: just oc-start hsb0  OR  just oc-start msbp" >&2; exit 1 ;;
        esac
    fi
    _container="$(just _oc-container $_target)"
    _dir="$(just _oc-compose-dir $_target)"
    just _oc-run "$_target" "cd $_dir && docker compose start $_container"

# Stop then start the container (no rebuild — picks up new openclaw.json on boot)

# Usage: just oc-restart [hsb0|msbp]
[group('openclaw')]
oc-restart host='':
    #!/usr/bin/env bash
    _hostname="$(hostname -s)"
    _target="{{ host }}"
    if [ -z "$_target" ]; then
        case "$_hostname" in
            hsb0) _target="hsb0" ;;
            miniserver-bp) _target="msbp" ;;
            *) echo "Error: specify host: just oc-restart hsb0  OR  just oc-restart msbp" >&2; exit 1 ;;
        esac
    fi
    _container="$(just _oc-container $_target)"
    _dir="$(just _oc-compose-dir $_target)"
    just _oc-run "$_target" "cd $_dir && docker compose stop $_container && docker compose start $_container"

# Pull all agent workspace repos into running container

# Usage: just oc-pull-workspace [hsb0|msbp]
[group('openclaw')]
oc-pull-workspace host='':
    #!/usr/bin/env bash
    _hostname="$(hostname -s)"
    _target="{{ host }}"
    if [ -z "$_target" ]; then
        case "$_hostname" in
            hsb0) _target="hsb0" ;;
            miniserver-bp) _target="msbp" ;;
            *) echo "Error: specify host: just oc-pull-workspace hsb0  OR  just oc-pull-workspace msbp" >&2; exit 1 ;;
        esac
    fi
    case "$_target" in
        hsb0)
            just _oc-run hsb0 "if [ -f /run/agenix/hsb0-openclaw-github-pat ]; then docker exec openclaw-gateway git -C /home/node/.openclaw/workspace-merlin pull --ff-only; else echo 'Merlin workspace pull disabled - no GitHub PAT configured'; fi"
            just _oc-run hsb0 "docker exec openclaw-gateway git -C /home/node/.openclaw/workspace-nimue pull --ff-only"
            ;;
        msbp)
            just _oc-run msbp "docker exec openclaw-percaival git -C /home/node/.openclaw/workspace pull --ff-only"
            ;;
    esac

# Reindex agent memory (triggers GGUF embedding model if needed, ~328MB first run)

# Usage: just oc-memory-index [hsb0|msbp]
[group('openclaw')]
oc-memory-index host='':
    #!/usr/bin/env bash
    _hostname="$(hostname -s)"
    _target="{{ host }}"
    if [ -z "$_target" ]; then
        case "$_hostname" in
            hsb0) _target="hsb0" ;;
            miniserver-bp) _target="msbp" ;;
            *) echo "Error: specify host: just oc-memory-index hsb0  OR  just oc-memory-index msbp" >&2; exit 1 ;;
        esac
    fi
    case "$_target" in
        hsb0)
            just _oc-run hsb0 "docker exec openclaw-gateway sh -c '. /home/node/.env && openclaw memory index --force --agent merlin 2>&1 | tail -5'"
            just _oc-run hsb0 "docker exec openclaw-gateway sh -c '. /home/node/.env && openclaw memory index --force --agent nimue 2>&1 | tail -5'"
            just _oc-run hsb0 "docker exec openclaw-gateway sh -c '. /home/node/.env && openclaw memory status 2>&1 | grep -e Provider -e Indexed -e Vector'"
            ;;
        msbp)
            just _oc-run msbp "docker exec openclaw-percaival sh -c 'openclaw memory index --force 2>&1 | tail -5'"
            just _oc-run msbp "docker exec openclaw-percaival sh -c 'openclaw memory status 2>&1 | grep -e Provider -e Indexed -e Vector'"
            ;;
    esac

# ── Workspace aliases (thin wrappers, hsb0-only agents) ──────────────────────

# Pull Merlin's workspace into running container (hsb0 only)
[group('openclaw')]
merlin-pull-workspace:
    just oc-pull-workspace hsb0

# Pull Nimue's workspace into running container (hsb0 only)
[group('openclaw')]
nimue-pull-workspace:
    just oc-pull-workspace hsb0

# ── Percy aliases (backward compat — prefer oc-* commands) ───────────────────

# [deprecated: use 'just oc-stop msbp'] Stop Percy container
[group('openclaw')]
percy-stop:
    just oc-stop msbp

# [deprecated: use 'just oc-start msbp'] Start Percy container
[group('openclaw')]
percy-start:
    just oc-start msbp

# [deprecated: use 'just oc-pull-workspace msbp'] Pull Percy workspace
[group('openclaw')]
percy-pull-workspace:
    just oc-pull-workspace msbp

# [deprecated: use 'just oc-rebuild msbp'] Rebuild Percy container
[group('openclaw')]
percy-rebuild:
    just oc-rebuild msbp

# [deprecated: use 'just oc-status msbp'] Percy container status
[group('openclaw')]
percy-status:
    just oc-status msbp

# Get the reverse dependencies of a nix store path
[group('maintenance')]
nix-store-reverse-dependencies:
    #!/usr/bin/env bash
    set -euxo pipefail
    nixStorePath=$(gum input --placeholder "Nix store path (e.g. /nix/store/hbldxn007k0y5qidna6fg0x168gnsmkj-botan-2.19.5.drv)")
    nix-store --query --referrers "$nixStorePath"

# Generate a random host ID for ZFS
[group('maintenance')]
zfs-generate-host-id:
    head -c4 /dev/urandom | od -A none -t x4

# Restart the plasmashell service (useful after an update)
[group('maintenance')]
restart-plasmashell:
    systemctl restart --user plasma-plasmashell.service

# Register local git merge drivers for lockfiles (run once per clone)
[group('config')]
setup-git-drivers:
    #!/usr/bin/env bash
    set -euo pipefail
    git config --local merge.ours.driver true
    echo "✅ Registered 'ours' merge driver. devenv.lock/flake.lock conflicts now auto-resolve on pull/rebase."
    echo "   See docs/AGENT-WORKFLOW.md → 'Lockfile Merge Conflicts' for details."

# Generate aider configuration file with GitHub Copilot oauth token
[group('config')]
@generate-aider-config:
    #!/usr/bin/env bash
    set -euo pipefail

    # Get the oauth token using the hidden helper recipe
    OAUTH_TOKEN=$(just _get-github-copilot-token)

    # Create the aider config file
    cat > "$HOME/.aider.conf.yml" << EOF
    openai-api-base: https://api.githubcopilot.com
    openai-api-key:  "$OAUTH_TOKEN"
    model:           openai/claude-sonnet-4
    weak-model:      openai/gpt-4o-mini
    show-model-warnings: false
    EOF

    echo "✅ Generated aider configuration at ~/.aider.conf.yml"

# List available GitHub Copilot models
[group('config')]
@list-github-copilot-models:
    #!/usr/bin/env bash
    set -euo pipefail

    # Get the oauth token using the hidden helper recipe
    OPENAI_API_KEY=$(just _get-github-copilot-token)

    echo "Available GitHub Copilot models:"
    curl -s https://api.githubcopilot.com/models \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -H "Content-Type: application/json" \
      -H "Copilot-Integration-Id: vscode-chat" | jq -r '.data[].id'

# Hidden recipe to extract GitHub Copilot oauth token
@_get-github-copilot-token:
    #!/usr/bin/env bash
    set -euo pipefail

    # Extract oauth_token from GitHub Copilot apps.json
    APPS_JSON="$HOME/.config/github-copilot/apps.json"

    if [ ! -f "$APPS_JSON" ]; then
        echo "Error: GitHub Copilot apps.json not found at $APPS_JSON" >&2
        exit 1
    fi

    # Extract the oauth_token using jq
    OAUTH_TOKEN=$(jq -r '.[].oauth_token' "$APPS_JSON")

    if [ -z "$OAUTH_TOKEN" ] || [ "$OAUTH_TOKEN" = "null" ]; then
        echo "Error: Could not extract oauth_token from $APPS_JSON" >&2
        exit 1
    fi

    echo "$OAUTH_TOKEN"

[group('linter')]
scan-dead-code args='':
    deadnix --exclude pkgs/ {{ args }}

# Fix dead code in the nix files
[group('linter')]
fix-dead-code args='':
    deadnix --exclude pkgs/ -e {{ args }}

# Run the QOwnNotes tests
[group('tests')]
test-qownnotes:
    nix build .#checks.x86_64-linux.qownnotes-unstable -L --no-link

# Run the QOwnNotes interactive test
[group('tests')]
test-qownnotes-interactive:
    nix build .#checks.x86_64-linux.qownnotes.driverInteractive
    echo "To interact with the test VM, run: start_all()"
    ./result/bin/nixos-test-driver

# Generate Markdown documentation for hokage module options
[group('docs')]
hokage-options-md:
    #!/usr/bin/env bash
    set -euo pipefail
    nix build .#hokage-options-md -L
    FILE="result"
    if [ -d "result" ]; then
        if [ -f "result/share/doc/nixos/options.md" ]; then
            FILE="result/share/doc/nixos/options.md"
        elif [ -f "result/options.md" ]; then
            FILE="result/options.md"
        fi
    fi
    echo -e "\n📄 Built hokage options Markdown at: ${FILE}\n"
    if command -v bat >/dev/null 2>&1; then bat -l markdown "$FILE"; else cat "$FILE"; fi

# Build and save the Markdown to a file in the repo (default docs/hokage-options.md)
[group('docs')]
hokage-options-md-save path='docs/hokage-options.md':
    #!/usr/bin/env bash
    set -euo pipefail
    nix build .#hokage-options-md -L
    FILE="result"
    if [ -d "result" ]; then
        if [ -f "result/share/doc/nixos/options.md" ]; then
            FILE="result/share/doc/nixos/options.md"
        elif [ -f "result/options.md" ]; then
            FILE="result/options.md"
        fi
    fi
    mkdir -p "$(dirname "{{ path }}")"
    install -Dm644 "$FILE" "{{ path }}"
    echo "✅ Saved hokage options documentation to {{ path }}"

# Run a command on hsb1 — locally if already there, via SSH otherwise
_hsb1 cmd:
    #!/usr/bin/env bash
    if [ "$(hostname)" = "hsb1" ]; then
        bash -c '{{ cmd }}'
    else
        ssh mba@hsb1.lan '{{ cmd }}'
    fi

# Start health-pixoo dashboard on Pixoo64
[group('smarthome')]
pixoo-start:
    just _hsb1 "mosquitto_pub -h localhost -u smarthome -P \$(grep MQTT_PASSWORD ~/secrets/health-pixoo.env | cut -d= -f2) -t 'jhw2211/health/control' -m 'start'"

# Stop health-pixoo dashboard, restore Pixoo clock face
[group('smarthome')]
pixoo-stop:
    just _hsb1 "mosquitto_pub -h localhost -u smarthome -P \$(grep MQTT_PASSWORD ~/secrets/health-pixoo.env | cut -d= -f2) -t 'jhw2211/health/control' -m 'stop'"

# Rebuild and redeploy health-pixoo on hsb1
[group('smarthome')]
pixoo-deploy:
    just _hsb1 "cd ~/Code/health-pixoo && git pull && docker build -t ghcr.io/markus-barta/health-pixoo:latest . && cd ~/docker && docker compose up -d health-pixoo"

# Tail health-pixoo logs from hsb1
[group('smarthome')]
pixoo-logs:
    just _hsb1 "docker logs -f health-pixoo"

# ── AI CLIs ───────────────────────────────────────────────────────────────────

# Bump AI CLIs (claude-code, codex) to npm latest — runs anywhere with node
[group('ai')]
update-ai-clis:
    @date
    npm i -g @anthropic-ai/claude-code@latest @openai/codex@latest
    @echo "---"
    @claude --version 2>/dev/null || echo "claude: not installed"
    @codex  --version 2>/dev/null || echo "codex:  not installed"
