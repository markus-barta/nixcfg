# NIX-584: unconditional Traefik fragment that keeps classic PPM public
# origins answering from Aeon after classic Paimos is retired.
#
# pm.barta.cm and flow.inspr.at/paimos MUST keep doing this (AEON-43 / AEON-261):
# browser navigation 302s to Aeon's /from-classic; classic API paths (any method)
# are rewritten to /from-classic/api, which answers 410 {"error":"moved"}.
#
# Self-contained: no cutover switches, no classic legacy host, no classic container.
# Merged into the legacy Flow fragment in configuration.nix. Priorities sit
# above every live paimos router (edge max 10001, measured 2026-09-26).
{
  entryPoint ? "web-secure",
  certificateResolver ? "default",
}:

let
  tlsRouter = {
    entryPoints = [ entryPoint ];
    tls.certResolver = certificateResolver;
  };
  classicPrefix = "PathRegexp(`^/paimos(/|%2[fF]|$)`)";
  classicApi = "PathRegexp(`^/(paimos(/|%2[fF]))?api(/|%2[fF]|$)`)";
in
{
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
        regex = "^https?://(?:pm\\.barta\\.cm(?:/paimos)?|flow\\.inspr\\.at/paimos)(/.*|\\?.*)?$";
        replacement = "https://aeon.barta.cm/from-classic\${1}";
        permanent = false;
      };
    };
    services.ops231-aeon.loadBalancer.servers = [ { url = "http://aeon:8080"; } ];
  };
}
