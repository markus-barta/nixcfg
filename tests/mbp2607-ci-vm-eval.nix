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
    writeShellScript = write;
    writeShellScriptBin = write;
  };
  fixture = {
    options = {
      home.homeDirectory = lib.mkOption { type = lib.types.str; };
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
  checks = {
    enabled = agent.enable && host.services.ciVm.enable;
    hardCaps = colima.cpu == 6 && colima.memory == 16 && colima.disk == 150 && colima.rootDisk == 150;
    linuxKvm = colima.arch == "aarch64" && colima.vmType == "vz" && colima.nestedVirtualization;
    singleDisk = colima.runtime == "none";
    noAutoActivation = !colima.autoActivate && !colima.sshConfig && !colima.forwardAgent;
    onlySecretsMount =
      colima.mounts == [
        {
          location = "/Users/markus/.local/state/ci-vm/secrets";
          mountPoint = "/etc/ci-vm-secrets";
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
    noActivationStart = !lib.hasInfix "colima start" activation.data;
    nixPinned =
      lib.hasInfix "nix_version=2.31.2" provision
      && lib.hasInfix "64db528412096d718b4bf8f78f85e5ac2b714b774e5005500dee37d23f560456" provision;
    runnerPinned =
      lib.hasInfix "runner_version=2.338.2" provision
      && lib.hasInfix "670adb2f268fe21dcbb58b3db0e0aa9d5b3bddfe2c651481336e561ff86de945" provision;
    verifyBeforeExtract = lib.hasInfix "sha256sum --check --status" provision;
    provisioningHealthGate = lib.hasInfix "cat /proc/sys/kernel/random/boot_id >/var/lib/ci-vm/ready" provision;
    qosBeforeRunner = lib.hasInfix "ConditionPathExists=/run/ci-vm-host-qos-ready" provision;
    nixFeatures = lib.hasInfix "system-features = nixos-test benchmark big-parallel kvm" provision;
    perRepositoryUser =
      lib.hasInfix ''user="ci-$id"'' provision && lib.hasInfix "SupplementaryGroups=kvm" provision;
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
