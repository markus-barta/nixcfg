# Offline: nix-instantiate --eval --strict --json --arg root "$PWD" \
#   tests/mbp2607-ci-vm-eval.nix
{
  root,
  moduleOnly ? true,
}:
let
  lib = (import <nixpkgs/lib>).extend (
    _: _: {
      hm.dag.entryBetween = before: after: data: { inherit before after data; };
    }
  );
  write = name: text: {
    inherit text;
    outPath = "/fixture/${name}";
  };
  pkgs = {
    colima = "/fixture/colima";
    jq = "/fixture/jq";
    python3 = "/fixture/python3";
    writeText = write;
    writeShellScript =
      name: text:
      assert lib.assertMsg (
        name != "ci-vm-qos"
        || (
          lib.hasInfix "export COLIMA_HOME=" text
          && lib.hasInfix ''export LIMA_HOME="$COLIMA_HOME/_lima"'' text
          && lib.hasInfix ''qos "$COLIMA_HOME/_lima/colima-ci/ha.pid"'' text
        )
      ) "QoS helper must explicitly share the module Colima/Lima homes";
      write name text;
    writeShellScriptBin = write;
  };
  fixture = {
    options = {
      home.homeDirectory = lib.mkOption { type = lib.types.str; };
      xdg.configHome = lib.mkOption {
        type = lib.types.str;
        default = "/Users/markus/.config";
      };
      home.packages = lib.mkOption { type = lib.types.listOf lib.types.anything; };
      home.file = lib.mkOption { type = lib.types.attrs; };
      home.activation = lib.mkOption { type = lib.types.attrs; };
      launchd.agents = lib.mkOption { type = lib.types.attrs; };
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [ ];
      };
    };
    config.home.homeDirectory = "/Users/markus";
  };
  evaluate =
    settings:
    (lib.evalModules {
      specialArgs = { inherit lib pkgs; };
      modules = [
        (root + "/hosts/mbp2607/ci-vm.nix")
        fixture
        settings
      ];
    }).config;
  module = evaluate {
    services.ciVm = {
      enable = true;
      repositories.hausnetz.repository = "inspr-at/hausnetz";
    };
  };
  host =
    if moduleOnly then
      module
    else
      (builtins.getFlake (toString root)).homeConfigurations."markus@mbp2607".config;
  agent = host.launchd.agents.ci-vm-dispatcher;
  launch = agent.config;
  colima = builtins.fromJSON module.home.file.".config/ci-vm/colima.yaml".source.text;
  provision = (builtins.head colima.provision).script;
  repos = builtins.fromJSON module.home.file.".config/ci-vm/repositories.json".source.text;
  two = evaluate {
    services.ciVm = {
      enable = true;
      repositories = {
        hausnetz.repository = "inspr-at/hausnetz";
        extra.repository = "inspr-at/extra";
      };
    };
  };
  disabled = evaluate { services.ciVm.enable = false; };
  invalid = evaluate {
    services.ciVm = {
      enable = true;
      repositories."bad/path".repository = "inspr-at/hausnetz";
    };
  };
  activation = host.home.activation.ciVmDirectories;
  command = (builtins.head module.home.packages).text;
  customXdg = evaluate {
    xdg.configHome = "/Users/markus/ci-xdg-test";
    services.ciVm = {
      enable = true;
      repositories.hausnetz.repository = "inspr-at/hausnetz";
    };
  };
  ciFiles = root + "/hosts/mbp2607/files/ci-vm";
  moduleSource = builtins.readFile (root + "/hosts/mbp2607/ci-vm.nix");
  sources = [
    moduleSource
    (builtins.readFile (root + "/hosts/mbp2607/README.md"))
  ]
  ++ map (name: builtins.readFile (ciFiles + "/${name}")) (
    builtins.attrNames (builtins.readDir ciFiles)
  );
  checks = {
    enabled = agent.enable && host.services.ciVm.enable;
    explicitColimaHome =
      lib.hasInfix "export XDG_CONFIG_HOME=/Users/markus/.config" command
      && lib.hasInfix "export COLIMA_HOME=/Users/markus/.config/colima" command;
    explicitLimaHome = lib.hasInfix ''export LIMA_HOME="$COLIMA_HOME/_lima"'' command;
    configurableXdgHome = lib.hasInfix "export COLIMA_HOME=/Users/markus/ci-xdg-test/colima" (builtins.head customXdg.home.packages)
    .text;
    qosColimaHome = lib.hasInfix ''qos "$COLIMA_HOME/_lima/colima-ci/ha.pid"'' moduleSource;
    noLegacyColimaHome = lib.all (source: !lib.hasInfix "/.colima" source) sources;
    hardCaps = colima.cpu == 6 && colima.memory == 16 && colima.disk == 150 && colima.rootDisk == 150;
    linuxKvm = colima.arch == "aarch64" && colima.vmType == "vz" && colima.nestedVirtualization;
    singleDisk = colima.runtime == "none";
    noAutoActivation = !colima.autoActivate && !colima.sshConfig && !colima.forwardAgent;
    onlySecretsMount =
      colima.mounts == [
        {
          location = "/Users/markus/.local/state/ci-vm/secrets";
          mountPoint = "/etc/ci-vm-private/secrets";
          writable = false;
        }
      ];
    everyBoot =
      builtins.length colima.provision == 1 && (builtins.head colima.provision).mode == "system";
    runnerIdentity =
      (builtins.head repos) == {
        id = "hausnetz";
        repository = "inspr-at/hausnetz";
        runnerName = "mbp2607-hausnetz";
        labels = [
          "mbp2607"
          "hausnetz"
          "kvm"
        ];
      };
    extensible =
      builtins.length (builtins.fromJSON two.home.file.".config/ci-vm/repositories.json".source.text)
      == 2;
    invalidUserRejected = !lib.all (a: a.assertion) invalid.assertions;
    disabledIsInert =
      !(disabled.launchd.agents or { } ? ci-vm-dispatcher) && (disabled.home.packages or [ ]) == [ ];
    positiveAssertions = lib.all (a: a.assertion) host.assertions;
    pollAndGrace =
      launch.StartInterval == 60
      && launch.RunAtLoad
      && ((launch.KeepAlive or null) == null || !launch.KeepAlive);
    background =
      launch.ProcessType == "Background"
      && launch.LowPriorityIO
      && launch.LowPriorityBackgroundIO
      && launch.AbandonProcessGroup;
    log =
      launch.StandardOutPath == "/Users/markus/.local/share/ops-qa/state/ci-vm-dispatcher.log"
      && launch.StandardErrorPath == launch.StandardOutPath;
    activationOrdering =
      activation.before == [ "setupLaunchAgents" ] && activation.after == [ "writeBoundary" ];
    privateMountDirectory = lib.hasInfix "chmod 0700" activation.data;
    privateGuestMountParent = lib.hasInfix "install -d -o root -g root -m 0700 /etc/ci-vm-private" provision;
    noActivationStart = !lib.hasInfix "colima start" activation.data;
    nixPinned =
      lib.hasInfix "nix_version=2.31.2" provision
      && lib.hasInfix "64db528412096d718b4bf8f78f85e5ac2b714b774e5005500dee37d23f560456" provision;
    runnerPinned =
      lib.hasInfix "runner_version=2.338.2" provision
      && lib.hasInfix "670adb2f268fe21dcbb58b3db0e0aa9d5b3bddfe2c651481336e561ff86de945" provision;
    archiveHashCheck = lib.hasInfix "sha256sum --check --status" provision;
    provisioningHealthGate = lib.hasInfix "cat /proc/sys/kernel/random/boot_id >/var/lib/ci-vm/ready" provision;
    qosBeforeRunner = lib.hasInfix "ConditionPathExists=/run/ci-vm-host-qos-ready" provision;
    nixFeatures = lib.hasInfix "system-features = nixos-test benchmark big-parallel kvm" provision;
    perRepositoryUser =
      lib.hasInfix ''user="ci-$id"'' provision && lib.hasInfix "SupplementaryGroups=kvm" provision;
    executableRunnerUnit =
      lib.hasInfix "ExecStart=$dir/bin/runsvc.sh" provision && lib.hasInfix "Type=exec" provision;
    sandboxKvm = lib.hasInfix "chmod 0666 /dev/kvm" provision;
    serviceLimits =
      lib.hasInfix "MemoryHigh=5G" provision
      && lib.hasInfix "MemoryMax=6G" provision
      && lib.hasInfix "MemoryHigh=8G" provision
      && lib.hasInfix "MemoryMax=10G" provision;
    guestFirewall =
      lib.hasInfix "meta skuid { $uids } ip daddr 192.168.5.2" provision
      && lib.hasInfix "Requires=ci-vm-firewall.service" provision;
    nixDiskReserve = lib.hasInfix "min-free = 5368709120" provision;
    enrollmentEnvironment = lib.all (name: lib.hasInfix "ACTIONS_RUNNER_INPUT_${name}" provision) [
      "URL"
      "TOKEN"
      "NAME"
      "LABELS"
      "UNATTENDED"
      "REPLACE"
      "DISABLEUPDATE"
    ];
    noRegistrationApi = !lib.hasInfix "registration-token" provision;
    noUnexpandedInputs =
      !lib.hasInfix "@repositories@" provision
      && !lib.hasInfix "@register@" provision
      && !lib.hasInfix "@control@" provision
      && !lib.hasInfix "@nixVersion@" provision;
  };
in
assert lib.assertMsg (lib.all (x: x) (lib.attrValues checks))
  "OPS-669 eval failed: ${
    lib.concatStringsSep ", " (lib.attrNames (lib.filterAttrs (_: v: !v) checks))
  }";
{
  inherit checks colima repos;
}
