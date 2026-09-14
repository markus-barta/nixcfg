# NIX-501: csb1-owned compatibility routes for the shared Flow origin.
#
# This is a pure Traefik file-provider fragment. It does not activate routing,
# choose production addresses, or duplicate the shared routing-edge compiler.
# The coordinator must pass reviewed private caller ranges when wiring this
# fragment beside inspr-routing-edge.
{
  privateSourceRanges,
  entryPoint ? "web-secure",
  certificateResolver ? "default",
  edgeNamespace ? "inspr-routing-edge",
}:

let
  tlsRouter = {
    entryPoints = [ entryPoint ];
    tls.certResolver = certificateResolver;
  };
  edgeService = app: "${edgeNamespace}-upstream-${app}@file";
  denyService = "inspr-legacy-flow-deny";
  denyMiddleware = "inspr-legacy-flow-deny";
  host = name: "Host(`${name}`)";
  getOrHead = "(Method(`GET`) || Method(`HEAD`))";
  htmlNavigation = "HeaderRegexp(`Accept`, `(?i)(^|.*,\\s*)text/html(\\s*;.*)?(,.*|$)`)";
  ipv4Octet = "(0|[1-9][0-9]?|1[0-9][0-9]|2[0-4][0-9]|25[0-5])";
  # A private-looking address with a wider mask (e.g. 10.0.0.1/0)
  # includes public clients. Require the whole CIDR to stay within RFC1918.
  privateCidrPattern =
    "(10\\.${ipv4Octet}\\.${ipv4Octet}\\.${ipv4Octet}/(8|9|[12][0-9]|3[0-2])"
    + "|192\\.168\\.${ipv4Octet}\\.${ipv4Octet}/(1[6-9]|2[0-9]|3[0-2])"
    + "|172\\.(1[6-9]|2[0-9]|3[01])\\.${ipv4Octet}\\.${ipv4Octet}/(1[2-9]|2[0-9]|3[0-2]))";
  privateRule = ranges: builtins.concatStringsSep " || " (map (range: "ClientIP(`${range}`)") ranges);
  pathFamilies =
    paths:
    builtins.concatStringsSep " || " (map (path: "(Path(`${path}`) || PathPrefix(`${path}/`))") paths);
  pathRegexp = expression: "PathRegexp(`${expression}`)";
  rootInternal = pathRegexp "^/internal(/|%2[fF]|$)";
  prefixedInternal = app: pathRegexp "^/${app}(/|%2[fF])internal(/|%2[fF]|$)";
  rootApi = pathRegexp "^/api(/|%2[fF]|$)";
  prefixedPath = app: pathRegexp "^/${app}(/|%2[fF]|$)";
  callbackPath = app: callback: pathRegexp "^/(${app}(/|%2[fF]))?${callback}$";
  proxy =
    app: rule: middlewares: priority:
    tlsRouter
    // {
      inherit rule middlewares priority;
      service = edgeService app;
    };
  publicProxy =
    app: rule: middlewares: priority:
    proxy app rule ([ "cloudflarewarp@file" ] ++ middlewares) priority;
  redirect =
    rule: middleware: priority:
    tlsRouter
    // {
      inherit rule priority;
      middlewares = [
        "cloudflarewarp@file"
        middleware
      ];
      service = denyService;
    };
  denyInternal =
    name: internalRule:
    tlsRouter
    // {
      rule = "${host name} && (${internalRule})";
      priority = 1300;
      service = denyService;
      middlewares = [ denyMiddleware ];
    };
