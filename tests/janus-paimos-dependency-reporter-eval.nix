{
  root ? ../.,
  nixpkgsPath ? null,
  enable ? true,
  activate ? true,
  mode ? "static",
  includeExpected ? true,
  includeStaticEvidence ? mode == "static",
  includeManagedCompletion ? mode == "managedCompletion",
  expectedStageKey ? "deployment",
  managedOperationRef ? "op_fixture01234567",
  extraManagedCompletion ? { },
  apiKeyFile ? "/run/agenix/fixture-paimos-api-key",
  handoffSecretFile ? "/run/agenix/fixture-paimos-handoff-secret",
  journalDirectory ? "/var/lib/janus-paimos-dependency-reporter/journal",
}:
let
  nixpkgs =
    if nixpkgsPath == null then (builtins.getFlake (toString root)).inputs.nixpkgs else nixpkgsPath;
  pkgs = import nixpkgs { system = "x86_64-linux"; };
  lib = pkgs.lib;
  repeat = value: builtins.concatStringsSep "" (builtins.genList (_: value) 64);
  expected = {
    dependencyKey = "fixture-handoff";
    stageKey = expectedStageKey;
    executionNumber = 4;
    planDigest = "sha256:${repeat "1"}";
    predecessorDigest = "sha256:${repeat "2"}";
    contextDigest = "sha256:${repeat "3"}";
    authorityEpoch = 2;
    credentialEpoch = 3;
    expiresAt = "2099-09-09T20:00:00Z";
  };
  managedCompletion = {
    operationRef = managedOperationRef;
    hostRef = "host_fixture012345";
    serviceRef = "svc_fixture0123456";
    slotRef = "slot_fixture012345";
    declarationFingerprint = "decl_fixture012345";
    secretRef = "sec_" + "fixture012345";
    scopeRef = "scp_fixture0123456";
    generation = 7;
    revocationEpoch = 7;
    planFingerprint = repeat "a";
    targetFingerprint = repeat "b";
    producerKeyId = "key_fixture0123456";
  }
  // extraManagedCompletion;
  evaluated = import (nixpkgs + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      (root + "/modules/janus-paimos-dependency-reporter/default.nix")
      {
        nixpkgs.pkgs = pkgs;
        system.stateVersion = "25.05";
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        inspr.janusPaimosDependencyReporter = {
          inherit
            enable
            activate
            mode
            ;
          package = pkgs.hello;
          paimosOrigin = "https://pm.barta.cm";
          handoffId = "01ARZ3NDEKTSV4RRFFQ69G5FAV";
          inherit apiKeyFile handoffSecretFile journalDirectory;
          expected = if includeExpected then expected else null;
          evidence =
            if includeStaticEvidence then
              {
                kind = "credential_handoff";
                observedAt = "2026-09-09T12:00:00Z";
              }
            else
              null;
          managedCompletion = if includeManagedCompletion then managedCompletion else null;
        };
      }
    ];
  };
  failedAssertions = builtins.filter (item: !(item.assertion or true)) evaluated.config.assertions;
  reporter = evaluated.config.inspr.janusPaimosDependencyReporter;
  goldenBinding = {
    target_fingerprint = repeat "b";
    schema_version = 1;
    operation_ref = "op_goldenfixture1";
    operation_kind = "create";
    source = "generated";
    host_ref = "host_goldenfixture1";
    service_ref = "svc_goldenfixture1";
    slot_ref = "slot_goldenfixture1";
    declaration_fingerprint = "decl_goldenfixture1";
    secret_ref = "sec_goldenfixture1";
    scope_ref = "scp_goldenfixture1";
    generation = 7;
    revocation_epoch = 7;
    plan_fingerprint = repeat "a";
    producer_key_id = "key_goldenfixture1";
    reporter = {
      stage_key = "deployment";
      schema_version = 1;
      schema = "inspr.janus.paimos-managed-completion-reporter-binding.v1";
      predecessor_digest = "sha256:${repeat "2"}";
      plan_digest = "sha256:${repeat "1"}";
      handoff_id = "01ARZ3NDEKTSV4RRFFQ69G5FAV";
      expires_at = "2099-09-09T20:00:00Z";
      execution_number = 4;
      evidence_source = "managed_completion_record";
      evidence_kind = "credential_handoff";
      dependency_key = "golden-handoff";
      credential_epoch = 3;
      context_digest = "sha256:${repeat "3"}";
      config_digest = "sha256:${repeat "4"}";
      authority_epoch = 2;
    };
    schema = "inspr.janus.managed-completion-paimos-binding.v2";
  };
in
if failedAssertions != [ ] then
  throw (
    builtins.concatStringsSep "\n" (
      map (item: item.message or "Janus/Paimos reporter assertion failed") failedAssertions
    )
  )
else
  {
    inherit mode;
    generated = reporter.generated or null;
    managedOutput = reporter.managedCompletionOutput or null;
    recomputedConfigDigest =
      if reporter ? managedCompletionOutput && reporter.managedCompletionOutput != null then
        "sha256:${builtins.hashString "sha256" (builtins.toJSON reporter.managedCompletionOutput.config)}"
      else
        null;
    recomputedBindingDigest =
      if reporter ? managedCompletionOutput && reporter.managedCompletionOutput != null then
        "sha256:${builtins.hashString "sha256" (builtins.toJSON reporter.managedCompletionOutput.binding)}"
      else
        null;
    services =
      lib.mapAttrs
        (_: service: {
          inherit (service) description serviceConfig;
          after = service.after or [ ];
          before = service.before or [ ];
          requires = service.requires or [ ];
          restartTriggers = service.restartTriggers or [ ];
          unitConfig = service.unitConfig or { };
          wantedBy = service.wantedBy or [ ];
          wants = service.wants or [ ];
        })
        (lib.filterAttrs (name: _: lib.hasPrefix "janus-paimos-" name) evaluated.config.systemd.services);
    timers = lib.mapAttrs (_: timer: {
      inherit (timer) description timerConfig;
      wantedBy = timer.wantedBy or [ ];
    }) (lib.filterAttrs (name: _: lib.hasPrefix "janus-paimos-" name) evaluated.config.systemd.timers);
    paths = lib.mapAttrs (_: path: {
      inherit (path) description pathConfig;
      after = path.after or [ ];
      requires = path.requires or [ ];
      wantedBy = path.wantedBy or [ ];
    }) (lib.filterAttrs (name: _: lib.hasPrefix "janus-paimos-" name) evaluated.config.systemd.paths);
    tmpfiles = builtins.filter (
      rule: lib.hasInfix "janus-" rule
    ) evaluated.config.systemd.tmpfiles.rules;
    goldenBindingDigest = "sha256:${builtins.hashString "sha256" (builtins.toJSON goldenBinding)}";
  }
