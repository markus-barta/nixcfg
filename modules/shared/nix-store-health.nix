# Nix store liveness watchdog — OPS-102.
#
# WHY THIS EXISTS
# ===============
# On 2026-07-29 hsb1 was carrying an orphaned `nix-daemon` worker, 16 days old,
# whose client had long since died (reparented to PID 1). It sat asleep holding
# /nix/var/nix/db/big-lock and /nix/var/nix/gc.lock. Nothing noticed, because
# nothing was looking, and the host was in every other respect perfectly
# healthy — containers up, services green, zero failed units.
#
# It stayed harmless until a nixpkgs bump (20260711 -> 20260718) meant the newer
# nix wanted exclusive store access on first use. From that moment EVERY nix
# operation on the host blocked forever at:
#
#     waiting for exclusive access to the Nix store...
#
# The symptoms pointed everywhere except the cause: three home-manager units
# timing out after exactly 5 minutes with no error; `nix-build --expr '{}'`
# (a build that touches no network) hanging; `nix store info` hanging after
# printing "Store URL: daemon"; `systemctl restart nix-daemon` refusing to
# start. It took four rounds of diagnosis to find a sleeping process holding a
# lock file. `kill -9` fixed it in one second.
#
# The failure mode that matters is NOT "nix is slow". It is: the host looks
# completely fine, and stays looking fine, right up until you need to deploy —
# and then you cannot deploy, and the reason is invisible unless you already
# know to run lsof against two specific lock files.
#
# WHAT IS ACTUALLY MEASURED
# =========================
#   liveness      `nix store info` completes within 20s. This is the honest
#                 end-to-end test: it exercises the same client -> daemon path
#                 every real nix operation uses. A process-exists check would
#                 have passed happily on hsb1 for 16 days.
#   lock holders  only consulted AFTER liveness fails — this is diagnosis, not
#                 detection, and it is what turns "nix is stuck" into a name,
#                 a PID and an age.
#
# WHY IT DOES NOT SELF-HEAL
# =========================
# The babycam watchdog (NIX-151) reconciles because it has an unambiguous
# statement of user intent to reconcile against. Here there is no such
# reference: a process holding the GC lock may be a perfectly legitimate
# garbage collection that has been running for an hour, and killing it mid-run
# to "fix" a fault that does not exist is precisely the operator-induced damage
# the ops doctrine warns about. So a running GC is reported as healthy and the
# check exits 0.
#
# What is left — a lock held by a process whose parent is dead, with no GC
# anywhere — has no legitimate explanation, but killing root processes on a
# timer is still a bigger hammer than this problem deserves. The unit fails
# instead, which surfaces in `systemctl --failed` and in anything that collects
# it, and the journal carries the exact command to run.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixcfg.nixStoreHealth;

  check = pkgs.writeShellApplication {
    name = "nix-store-health-check";
    runtimeInputs = with pkgs; [
      config.nix.package
      coreutils
      lsof
      procps
    ];
    text = ''
      # Liveness: the same client -> daemon path every real nix command uses.
      if timeout ${toString cfg.timeoutSeconds} nix store info >/dev/null 2>&1; then
        exit 0
      fi

      echo "FAULT: nix store did not respond within ${toString cfg.timeoutSeconds}s."
      echo "Every nix operation on this host is blocked (deploys included)."

      # A running collection legitimately holds the lock. Not a fault.
      if pgrep -f 'nix-collect-garbage|nix-store .*--gc|nix store gc' >/dev/null 2>&1; then
        echo "A garbage collection is running and holds the lock. Expected; not a fault."
        exit 0
      fi

      echo "No garbage collection is running, so the lock is held by something stale."

      holders="$(lsof -t /nix/var/nix/db/big-lock /nix/var/nix/gc.lock 2>/dev/null | sort -u || true)"
      if [ -z "$holders" ]; then
        echo "No lock holder found — nix is unresponsive for some OTHER reason."
        echo "Check: systemctl status nix-daemon, journalctl -u nix-daemon -n 50"
        exit 1
      fi

      # read-loop rather than `for pid in $holders` so shellcheck stays happy
      # about word splitting (writeShellApplication treats its warnings as
      # build errors, and this file cannot be built on the macOS workstation).
      while read -r pid; do
        [ -n "$pid" ] || continue
        ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || echo '?')"
        age="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ' || echo '0')"
        cmd="$(ps -o args= -p "$pid" 2>/dev/null || echo '?')"
        echo "  holder pid=$pid ppid=$ppid age=''${age}s cmd=$cmd"
        if [ "$ppid" = "1" ]; then
          echo "  -> pid $pid is ORPHANED (parent dead). This is the hsb1 2026-07-29 shape."
          echo "  -> verify, then: sudo kill -9 $pid   (SIGTERM was ignored on hsb1)"
        fi
      done <<< "$holders"

      exit 1
    '';
  };
in
{
  options.nixcfg.nixStoreHealth = {
    enable = lib.mkEnableOption "periodic Nix store liveness check (OPS-102)" // {
      default = true;
    };

    timeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 20;
      description = ''
        How long `nix store info` may take before the store counts as wedged.
        Generous on purpose: a busy store is slow, a wedged one never answers.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = ''
        systemd OnCalendar expression. Hourly is deliberate — this fault is
        measured in weeks, not minutes, and the check is worthless as noise.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.nix-store-health = {
      description = "Nix store liveness check (OPS-102)";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe check;
        # The check must never become the thing that hangs.
        TimeoutStartSec = cfg.timeoutSeconds + 40;
        User = "root";
      };
    };

    systemd.timers.nix-store-health = {
      description = "Nix store liveness check schedule (OPS-102)";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.interval;
        # Not at boot: nix is legitimately busy then, and a false alarm during
        # activation is exactly the noise that gets watchdogs ignored.
        OnBootSec = "30min";
        RandomizedDelaySec = "5min";
        Persistent = true;
      };
    };
  };
}