in
assert builtins.isAttrs privateSourceRanges;
assert privateSourceRanges ? pharos && builtins.length privateSourceRanges.pharos > 0;
assert privateSourceRanges ? janus && builtins.length privateSourceRanges.janus > 0;
assert builtins.all (
  range: builtins.match privateCidrPattern range != null
) privateSourceRanges.pharos;
assert builtins.all (
  range: builtins.match privateCidrPattern range != null
) privateSourceRanges.janus;
{
  http = {
    routers = {
      # Old-host callbacks cannot carry an authorization code or state into a
      # new-origin transaction. These rules also outrank prefixed pass-through.
      inspr-legacy-paimos-stale-callback = redirect (
        "${host "pm.barta.cm"} && ${getOrHead}"
        + " && ${callbackPath "paimos" "api(/|%2[fF])auth(/|%2[fF])oidc(/|%2[fF])callback"}"
      ) "inspr-legacy-paimos-restart-login" 1500;
      inspr-legacy-pharos-stale-callback = redirect (
        "${host "pharos.barta.cm"} && ${getOrHead}"
        + " && ${callbackPath "pharos" "auth(/|%2[fF])callback"}"
      ) "inspr-legacy-pharos-restart-login" 1500;
      inspr-legacy-janus-stale-callback = redirect (
        "${host "vault.barta.cm"} && ${getOrHead}" + " && ${callbackPath "janus" "oidc(/|%2[fF])callback"}"
      ) "inspr-legacy-janus-restart-login" 1500;

      # Start login on the destination origin before any state cookie is set.
      inspr-legacy-paimos-login = redirect (
        "${host "pm.barta.cm"} && ${getOrHead}"
        + " && ${callbackPath "paimos" "api(/|%2[fF])auth(/|%2[fF])oidc(/|%2[fF])login"}"
      ) "inspr-legacy-paimos-browser" 1450;
      inspr-legacy-pharos-login = redirect (
        "${host "pharos.barta.cm"} && ${getOrHead}" + " && ${callbackPath "pharos" "auth(/|%2[fF])login"}"
      ) "inspr-legacy-pharos-browser" 1450;
      inspr-legacy-janus-login = redirect (
        "${host "vault.barta.cm"} && ${getOrHead}" + " && ${callbackPath "janus" "login"}"
      ) "inspr-legacy-janus-browser" 1450;

      # Internal namespaces are decided before every broad compatibility rule.
      # Root forms receive one prefix; already-prefixed forms pass unchanged.
      inspr-legacy-pharos-private-internal-root = proxy "pharos" (
        "${host "pharos.barta.cm"} && ${rootInternal}" + " && (${privateRule privateSourceRanges.pharos})"
      ) [ "inspr-legacy-pharos-prefix" ] 1400;
      inspr-legacy-pharos-private-internal-prefixed = proxy "pharos" (
        "${host "pharos.barta.cm"} && ${prefixedInternal "pharos"}"
        + " && (${privateRule privateSourceRanges.pharos})"
      ) [ ] 1400;
      inspr-legacy-janus-private-internal-root = proxy "janus" (
        "${host "vault.barta.cm"} && ${rootInternal}" + " && (${privateRule privateSourceRanges.janus})"
      ) [ "inspr-legacy-janus-prefix" ] 1400;
      inspr-legacy-janus-private-internal-prefixed = proxy "janus" (
        "${host "vault.barta.cm"} && ${prefixedInternal "janus"}"
        + " && (${privateRule privateSourceRanges.janus})"
      ) [ ] 1400;
      inspr-legacy-paimos-public-internal = denyInternal "pm.barta.cm" (
        "${rootInternal} || ${prefixedInternal "paimos"}"
      );
      inspr-legacy-pharos-public-internal = denyInternal "pharos.barta.cm" (
        "${rootInternal} || ${prefixedInternal "pharos"}"
      );
      inspr-legacy-janus-public-internal = denyInternal "vault.barta.cm" (
        "${rootInternal} || ${prefixedInternal "janus"}"
      );

      # Native-prefix non-browser requests pass unchanged. HTML navigation
      # moves to the shared host; API, machine, internal and callback rules win.
      inspr-legacy-paimos-prefixed = publicProxy "paimos" (
        "${host "pm.barta.cm"} && ${prefixedPath "paimos"}"
      ) [ ] 850;
      inspr-legacy-pharos-prefixed = publicProxy "pharos" (
        "${host "pharos.barta.cm"} && ${prefixedPath "pharos"}"
      ) [ ] 850;
      inspr-legacy-janus-prefixed = publicProxy "janus" (
        "${host "vault.barta.cm"} && ${prefixedPath "janus"}"
      ) [ ] 850;

      # API paths remain APIs for every method and Accept header. Application
      # authentication, authorization, CSRF, and method handling stay decisive.
      inspr-legacy-paimos-api = publicProxy "paimos" ("${host "pm.barta.cm"} && ${rootApi}") [
        "inspr-legacy-paimos-prefix"
      ] 1100;
      inspr-legacy-pharos-api = publicProxy "pharos" ("${host "pharos.barta.cm"} && ${rootApi}") [
        "inspr-legacy-pharos-prefix"
      ] 1100;
      inspr-legacy-janus-api = publicProxy "janus" ("${host "vault.barta.cm"} && ${rootApi}") [
        "inspr-legacy-janus-prefix"
      ] 1100;

      inspr-legacy-paimos-prefixed-api = publicProxy "paimos" (
        "${host "pm.barta.cm"} && ${pathRegexp "^/paimos(/|%2[fF])api(/|%2[fF]|$)"}"
      ) [ ] 1100;
      inspr-legacy-pharos-prefixed-api = publicProxy "pharos" (
        "${host "pharos.barta.cm"} && ${pathRegexp "^/pharos(/|%2[fF])api(/|%2[fF]|$)"}"
      ) [ ] 1100;
      inspr-legacy-janus-prefixed-api = publicProxy "janus" (
        "${host "vault.barta.cm"} && ${pathRegexp "^/janus(/|%2[fF])api(/|%2[fF]|$)"}"
      ) [ ] 1100;

      # Stable machine and asset roots must not become browser redirects even
      # when a caller sends a broad or HTML-capable Accept header.
      inspr-legacy-paimos-machine = publicProxy "paimos" (
        "${host "pm.barta.cm"} && (${
          pathFamilies [
            "/brand"
            "/assets"
          ]
        })"
      ) [ "inspr-legacy-paimos-prefix" ] 1050;
      inspr-legacy-pharos-machine = publicProxy "pharos" (
        "${host "pharos.barta.cm"}"
        + " && (${
           pathFamilies [
             "/healthz"
             "/readyz"
             "/metrics"
             "/version"
             "/favicon.svg"
             "/assets"
             "/register"
             "/report"
             "/agent"
           ]
         })"
      ) [ "inspr-legacy-pharos-prefix" ] 1050;
      inspr-legacy-janus-machine = publicProxy "janus" (
        "${host "vault.barta.cm"}"
        + " && (${
           pathFamilies [
             "/healthz"
             "/readyz"
             "/buildz"
             "/favicon.ico"
             "/static"
           ]
         })"
      ) [ "inspr-legacy-janus-prefix" ] 1050;

      inspr-legacy-paimos-prefixed-machine = publicProxy "paimos" (
        "${host "pm.barta.cm"} && (${
          pathFamilies [
            "/paimos/brand"
            "/paimos/assets"
          ]
        })"
      ) [ ] 1050;
      inspr-legacy-pharos-prefixed-machine = publicProxy "pharos" (
        "${host "pharos.barta.cm"} && (${
          pathFamilies [
            "/pharos/healthz"
            "/pharos/readyz"
            "/pharos/metrics"
            "/pharos/version"
            "/pharos/favicon.svg"
            "/pharos/assets"
            "/pharos/register"
            "/pharos/report"
            "/pharos/agent"
          ]
        })"
      ) [ ] 1050;
      inspr-legacy-janus-prefixed-machine = publicProxy "janus" (
        "${host "vault.barta.cm"} && (${
          pathFamilies [
            "/janus/healthz"
            "/janus/readyz"
            "/janus/buildz"
            "/janus/favicon.ico"
            "/janus/static"
          ]
        })"
      ) [ ] 1050;

      # Only browser navigations move origins. API and machine rules above are
      # higher priority; non-browser and mutation traffic falls through to the
      # proxy catchalls below with headers and payload untouched.
      inspr-legacy-paimos-browser = redirect (
        "${host "pm.barta.cm"} && ${getOrHead} && ${htmlNavigation}"
      ) "inspr-legacy-paimos-browser" 900;
      inspr-legacy-pharos-browser = redirect (
        "${host "pharos.barta.cm"} && ${getOrHead} && ${htmlNavigation}"
      ) "inspr-legacy-pharos-browser" 900;
      inspr-legacy-janus-browser = redirect (
        "${host "vault.barta.cm"} && ${getOrHead} && ${htmlNavigation}"
      ) "inspr-legacy-janus-browser" 900;

      inspr-legacy-paimos-proxy = publicProxy "paimos" (host "pm.barta.cm") [
        "inspr-legacy-paimos-prefix"
      ] 100;
      inspr-legacy-pharos-proxy = publicProxy "pharos" (host "pharos.barta.cm") [
        "inspr-legacy-pharos-prefix"
      ] 100;
      inspr-legacy-janus-proxy = publicProxy "janus" (host "vault.barta.cm") [
        "inspr-legacy-janus-prefix"
      ] 100;
    };

    middlewares = {
      inspr-legacy-paimos-prefix.addPrefix.prefix = "/paimos";
      inspr-legacy-pharos-prefix.addPrefix.prefix = "/pharos";
      inspr-legacy-janus-prefix.addPrefix.prefix = "/janus";

      inspr-legacy-paimos-browser.redirectRegex = {
        regex = "^https?://pm\\.barta\\.cm(?:/paimos)?(/.*|\\?.*|$)$";
        replacement = "https://flow.inspr.at/paimos\${1}";
        permanent = false;
      };
      inspr-legacy-pharos-browser.redirectRegex = {
        regex = "^https?://pharos\\.barta\\.cm(?:/pharos)?(/.*|\\?.*|$)$";
        replacement = "https://flow.inspr.at/pharos\${1}";
        permanent = false;
      };
      inspr-legacy-janus-browser.redirectRegex = {
        regex = "^https?://vault\\.barta\\.cm(?:/janus)?(/.*|\\?.*|$)$";
        replacement = "https://flow.inspr.at/janus\${1}";
        permanent = false;
      };
      inspr-legacy-paimos-restart-login.redirectRegex = {
        regex = "^https?://pm\\.barta\\.cm/(paimos(/|%2[fF]))?api(/|%2[fF])auth(/|%2[fF])oidc(/|%2[fF])callback(\\?.*)?$";
        replacement = "https://flow.inspr.at/paimos/api/auth/oidc/login";
        permanent = false;
      };
      inspr-legacy-pharos-restart-login.redirectRegex = {
        regex = "^https?://pharos\\.barta\\.cm/(pharos(/|%2[fF]))?auth(/|%2[fF])callback(\\?.*)?$";
        replacement = "https://flow.inspr.at/pharos/auth/login";
        permanent = false;
      };
      inspr-legacy-janus-restart-login.redirectRegex = {
        regex = "^https?://vault\\.barta\\.cm/(janus(/|%2[fF]))?oidc(/|%2[fF])callback(\\?.*)?$";
        replacement = "https://flow.inspr.at/janus/login";
        permanent = false;
      };
      inspr-legacy-flow-deny.ipAllowList.sourceRange = [ "255.255.255.255/32" ];
    };

    services.inspr-legacy-flow-deny.loadBalancer = {
      passHostHeader = false;
      servers = [ { url = "http://127.0.0.1:1"; } ];
    };
  };
}
