# OPS-327 isolated agm2 test, never build this NixOS derivation on macOS.
# On the Linux builder, with the repo's locked nixpkgs already available:
# nix-build tests/docker-image-gc-vm.nix --arg pkgs \
#   '(import (builtins.getFlake (toString ./.)).inputs.nixpkgs { system = "x86_64-linux"; })'
# Runtime: ~2 hours (real 600/180/120/30 s unit budgets), plus image/VM build.
{
  pkgs ? import <nixpkgs> { system = "x86_64-linux"; },
}:
let
  inherit (pkgs) lib;
  mkImage =
    n:
    pkgs.dockerTools.buildImage {
      name = "localhost:5000/fixture";
      tag = "r${toString n}";
      created = "2000-01-01T00:00:01Z";
      copyToRoot = pkgs.buildEnv {
        name = "ops327-image-root";
        paths = [ pkgs.busybox ];
        pathsToLink = [ "/bin" ];
      };
      config = {
        Env = [ "FIXTURE_ID=${toString n}" ];
        Cmd = [
          "/bin/sh"
          "-c"
          "trap 'exit 0' TERM; while :; do sleep 1; done"
        ];
      };
    };
  images = map mkImage (lib.range 1 8);
  entry = pkgs.writeShellScriptBin "ops327-vm" ''
    exec ${pkgs.python3}/bin/python3 /etc/ops327/support.py "$@"
  '';
in
pkgs.testers.runNixOSTest {
  name = "docker-image-gc-r34";
  globalTimeout = 14400;
  nodes.machine =
    { config, lib, ... }:
    {
      imports = [ ../hosts/csb1/docker-image-gc.nix ];
      options.nixcfg.composeStack.renderedSpec = lib.mkOption { type = lib.types.attrs; };
      config = {
        virtualisation.memorySize = 3072;
        virtualisation.cores = 2;
        virtualisation.diskSize = 8192;
        # Every system and specialisation is prebuilt; rollback only updates
        # profiles. A read-only store avoids overlayfs file/device mismatches.
        virtualisation.writableStore = false;
        virtualisation.docker.enable = true;
        virtualisation.docker.listenOptions = [ "/run/ops327-docker.sock" ];
        virtualisation.docker.daemon.settings.insecure-registries = [
          "localhost:5000"
          "localhost:5001"
        ];
        networking.firewall.enable = false;
        environment.systemPackages = [
          pkgs.python3
          pkgs.util-linux
          pkgs.docker-compose
          pkgs.curl
          entry
          pkgs.nixos-rebuild
        ];
        nix.settings.substituters = lib.mkForce [ ];
        nix.settings.experimental-features = [
          "nix-command"
          "flakes"
        ];
        nixcfg.composeStack.renderedSpec.services.live.image = "ghcr.io/inspr-at/aeon:live";
        environment.etc."compose/csb1/docker-compose.yml".text =
          builtins.toJSON config.nixcfg.composeStack.renderedSpec;
        environment.etc."ops327/gc.py".source = pkgs.replaceVars ../hosts/csb1/docker-image-gc.py {
          DECLARED_REFS = "[]";
        };
        environment.etc."ops327/support.py".source = ./docker-image-gc-vm-support.py;
        environment.etc."ops327/harness.py".source = ./docker-image-gc-harness.py;
        environment.etc."ops327/vm-only".text = "OPS-327 disposable VM\n";
        environment.etc."ops327/images.json".text = builtins.toJSON (map toString images);
        environment.etc."ops327/registry.yml".text = ''
          version: 0.1
          log:
            level: error
          storage:
            filesystem:
              rootdirectory: /var/lib/ops327-registry
          http:
            addr: 127.0.0.1:5000
        '';
        systemd.services.ops327-registry = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = "${pkgs.distribution}/bin/registry serve /etc/ops327/registry.yml";
            StateDirectory = "ops327-registry";
          };
        };
        systemd.services.ops327-proxy = {
          serviceConfig.ExecStart = "${lib.getExe entry} proxy";
        };
        systemd.services.ops327-gc = {
          after = [
            "docker.service"
            "ops327-proxy.service"
          ];
          requires = [
            "docker.service"
            "ops327-proxy.service"
          ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${lib.getExe entry} gc";
            TimeoutStartSec = "1h";
            TimeoutStopSec = 180;
          };
        };
        systemd.services.compose-csb1 = {
          wantedBy = [ "multi-user.target" ];
          restartTriggers = [ config.environment.etc."compose/csb1/docker-compose.yml".source ];
          unitConfig = {
            StartLimitIntervalSec = 300;
            StartLimitBurst = 3;
            ConditionPathExists = "/run/ops327-ready";
          };
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${lib.getExe entry} compose";
            Restart = "on-failure";
            RestartSec = 30;
            TimeoutStartSec = 600;
          };
        };
        systemd.services.janus-managed-canary = {
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${lib.getExe entry} canary-start";
            ExecStop = "${lib.getExe entry} canary-stop";
            TimeoutStartSec = 120;
            TimeoutStopSec = 30;
          };
        };
        systemd.services.hausv-backup-snapshot = {
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${lib.getExe entry} hausv";
            TimeoutStartSec = 180;
            TimeoutStopSec = 90;
          };
        };
        specialisation.changed.configuration = {
          environment.etc."compose/csb1/docker-compose.yml".text = lib.mkForce (
            builtins.toJSON {
              services.live = {
                image = "localhost:5000/fixture:r8";
              };
            }
          );
        };
        specialisation.old2.configuration = {
          environment.etc."compose/csb1/docker-compose.yml".text = lib.mkForce (
            builtins.toJSON {
              services.live = {
                image = "localhost:5000/fixture:r2";
              };
            }
          );
        };
        specialisation.old3.configuration = {
          environment.etc."compose/csb1/docker-compose.yml".text = lib.mkForce (
            builtins.toJSON {
              services.live = {
                image = "localhost:5000/fixture:r3";
              };
            }
          );
        };
        # A real switch stays inside ng after activate, allowing /proc/locks
        # token matching while its compose job waits. No activation barrier.
        systemd.timers.docker-image-gc.enable = lib.mkForce false;
        system.stateVersion = "26.05";
      };
    };
  testScript = ''
    start_all()
    machine.wait_for_unit("docker.service")
    machine.wait_for_unit("ops327-registry.service")
    machine.succeed("ops327-vm prepare", timeout=180)
    machine.succeed("ops327-vm checks", timeout=12000)
    machine.copy_from_vm("/var/lib/ops327/results.json")
    machine.copy_from_vm("/var/lib/ops327/unit-outcomes.json")
  '';
}
