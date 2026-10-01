# OPS-248: actual csb1 module integration, evaluated without builds or runtime
# credentials. Only booleans escape this projection, never service environments.
let
  flakeRef = builtins.getEnv "OPS248_FLAKE_REF";
  flake = builtins.getFlake flakeRef;
  inherit (flake.inputs.nixpkgs) lib;
  host = flake.nixosConfigurations.csb1;
  base = host.config;
  alter = module: (host.extendModules { modules = [ module ]; }).config;
  compose = cfg: cfg.nixcfg.composeStack;
  stack = cfg: cfg.systemd.services.compose-csb1;
  janus = cfg: cfg.systemd.services.janus-managed-transactiond;
  bytes = builtins.toJSON;
  changedServices =
    cfg:
    lib.filter (
      name:
      bytes (compose base).renderedSpec.services.${name}
      != bytes (compose cfg).renderedSpec.services.${name}
    ) (builtins.attrNames (compose base).renderedSpec.services);
  specVariant =
    patch:
    alter {
      nixcfg.composeStack.spec = lib.mkForce (lib.recursiveUpdate (compose base).spec patch);
    };
  fixture = builtins.toFile "ops248-public-fixture" "synthetic input reference; not a credential\n";
  rotate = name: alter { age.secrets.${name}.file = lib.mkForce fixture; };
  fails = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  aeon = specVariant { services.aeon.image = "example.invalid/ops248/aeon:probe"; };
  hostdash = alter { environment.etc."hostdash/csb1".source = lib.mkForce fixture; };
  hostdashAuth = rotate "csb-hostdash-oauth2-proxy-env";
  traefikEnv = rotate "traefik-variables";
  edgeToken = rotate "csb1-inspr-auth-env";
  edgeRenderer = alter {
    systemd.services.inspr-edge-config.script = lib.mkAfter "\n# OPS-248 renderer probe\n";
  };
  sharedRenderer = alter {
    systemd.services.inspr-shared-flow-config.script = lib.mkAfter "\n# OPS-248 shared renderer probe\n";
  };
  janusImage = specVariant {
    services.janus-managed-transactiond.image = "example.invalid/ops248/janus:probe";
  };
  janusSigning = rotate "csb1-janus-managed-host-signing-key";
  janusIdentity = rotate "csb1-janus-managed-age-identity";
  contracts = [
    "secretspec.toml"
    "managed-env-files.toml"
    "hooks.toml"
    "web-transaction-catalog.json"
    "release-channels-v1.json"
    "release-admission.json"
  ];
  contractChanges = map (
    name: alter { environment.etc."janus/managed/${name}".source = lib.mkForce fixture; }
  ) contracts;
  invalidService = alter { nixcfg.composeStack.serviceRefreshTriggers.absent = [ "probe" ]; };
  collision = labels: specVariant { services.hostdash.labels = labels; };
  sourcePath = name: "${flake.outPath}/hosts/csb1/${name}";
  traefikInputs = (compose base).serviceRefreshTriggers.traefik;
  hasTraefikInput = input: lib.any (item: toString item == toString input) traefikInputs;
  selectService = import ../modules/shared/compose-stack/service-definition.nix { inherit lib; };
  example = {
    name = "fixture";
    services.worker = {
      image = "example.invalid/worker:probe";
      networks = [ "private" ];
      volumes = [
        "data:/data"
        {
          type = "volume";
          source = "cache";
          target = "/cache";
        }
        "/run/file:/file"
      ];
      configs = [ "settings" ];
      secrets = [ { source = "credential"; } ];
    };
    networks = {
      private.internal = true;
      unrelated = null;
    };
    volumes = {
      data.external = true;
      cache = null;
      unused = null;
    };
    configs.settings.file = "/declared/config-path";
    secrets.credential.external = true;
  };
  projection = selectService example "worker";
  resourceChanges = map (patch: selectService (lib.recursiveUpdate example patch) "worker") [
    { networks.private.internal = false; }
    { volumes.data.name = "replacement"; }
    { configs.settings.file = "/different/config-path"; }
    { secrets.credential.name = "replacement"; }
  ];
