# One-shot boot trial with automatic fallback — OPS-213.
#
# WHY THIS EXISTS
# ===============
# hsb9 sits at the parents-in-law (hsb8 at Markus's dad's). A kernel that boots
# but never brings the NIC up turns a routine reboot into a drive, and hsb9's
# forcedeth NIC has form: kernel 6.12 regressed it and the install-day boot
# hung in an RCU stall (NIX-138). The 2026-09-21 nixpkgs bump moved hsb9's
# pinned 6.18 kernel 6.18.38 -> 6.18.52, which only takes effect on reboot.
#
# The idea is old and boring: boot the new generation exactly ONCE, with the
# last known-good generation as the GRUB default. GRUB clears the one-shot
# entry (`next_entry`, NixOS's grub.cfg honours it) before it boots it, so
# anything that ends in a reboot, whether automatic or someone pressing the
# power button, lands on the known-good default.
#
# WHAT TURNS A FAILED TRIAL INTO A REBOOT
# =======================================
#   kernel panic      `panic=30` reboots instead of hanging forever.
#   RCU stall         `sysctl.kernel.panic_on_rcu_stall=1` (the NIX-138 shape);
#   soft lockup       `softlockup_panic=1`;
#   hard lockup       `nmi_watchdog=panic`. All are on the command line so they
#                     hold from early boot, not only once systemd-sysctl runs.
#                     They stay on permanently, which is what a headless
#                     offsite box wants: a reboot beats a hang nobody can see.
#                     hsb9's journal (16 boots since 2026-05-26) holds zero
#                     stalls, lockups, hung tasks or oopses, so this does not
#                     trade a quiet box for spurious reboots.
#   initrd failure    with systemd stage 1 and emergencyAccess off, a failed
#                     initrd (root device never appears, ...) waits forever at
#                     a locked emergency shell. `boot.panic_on_fail` turns it
#                     into a panic, and so into a reboot.
#   no network        boot-trial-guard: on an armed boot, if the gateway does
#                     not answer and (with tailscale) the tailnet is not up
#                     within the window, reboot. Disarms first, so it can never
#                     loop.
#
# WHAT IT CANNOT CATCH
# ====================
#   GRUB itself       the MBR code is shared by every entry, so GRUB cannot
#                     fall back to another GRUB. That is why `arm` reinstalls
#                     the known-good generation's OWN bootloader: during the
#                     trial the MBR holds the GRUB that last booted this box,
#                     and only `promote` moves it forward. Run `promote` when a
#                     GRUB upgrade can be attended; the next reboot tests it.
#   silent hangs      a hang that raises no panic, stall or lockup (firmware,
#                     a stage 2 emergency shell) still needs a power cycle,
#                     which the one-shot turns into a fallback.
#   shutdown hangs    no watchdog device is used. hsb9's MCP79 `nv_tco` is a
#                     legacy misc device (untested here), and its presence
#                     pushes softdog to /dev/watchdog1, where systemd's
#                     RebootWatchdogSec does not look.
#
# HOW TO RUN A TRIAL (as root, on the host)
# =========================================
#   1. Switch to the generation you want to try. The guard stays inert.
#   2. boot-trial arm <known-good-generation> [window-seconds]
#        installs the known-good generation's own bootloader with itself as
#        the default (its GRUB, its grub.cfg generator), points next_entry at
#        the running generation, and arms the guard. From here on EVERY boot,
#        planned or a power cut, is the one trial with fallback.
#   3. systemctl reboot, then watch.
#   4. On success: boot-trial promote. This makes the tried generation the
#      default and installs its bootloader, GRUB included.
#      On failure the host comes back on the known-good generation; investigate
#      from there.
#   A `switch` before `promote` also installs the new bootloader and default,
#   which ends the known-good fallback. Don't switch a host mid-trial.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixcfg.bootTrial;
  stateDir = "/var/lib/boot-trial";
  armedFile = "${stateDir}/armed";
  passedFile = "${stateDir}/passed";
  grubenv = "/boot/grub/grubenv";

  guard = pkgs.writeShellApplication {
    name = "boot-trial-guard";
    runtimeInputs =
      with pkgs;
      [
        coreutils
        iputils
        jq
        systemd
      ]
      ++ lib.optional cfg.requireTailnet config.services.tailscale.package;
    text = ''
      read -r window armed_boot < ${armedFile} || true
      # The arming boot's id, not a timestamp: before NTP syncs, the clock is
      # whatever the RTC says, and a skewed RTC must not disarm the guard.
      if [ "''${armed_boot:-}" = "$(cat /proc/sys/kernel/random/boot_id)" ]; then
        # This is the boot being left, not the boot being tried (e.g. a switch
        # started the unit). Keep the arming for the next boot.
        echo "boot trial armed during this boot; it applies to the next one"
        exit 0
      fi
      if ! [[ "''${window:-}" =~ ^[0-9]+$ ]]; then
        window=${toString cfg.defaultWindowSeconds}
      fi
      # One attempt only: disarm before anything else, so a boot this guard
      # sends back to the GRUB default can never become a reboot loop.
      rm -f ${armedFile}
      echo "boot trial: kernel $(uname -r), $(readlink -f /run/current-system)"
      echo "boot trial: proving the network within ''${window}s"

      network_ok() {
        ping -c 1 -W 3 ${cfg.gateway} >/dev/null 2>&1 || return 1
        ${lib.optionalString cfg.requireTailnet ''
          tailscale status --json 2>/dev/null |
            jq -e '.BackendState == "Running" and .Self.Online == true' >/dev/null || return 1
        ''}
        return 0
      }

      deadline=$(( SECONDS + window ))
      while [ "$SECONDS" -lt "$deadline" ]; do
        if network_ok; then
          echo "boot trial PASSED after ''${SECONDS}s: gateway ${cfg.gateway} answers${lib.optionalString cfg.requireTailnet ", tailnet up"}"
          printf '%s %s %s\n' "$(date -Is)" "$(uname -r)" "$(readlink -f /run/current-system)" > ${passedFile}
          echo "boot trial: make it the default with: boot-trial promote"
          exit 0
        fi
        sleep 10
      done

      echo "boot trial FAILED: no network within ''${window}s; rebooting into the GRUB default (last known-good)"
      systemctl --no-block --check-inhibitors=no reboot
    '';
  };

  cli = pkgs.writeShellApplication {
    name = "boot-trial";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      gnused
      grub2
    ];
    text = ''
      die() { echo "boot-trial: $*" >&2; exit 1; }
      [ "$(id -u)" -eq 0 ] || die "run as root"

      status() {
        echo "booted:   $(uname -r)  $(readlink -f /run/current-system)"
        echo "default:  $(grep -m1 -E '^\s*linux ' /boot/grub/grub.cfg | sed -E 's/^\s*linux //; s/ .*//')"
        echo "grubenv:  $(grub-editenv ${grubenv} list | tr '\n' ' ')"
        if [ -e ${armedFile} ]; then echo "armed:    $(cat ${armedFile}) (window seconds, arming boot id)"; else echo "armed:    no"; fi
        if [ -e ${passedFile} ]; then echo "passed:   $(cat ${passedFile})"; fi
      }

      case "''${1:-status}" in
        status)
          status
          ;;
        arm)
          [ $# -ge 2 ] || die "usage: boot-trial arm <known-good-generation> [window-seconds]"
          known_good="/nix/var/nix/profiles/system-$2-link"
          window="''${3:-${toString cfg.defaultWindowSeconds}}"
          if ! [[ "$window" =~ ^[0-9]+$ ]] || [ "$window" -lt 120 ]; then
            die "window must be >= 120 seconds"
          fi
          [ -e "$known_good/kernel" ] || die "no generation $2"
          current="$(readlink -f /run/current-system)"
          [ "$(readlink -f "$known_good")" != "$current" ] || die "generation $2 is the running system; nothing to try"

          trial=""
          for link in /nix/var/nix/profiles/system-*-link; do
            if [ "$(readlink -f "$link")" = "$current" ]; then
              trial="$(basename "$link" | sed -E 's/^system-([0-9]+)-link$/\1/')"
            fi
          done
          [ -n "$trial" ] || die "the running system is not a profile generation"

          # The known-good generation's own bootloader, GRUB included: the
          # fallback must be exactly what last booted, not today's GRUB.
          echo "default -> generation $2 ($(readlink -f "$known_good"))"
          "$known_good/bin/switch-to-configuration" boot

          title="$(grep -o "menuentry \"NixOS - Configuration $trial ([^\"]*)\"" /boot/grub/grub.cfg |
            sed -E 's/^menuentry "//; s/"$//')"
          [ -n "$title" ] || die "no grub.cfg entry for generation $trial"
          grub-editenv ${grubenv} set "next_entry=NixOS - All configurations>$title"

          mkdir -p ${stateDir}
          rm -f ${passedFile}
          echo "$window $(cat /proc/sys/kernel/random/boot_id)" > ${armedFile}
          echo "once   -> $title"
          status
          echo "armed. Reboot to try generation $trial once; any failed boot falls back to generation $2."
          ;;
        promote)
          /run/current-system/bin/switch-to-configuration boot
          status
          ;;
        *)
          die "usage: boot-trial [status | arm <known-good-generation> [window-seconds] | promote]"
          ;;
      esac
    '';
  };
