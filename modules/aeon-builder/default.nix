# NIX-600: mbp2606 as a switchable, hardened runner pool for inspr-at/paimos.
#
# Home Manager module for the dedicated `ci` user. Mode B of the AEON-438
# contract (paimos docs/RELEASE.md): no idle runners; the controller verifies a
# queued job through the API, clones a fresh Lima VM from a sealed base, checks
# the VM cannot reach LAN/tailnet/host, and only then mints a one-job JIT runner.
# `aeon-builder on|off|status`; from nixcfg: `just mbp2606-builder on|off|status`.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.aeonBuilder;

  templates = "${cfg.limaPackage}/share/lima/templates";

  scripts = {
    provisionScript = ./provision-base.sh;
    hookScript = ./job-started.sh;
    startRunnerScript = ./start-runner.sh;
    cacheLockScript = ./cache-lock.sh;
  };

  # Any change to what goes into the base VM rebuilds it on the next `on`.
  baseId = builtins.hashString "sha256" (
    builtins.toJSON {
      inherit (cfg)
        runner
        prePullImages
        events
        workflows
        branch
        repo
        slotDiskGiB
        ;
      lima = cfg.limaPackage.version;
      files = lib.mapAttrs (_: f: builtins.hashFile "sha256" f) scripts;
    }
  );

  settings = {
    inherit (cfg)
      repo
      label
      runnerLabels
      classLabels
      events
      workflows
      branch
      cacheWriteEvents
      slots
      slotCpus
      slotMemoryGiB
      slotDiskGiB
      cacheDiskGiB
      maxJobMinutes
      pollSeconds
      loadHigh
      loadLow
      sshPortBase
      labGuardUsers
      probeTargets
      requireNetworkBlock
      proofMinutes
      blockedNetworks
      prePullImages
      runner
      ruleset
      ;
    inherit baseId;
    appEnv = "${cfg.configDir}/app.env";
    appKey = "${cfg.configDir}/github-app.pem";
    limactl = "${cfg.limaPackage}/bin/limactl";
    baseTemplate = "${templates}/docker-rootful.yaml";
    provisionScript = "${scripts.provisionScript}";
    hookScript = "${scripts.hookScript}";
    startRunnerScript = "${scripts.startRunnerScript}";
    cacheLockScript = "${scripts.cacheLockScript}";
  };

  configFile = pkgs.writeText "aeon-builder.json" (builtins.toJSON settings);

  aeonBuilder = pkgs.writeShellApplication {
    name = "aeon-builder";
    runtimeInputs = [
      cfg.limaPackage
      pkgs.openssl
    ];
    text = ''
      exec ${pkgs.python3}/bin/python3 ${./aeon_builder.py} --config ${configFile} "$@"
    '';
  };
in
{
  options.services.aeonBuilder = {
    enable = lib.mkEnableOption "the mbp2606 runner pool for inspr-at/paimos (NIX-600)";

    limaPackage = lib.mkPackageOption pkgs "lima" { };

    configDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.config/aeon-builder";
      description = "Holds github-app.pem and app.env (app_id, installation_id); never copied into a VM.";
    };

    repo = lib.mkOption {
      type = lib.types.str;
      default = "inspr-at/paimos";
    };
    label = lib.mkOption {
      type = lib.types.str;
      default = "mbp2606";
    };
    runnerLabels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "self-hosted"
        "Linux"
        "ARM64"
        "mbp2606"
      ];
      description = "Never a hosted label (ubuntu-latest, …): AEON-438's ci-runner-guard rejects those.";
    };
    classLabels = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        push = "mbp2606-push";
        workflow_dispatch = "mbp2606-dispatch";
        pull_request = "mbp2606-pr";
        merge_group = "mbp2606-mq";
      };
      description = ''
        AEON-459: each runner also gets exactly one class label for its verified
        run's event, and only jobs carrying exactly that class are minted for, so
        jobs from different event classes cannot take each other's runners.
      '';
    };
    events = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "push"
        "workflow_dispatch"
      ];
      description = "Mirror of the ci.yml router allowlist (AEON-438); the smaller set wins.";
    };
    workflows = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        ".github/workflows/ci.yml"
        ".github/workflows/test-runner-smoke.yml"
      ];
    };
    branch = lib.mkOption {
      type = lib.types.str;
      default = "main";
    };
    cacheWriteEvents = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "push" ];
      description = "Events whose jobs get the trusted cache disk; all others get a disposable APFS clone of it.";
    };

    slots = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
    };
    slotCpus = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
    };
    slotMemoryGiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 7;
    };
    slotDiskGiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
    };
    cacheDiskGiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
    };
    maxJobMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
    };
    pollSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "The availability record expires after 30 s and must refresh at least every 10 s.";
    };
    loadHigh = lib.mkOption {
      type = lib.types.number;
      default = 12.0;
      description = "Stop taking new jobs when the host's 1-minute load exceeds this threshold; must exceed loadLow.";
    };
    loadLow = lib.mkOption {
      type = lib.types.addCheck lib.types.number (value: value >= 0);
      default = 8.0;
      description = "Resume taking jobs only when the host's 1-minute load falls below this threshold.";
    };
    sshPortBase = lib.mkOption {
      type = lib.types.port;
      default = 41020;
      description = ''
        Job VM ssh ports: base-1 for the base and proof VMs, then one per slot.
        The pf anchor allows only these on loopback, so they sit below the
        macOS ephemeral range (49152+) where no other listener (e.g. mba's
        Colima) can land by chance.
      '';
    };

    labGuardUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "mba" ];
      description = "`on` refuses while one of these users runs a lab VM (memory).";
    };
    requireNetworkBlock = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Every job VM must fail to reach the host and LAN before a runner is minted; otherwise the pool pauses.";
    };
    proofMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "While idle, re-prove the network block with a throwaway VM this often.";
    };
    probeTargets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "192.168.5.2:22" ];
      description = "Checked from each job VM besides the host's own addresses; 192.168.5.2 is the host loopback in Lima usernet.";
    };
    blockedNetworks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "10.0.0.0/8"
        "172.16.0.0/12"
        "192.168.0.0/16"
        "100.64.0.0/10"
        "169.254.0.0/16"
        "127.0.0.0/8"
        "fc00::/7"
        "fe80::/10"
        "::1"
      ];
    };

    prePullImages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "pgvector/pgvector:pg18" ];
    };
    runner = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        version = "2.337.0";
        sha256 = "9b1dc70626422526e3c94767cf024896beb15da5342a3f4819bf2feac13e0393";
      };
      description = "actions/runner linux-arm64 release, verified by sha256 inside the base VM.";
    };
    ruleset = lib.mkOption {
      type = lib.types.anything;
      default = {
        id = 24240960;
        expected = lib.importJSON ./paimos-main-ruleset.json;
      };
      description = ''
        The paimos main ruleset (AEON-411), checked before every mint and every
        availability publish. It must equal the pinned copy exactly; any drift
        pauses the pool. After an intended ruleset change, refresh the pin with
        `gh api repos/inspr-at/paimos/rulesets/24240960` (keys enforcement,
        target, conditions, bypass_actors, rules).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.loadHigh > cfg.loadLow;
        message = "services.aeonBuilder.loadHigh must be greater than loadLow.";
      }
    ];
    home.packages = [
      aeonBuilder
      cfg.limaPackage
    ];
  };
}
