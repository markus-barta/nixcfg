# OPS-233: Traefik file-provider fragment for the classic PPM cutover.
#
# Merged into the legacy Flow fragment in configuration.nix. Returns an empty
# attrset while both switches in ppm-cutover.nix are false, so the rendered
# dynamic config does not change until a window flips one of them.
{
  lib,
  cutover,
  entryPoint ? "web-secure",
  certificateResolver ? "default",
}:

let
  tlsRouter = {
    entryPoints = [ entryPoint ];
    tls.certResolver = certificateResolver;
  };
  # Reuses the deny service and middleware declared by legacy-flow-routing.nix.
  deny = tlsRouter // {
    service = "inspr-legacy-flow-deny";
    middlewares = [ "inspr-legacy-flow-deny" ];
  };
  readMethods = "(Method(`GET`) || Method(`HEAD`) || Method(`OPTIONS`))";
  classicPrefix = "PathRegexp(`^/paimos(/|%2[fF]|$)`)";
  legacy = "Host(`${cutover.legacyHost}`)";
  legacyProxy =
    rule: middlewares: priority:
    tlsRouter
    // {
      inherit rule priority;
      middlewares = [ "cloudflarewarp@file" ] ++ middlewares;
      service = "ops233-ppm-legacy";
    };

  freezeFragment = {
    http.routers.ops233-ppm-write-freeze = deny // {
      # Above every live paimos router (max 10001, measured 2026-09-26).
      priority = 20000;
      rule =
        "(Host(`pm.barta.cm`) || (Host(`flow.inspr.at`) && ${classicPrefix}))" + " && !${readMethods}";
    };
  };

  legacyFragment = {
    http = {
      routers = {
        ops233-ppm-legacy-internal = deny // {
          priority = 1300;
          rule = "${legacy} && PathRegexp(`^/(paimos(/|%2[fF]))?internal(/|%2[fF]|$)`)";
        };
        ops233-ppm-legacy-prefixed =
          legacyProxy "${legacy} && (Method(`GET`) || Method(`HEAD`)) && ${classicPrefix}" [ ]
            1100;
        ops233-ppm-legacy-root = legacyProxy "${legacy} && (Method(`GET`) || Method(`HEAD`))" [
          "inspr-legacy-paimos-prefix"
        ] 1000;
      };
      # Straight to the classic container, never the edge's paimos upstream,
      # which the cutover re-points at Aeon.
      services.ops233-ppm-legacy.loadBalancer.servers = [ { url = "http://ppm:8888"; } ];
    };
  };
  # Step 5 (AEON-43). Above every live paimos router (edge max 10001).
  classicApi = "PathRegexp(`^/(paimos(/|%2[fF]))?api(/|%2[fF]|$)`)";
  aeonFragment = {
    http = {
      routers = {
        ops231-aeon-classic-api = tlsRouter // {
          priority = 15100;
          rule = "(Host(`pm.barta.cm`) && ${classicApi}) || (Host(`flow.inspr.at`) && PathRegexp(`^/paimos(/|%2[fF])api(/|%2[fF]|$)`))";
          middlewares = [
            "cloudflarewarp@file"
            "ops231-aeon-classic-api-rewrite"
          ];
          service = "ops231-aeon";
        };
        ops231-aeon-classic-browser = tlsRouter // {
          priority = 15000;
          rule = "Host(`pm.barta.cm`) || (Host(`flow.inspr.at`) && ${classicPrefix})";
          middlewares = [
            "cloudflarewarp@file"
            "ops231-aeon-from-classic"
          ];
          # The redirect middleware answers; the service is never reached.
          service = "inspr-legacy-flow-deny";
        };
      };
      middlewares = {
        ops231-aeon-classic-api-rewrite.replacePathRegex = {
          regex = "^/(?:paimos/)?api(.*)$";
          replacement = "/from-classic/api$1";
        };
        ops231-aeon-from-classic.redirectRegex = {
          regex = "^https?://(?:pm\\.barta\\.cm(?:/paimos)?|flow\\.inspr\\.at/paimos)(/.*)?$";
          replacement = "https://aeon.barta.cm/from-classic\${1}";
          permanent = false;
        };
      };
      services.ops231-aeon.loadBalancer.servers = [ { url = "http://aeon:8080"; } ];
    };
  };
in
assert builtins.isBool cutover.freeze && builtins.isBool cutover.legacy;
assert builtins.match "[a-z0-9-]+(\\.[a-z0-9-]+)+" cutover.legacyHost != null;
builtins.foldl' lib.recursiveUpdate { } (
  (if cutover.freeze then [ freezeFragment ] else [ ])
  ++ (if cutover.aeonRoutes or false then [ aeonFragment ] else [ ])
  ++ (if cutover.legacy then [ legacyFragment ] else [ ])
)