in
{
  options.nixcfg.bootTrial = {
    enable = lib.mkEnableOption "one-shot boot trials with automatic fallback (OPS-213)";

    gateway = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default =
        if config.networking.defaultGateway == null then null else config.networking.defaultGateway.address;
      defaultText = lib.literalExpression "config.networking.defaultGateway.address";
      description = "Address the guard must reach for a trial boot to count as networked.";
    };

    requireTailnet = lib.mkOption {
      type = lib.types.bool;
      default = config.services.tailscale.enable;
      defaultText = lib.literalExpression "config.services.tailscale.enable";
      description = ''
        Also require tailscale to be running and online. An offsite host that
        reaches its gateway but not the tailnet is still unreachable.
      '';
    };

    defaultWindowSeconds = lib.mkOption {
      type = lib.types.ints.between 120 3600;
      default = 600;
      description = ''
        How long an armed boot has to prove its network before the guard
        reboots it into the known-good default. `boot-trial arm` can override
        it per trial.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.gateway != null;
        message = "nixcfg.bootTrial needs a gateway (set networking.defaultGateway or nixcfg.bootTrial.gateway).";
      }
      {
        assertion = config.boot.loader.grub.enable;
        message = "nixcfg.bootTrial relies on GRUB's next_entry one-shot.";
      }
    ];

    boot.kernelParams = [
      "panic=30"
      "softlockup_panic=1"
      "nmi_watchdog=panic"
      "sysctl.kernel.panic_on_rcu_stall=1"
      # NixOS's own initrd panic-on-fail.service: emergency.target -> panic.
      "boot.panic_on_fail"
    ];

    environment.systemPackages = [ cli ];

    systemd.tmpfiles.rules = [ "d ${stateDir} 0700 root root -" ];

    systemd.services.boot-trial-guard = {
      description = "Boot trial guard: without network, fall back to the GRUB default (OPS-213)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ] ++ lib.optional cfg.requireTailnet "tailscaled.service";
      unitConfig.ConditionPathExists = armedFile;
      # A switch must never start a second attempt or cut the running one short.
      restartIfChanged = false;
      serviceConfig = {
        # exec, not oneshot: the window must not hold up multi-user.target.
        Type = "exec";
        ExecStart = lib.getExe guard;
        # Also on the console, for whoever stands in front of the box.
        StandardOutput = "journal+console";
        StandardError = "journal+console";
      };
    };
  };
}
