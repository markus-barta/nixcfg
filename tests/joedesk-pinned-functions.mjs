// Exact function bytes from db621bf (host) and dafe7909 (identity).
// Compare actual pinned source before evaluating these repository constants.
export const legacyHostSource = String.raw`(function isCanonicalJoeHost(hostname) {
    var host = String(hostname || "").toLowerCase();
    if (host.charAt(0) === "[" && host.charAt(host.length - 1) === "]") {
      host = host.slice(1, -1);
    }
    if (
      host === "cs0.barta.cm" || host === "cs0" ||
      host === "hsb1.lan" || host === "hsb1" ||
      host === "localhost" || host === "127.0.0.1" || host === "::1"
    ) {
      return true;
    }
    var parts = host.split(".");
    if (parts.length === 4) {
      var octets = [];
      var i;
      var valid = true;
      for (i = 0; i < 4; i += 1) {
        if (!/^(0|[1-9]\d{0,2})$/.test(parts[i])) {
          valid = false;
          break;
        }
        var n = Number(parts[i]);
        if (n > 255) {
          valid = false;
          break;
        }
        octets.push(n);
      }
      if (valid && octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127) {
        return true;
      }
    }
    return host.slice(-7) === ".ts.net" && host.indexOf("hsb1") !== -1;
  })`;
export const fleetActorSource = String.raw`const FLEET_ACTOR = /^[A-Za-z0-9][A-Za-z0-9@._+-]{0,159}$/;; (function fleetActor(req) {
  const actor = String(req.headers["x-auth-request-user"] || "").trim();
  return FLEET_ACTOR.test(actor) ? actor : "";
})`;