in
{
  aeonChangesOnlyAeon = changedServices aeon == [ "aeon" ];
  aeonRestartsStack = (stack base).restartTriggers != (stack aeon).restartTriggers;
  aeonPreservesStartScript = (stack base).script == (stack aeon).script;
  noForcedRecreateInStartScript = !(lib.hasInfix "--force-recreate" (stack base).script);
  stableComposePathAndLock =
    lib.hasInfix "/etc/compose/csb1/docker-compose.yml" (stack base).script
    && lib.hasInfix "/run/lock/compose-csb1.lock" (stack base).script;
  aeonPreservesJanusTriggerBytes =
    bytes (janus base).restartTriggers == bytes (janus aeon).restartTriggers;
  inputsDoNotRetainWholeSourcePath =
    !(lib.hasInfix flake.outPath (bytes (compose base).serviceRefreshTriggers))
    && !(lib.hasInfix flake.outPath (bytes (janus base).restartTriggers));
  aeonPreservesJanusUnitBytes =
    base.systemd.units."janus-managed-transactiond.service".text
    == aeon.systemd.units."janus-managed-transactiond.service".text;
  hostdashRefreshIsScoped = changedServices hostdash == [ "hostdash" ];
  hostdashAuthRefreshIsScoped = changedServices hostdashAuth == [ "hostdash-auth" ];
  traefikCredentialRefreshIsScoped = changedServices traefikEnv == [ "traefik" ];
  edgeTokenRefreshesBothConsumers =
    changedServices edgeToken == [
      "inspr-auth"
      "traefik"
    ];
  edgeRendererRefreshesTraefik = changedServices edgeRenderer == [ "traefik" ];
  sharedRendererRefreshesTraefik = changedServices sharedRenderer == [ "traefik" ];
  unrelatedRefreshPreservesJanus =
    lib.all (cfg: bytes (janus base).restartTriggers == bytes (janus cfg).restartTriggers)
      [
        hostdash
        hostdashAuth
        traefikEnv
        edgeToken
        edgeRenderer
        sharedRenderer
      ];
  traefikTracksStaticAndDynamicFiles =
    hasTraefikInput (sourcePath "docker/traefik/static.yml")
    && hasTraefikInput (sourcePath "docker/traefik/dynamic.yml");
  traefikTracksCompiledRoutes =
    hasTraefikInput base.services.inspr.routingEdge.generatedFragmentFile
    && lib.any (item: lib.hasSuffix "csb1-legacy-flow-routing.json" (toString item)) traefikInputs;
  janusImageChangesTrigger =
    bytes (janus base).restartTriggers != bytes (janus janusImage).restartTriggers;
  janusBoundKeysChangeTrigger =
    lib.all
      (
        cfg:
        bytes (janus base).restartTriggers != bytes (janus cfg).restartTriggers
        && changedServices cfg == [ ]
      )
      [
        janusSigning
        janusIdentity
      ];
  everyJanusContractChangesTrigger = lib.all (
    cfg:
    bytes (janus base).restartTriggers != bytes (janus cfg).restartTriggers
    && changedServices cfg == [ ]
  ) contractChanges;
  janusTriggerInventory = builtins.length (janus base).restartTriggers == 9;
  rendererOrderingRetained =
    lib.all (unit: lib.elem unit (stack base).requires && lib.elem unit (stack base).after)
      [
        "inspr-edge-config.service"
        "inspr-shared-flow-config.service"
      ];
  janusOrderingRetained =
    lib.elem "compose-csb1.service" (janus base).after
    && !(lib.elem "compose-csb1.service" (janus base).requires);
  failedConvergenceStillRetries =
    (stack base).serviceConfig.Restart == "on-failure"
    && (stack base).startLimitBurst == 3
    && !(lib.hasInfix "|| true" (stack base).script);
  rejectsUnknownRefreshService = fails (compose invalidService).renderedSpec;
  rejectsListLabelCollision =
    fails
      (compose (collision [ "cm.barta.compose.refresh=manual" ])).renderedSpec;
  rejectsBareLabelCollision = fails (compose (collision [ "cm.barta.compose.refresh" ])).renderedSpec;
  rejectsMapLabelCollision =
    fails
      (compose (collision {
        "cm.barta.compose.refresh" = "manual";
      })).renderedSpec;
  mapLabelsSupported =
    let
      cfg = collision { "example.label" = "retained"; };
    in
    (compose cfg).renderedSpec.services.hostdash.labels."example.label" == "retained"
    && (compose cfg).renderedSpec.services.hostdash.labels ? "cm.barta.compose.refresh";
  projectionSelectsReferencedResources =
    builtins.attrNames projection.networks == [ "private" ]
    &&
      builtins.attrNames projection.volumes == [
        "cache"
        "data"
      ]
    && builtins.attrNames projection.configs == [ "settings" ]
    && builtins.attrNames projection.secrets == [ "credential" ];
  referencedResourceChangesTrigger = lib.all (value: bytes value != bytes projection) resourceChanges;
  unrelatedResourceDoesNotChangeTrigger =
    bytes projection == bytes (
      selectService (lib.recursiveUpdate example {
        networks.unrelated.internal = true;
        volumes.unused.external = true;
      }) "worker"
    );
  rejectsUnresolvedResource = fails (selectService (example // { networks = { }; }) "worker");
  implicitDefaultNetworkIsCovered =
    (selectService { services.worker.image = "fixture"; } "worker").networks == { default = null; };
}
