# OPS-669: on-demand Linux CI, confined to Colima's `ci` profile.
# No VM starts during activation. See README.md for enrollment and operation.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.ciVm;
  home = config.home.homeDirectory;
  colimaHome = "${config.xdg.configHome}/colima";
  colimaEnvironment = ''
    export XDG_CONFIG_HOME=${lib.escapeShellArg config.xdg.configHome}
    export COLIMA_HOME=${lib.escapeShellArg colimaHome}
    export LIMA_HOME="$COLIMA_HOME/_lima"
  '';
  stateDir = "${home}/.local/state/ci-vm";
  secretsDir = "${stateDir}/secrets";
  logDir = "${home}/.local/share/ops-qa/state";
  repos = lib.mapAttrsToList (id: repo: {
    inherit id;
    inherit (repo) repository runnerName labels;
  }) cfg.repositories;
  reposJson = builtins.toJSON repos;
  reposFile = pkgs.writeText "ci-vm-repositories.json" reposJson;
  # The entire upstream installer archive is authenticated before extraction.
  # Runner digest: GitHub release asset digest, actions/runner v2.338.2.
  provision =
    lib.replaceStrings
      [
        "@repositories@"
        "@register@"
        "@control@"
        "@nixVersion@"
        "@nixSha256@"
        "@runnerVersion@"
        "@runnerSha256@"
      ]
      [
        reposJson
        (builtins.readFile ./files/ci-vm/register.sh)
        (builtins.readFile ./files/ci-vm/control.sh)
        "2.31.2"
        "64db528412096d718b4bf8f78f85e5ac2b714b774e5005500dee37d23f560456"
        "2.338.2"
        "670adb2f268fe21dcbb58b3db0e0aa9d5b3bddfe2c651481336e561ff86de945"
      ]
      (builtins.readFile ./files/ci-vm/provision.sh);
  # JSON is valid YAML. Colima rewrites this file: the starter COPIES it.
  colimaConfig = pkgs.writeText "ci-colima.yaml" (
    builtins.toJSON {
      cpu = 4;
      memory = 16;
      disk = 150;
      rootDisk = 150;
      arch = "aarch64";
      vmType = "vz";
      nestedVirtualization = true;
      runtime = "none"; # One 150 GiB root disk; no second container-data disk.
      autoActivate = false;
      forwardAgent = false;
      sshConfig = false;
      rosetta = false;
      binfmt = false;
      portForwarder = "none";
      mountType = "virtiofs";
      mounts = [
        {
          location = secretsDir;
          mountPoint = "/etc/ci-vm-private/secrets";
          writable = false;
        }
      ];
      provision = [
        {
          mode = "system"; # Lima executes system provisions on every boot.
          script = provision;
        }
      ];
    }
  );
  hostHelper = pkgs.writeText "ci-vm-host.py" (
    lib.replaceStrings
      (map builtins.toJSON [
        "@stateDir@"
        "@pidfile@"
        "@dispatcher@"
      ])
      (map builtins.toJSON [
        stateDir
        "${colimaHome}/_lima/colima-ci/ha.pid"
        "${./files/ci-vm/dispatcher.sh}"
      ])
      (builtins.readFile ./files/ci-vm/host.py)
  );
  heavyLockHelper = pkgs.writeText "ci-vm-heavy-lock.py" (
    lib.replaceStrings
      [ (builtins.toJSON "/Users/Shared/ci-locks/mbp2607-heavy.lock.d") ]
      [ (builtins.toJSON cfg.heavyLockPath) ]
      (builtins.readFile ./files/ci-vm/heavy-lock.py)
  );
  dispatcher = pkgs.writeShellScriptBin "ci-vm" ''
    ${colimaEnvironment}
    export PATH=${
      lib.makeBinPath [
        pkgs.colima
        pkgs.jq
        pkgs.python3
      ]
    }:/usr/bin:/bin:/usr/sbin:/sbin
    export CI_VM_CONFIG=${colimaConfig}
    export CI_VM_REPOSITORIES=${reposFile}
    export CI_VM_HEAVY_LOCK_HELPER=${heavyLockHelper}
    export CI_VM_HEAVY_LOCK=${lib.escapeShellArg cfg.heavyLockPath}
    export CI_VM_HOST_HELPER=${hostHelper}
    exec /bin/bash ${./files/ci-vm/dispatcher.sh} "$@"
  '';
in
{
  options.services.ciVm = {
    enable = lib.mkEnableOption "the memory-capped, on-demand Colima CI VM";
    heavyLockPath = lib.mkOption {
      type = lib.types.str;
      default = "/Users/Shared/ci-locks/mbp2607-heavy.lock.d";
      description = "OPS-669 detail spec v1 heavy-CI lock shared with PAPP.";
    };
    repositories = lib.mkOption {
      default = { };
      description = "Private repositories, each with its own Unix user and runner service.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              repository = lib.mkOption {
                type = lib.types.strMatching "[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+";
                description = "GitHub owner/repository.";
              };
              runnerName = lib.mkOption {
                type = lib.types.strMatching "[A-Za-z0-9_-]+";
                default = "mbp2607-${name}";
              };
              labels = lib.mkOption {
                type = lib.types.listOf (lib.types.strMatching "[A-Za-z0-9_-]+");
                default = [
                  "mbp2607"
                  name
                  "kvm"
                ];
                description = "Additional labels; self-hosted, Linux and ARM64 are automatic.";
              };
            };
          }
        )
      );
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          repos != [ ] && lib.all (repo: builtins.match "[a-z][a-z0-9-]{0,23}" repo.id != null) repos;
        message = "ciVm requires repositories with safe Unix-user suffixes (1–24 lowercase letters/digits/hyphens).";
      }
      {
        assertion = lib.length (lib.unique (map (repo: repo.runnerName) repos)) == lib.length repos;
        message = "ciVm runner names must be unique.";
      }
    ];
    home.packages = [ dispatcher ];
    home.file.".config/ci-vm/colima.yaml".source = colimaConfig;
    home.file.".config/ci-vm/repositories.json".source = reposFile;
    home.activation.ciVmDirectories =
      lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ]
        ''
          run mkdir -p ${lib.escapeShellArg logDir}
          run mkdir -p ${lib.escapeShellArg secretsDir}
          run chmod 0700 ${lib.escapeShellArg stateDir} ${lib.escapeShellArg secretsDir}
        '';
    launchd.agents.ci-vm-dispatcher = {
      enable = true;
      config = {
        ProgramArguments = [
          "${dispatcher}/bin/ci-vm"
          "tick"
        ];
        EnvironmentVariables.HOME = home;
        ProcessType = "Standard";
        # The hostagent must survive the end of a single dispatcher poll.
        AbandonProcessGroup = true;
        StartInterval = 60;
        RunAtLoad = true;
        StandardOutPath = "${logDir}/ci-vm-dispatcher.log";
        StandardErrorPath = "${logDir}/ci-vm-dispatcher.log";
      };
    };
  };
}
