# csb1 — classic PPM switches for the Aeon cutover (OPS-233, AEON-43).
#
# Value-free. Both switches stay false until their own window; with both
# false ppm-cutover-routing.nix contributes nothing and csb1's rendered
# routing is byte-identical to the pre-cutover spec.
{
  # Write freeze (runbook step 1): refuse every method except GET, HEAD and
  # OPTIONS on classic's two public origins, pm.barta.cm and
  # flow.inspr.at/paimos. Flip only inside the announced freeze window.
  # Limit: direct in-network calls to ppm:8888 bypass Traefik and are not
  # covered; the delivery stage is already fail-closed (paimos-delivery-stage.nix).
  freeze = true;

  # Read-only classic fallback at legacyHost (GET/HEAD only, straight to the
  # classic container so it survives flow.inspr.at/paimos moving to Aeon).
  # Browser SSO there also needs classic's OIDC_REDIRECT_URL and public URL
  # moved to legacyHost, plus the redirect URI on the Zitadel client; both
  # belong to the switch change, not to this flag.
  legacy = true;
  legacyHost = "pml.barta.cm";

  # Classic's canonical public URL and OIDC callback move to legacyHost (base
  # path /paimos kept, matching the legacy routers). Set together with the
  # freeze: from then on classic is read-only and reached for reading only
  # via pml, and SSO there needs this redirect URI registered on the
  # paimos-ppm Zitadel client (391618992831266821@paimos_ppm).
  classicOnLegacy = true;
}
