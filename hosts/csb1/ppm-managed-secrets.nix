let
  serviceRef = "svc_616c1af8cc7f4556975b";
  mkSlot =
    {
      name,
      safeLabel,
      slotRef,
      secretRef,
      deliveryProfileRef,
      reloadProfileRef,
      healthProfileRef,
      detachProfileRef,
      containerPath,
      fileVariable,
    }:
    {
      inherit
        name
        safeLabel
        slotRef
        secretRef
        deliveryProfileRef
        reloadProfileRef
        healthProfileRef
        detachProfileRef
        containerPath
        fileVariable
        ;
      hostPath = "/run/janus-managed/${serviceRef}/${slotRef}.env";
      profileId = "profile.${name}";
    };

  # NIX-350 is a two-stage, one-PR cutover. Keep this false while the reviewed
  # declarations are first published and all three imported generations are
  # installed and verified. The final reviewed commit flips it to true and
  # removes the aggregate env-file boundary from PPM.
  cutover = false;
  slots = [
    (mkSlot {
      name = "PPM_PAIMOS_SECRET_KEY";
      safeLabel = "PPM encryption key";
      slotRef = "slot_6e7523d1b57919248919";
      secretRef = "sec_6995435765a2475d4cdb";
      deliveryProfileRef = "delivery_ee3ee55a5691";
      reloadProfileRef = "reload_97c795963d1b";
      healthProfileRef = "health_79a4d461b66d";
      detachProfileRef = "detach_e1eed9bed55a";
      containerPath = "/run/secrets/paimos-secret-key";
      fileVariable = "PAIMOS_SECRET_KEY_FILE";
    })
    (mkSlot {
      name = "PPM_SMTP_PASS";
      safeLabel = "PPM SMTP password";
      slotRef = "slot_4f7e86b99497776adf95";
      secretRef = "sec_c188cd3d1f54f4aadb31";
      deliveryProfileRef = "delivery_8089afb7e6e7";
      reloadProfileRef = "reload_9abf75ea254d";
      healthProfileRef = "health_b597b0dc3340";
      detachProfileRef = "detach_d5c3f3d7461a";
      containerPath = "/run/secrets/smtp-pass";
      fileVariable = "SMTP_PASS_FILE";
    })
    (mkSlot {
      name = "PPM_OIDC_CLIENT_SECRET";
      safeLabel = "PPM OIDC client secret";
      slotRef = "slot_25e403cccaaf015f30cb";
      secretRef = "sec_43f90333e9c09d204d13";
      deliveryProfileRef = "delivery_572ad50f794e";
      reloadProfileRef = "reload_869d0c7c8106";
      healthProfileRef = "health_c9ac45927f59";
      detachProfileRef = "detach_aa95b35a8b11";
      containerPath = "/run/secrets/oidc-client-secret";
      fileVariable = "OIDC_CLIENT_SECRET_FILE";
    })
  ];
  mkComposeBindings = active: {
    environment =
      if active then map (slot: "${slot.fileVariable}=${slot.containerPath}") slots else [ ];
    envFile = if active then [ ] else [ "/run/agenix/csb1-ppm-env" ];
    volumes = if active then map (slot: { inherit (slot) hostPath containerPath; }) slots else [ ];
  };
in
{
  inherit
    cutover
    serviceRef
    slots
    mkComposeBindings
    ;
  consumerRef = "consumer.ppm";
  composeBindings = mkComposeBindings cutover;
}
