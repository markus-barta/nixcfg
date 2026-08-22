# csb1 — Paimos v1 external-stage adapter wiring (NIX-381 / PAI-810).
#
# 🔴 VALUE-FREE BY CONSTRUCTION. This file is the single reviewed source of
# truth for the Pharos owner adapter and the Janus dependency reporter. It
# carries paths, symbolic references and one readiness switch. It MUST NEVER
# carry an API key, a raw 32-byte handoff secret, or any other credential
# value — those live only in agenix ciphertext and, at runtime, in root-only
# or container-uid-only files that this file merely names.
#
# Imported by BOTH hosts/csb1/configuration.nix (module wiring) and
# hosts/csb1/docker/compose-spec.nix (pharosd env + bind mounts) so the two
# sides can never disagree about whether the adapter is live. tests/T48
# asserts that agreement.
#
# ── Why `active` is a manual switch, and the only one ──────────────────────
# pharosd v0.1.83 PANICS at startup when PHAROS_PAIMOS_DELIVERY_CONFIG_FILE
# is set but the config, the API key or any referenced 32-byte handoff secret
# is missing, malformed, or not owned by the container uid with no group/other
# permission bits (crates/pharosd/src/main.rs -> `unwrap_or_else(|error|
# panic!(...))`). A half-provisioned activation therefore does not degrade —
# it crash-loops the live fleet dashboard.
#
# The adapter also needs real Paimos-minted identifiers that cannot be
# invented here: each `handoffId` is a 26-character Crockford base32 ULID
# issued by Paimos when the handoff is created. So the fail-closed design is:
# everything declarative lands first with `active = false` (inert, pharosd
# untouched, reporter unit skipped by ConditionPathExists), and flipping this
# one boolean — after the operator preflight in hosts/csb1/docs/RUNBOOK.md
# confirms every credential file exists with the right owner, mode and size —
# is the reviewed activation.
{
  # 🔴 THE READINESS SWITCH. Flip only after the RUNBOOK preflight passes on
  # csb1. Flipping it with `intents = [ ]` fails the build, not the host.
  active = false;

  # Real production Paimos origin. https, no userinfo, query, fragment or
  # path — both adapters reject anything else before the first request.
  paimosOrigin = "https://paimos.barta.cm";

  # ── Pharos owner adapter (PHAROS-206) ────────────────────────────────────
  pharos = {
    # Host path published by the pharos-paimos-delivery-config unit and bound
    # into pharosd at the identical path. Never a store path: pharosd requires
    # mode & 0o077 == 0, uid == its own euid, and nlink == 1, which a
    # world-readable (and possibly store-optimised, hardlinked) /nix/store
    # file can never satisfy.
    configFile = "/run/pharos/paimos-delivery/config.json";

    # In-container credential paths. Each is a separate inode bound read-only
    # from its own agenix secret; pharosd refuses a shared API-key/handoff
    # file by comparing (device, inode).
    apiKeyFile = "/run/pharos/paimos/owner-api-key";
    deploymentHandoffSecretFile = "/run/pharos/paimos/deployment-handoff-secret";
    verificationHandoffSecretFile = "/run/pharos/paimos/verification-handoff-secret";

    # Host-side agenix outputs backing the three mounts above. Declared as
    # 0400 owned by uid 10001 (users.users.pharos-container) so the in-container
    # euid is the owner. See RUNBOOK "Paimos external-stage activation".
    hostApiKeyFile = "/run/agenix/csb1-paimos-pharos-owner-api-key";
    hostDeploymentHandoffSecretFile = "/run/agenix/csb1-paimos-pharos-deployment-handoff-secret";
    hostVerificationHandoffSecretFile = "/run/agenix/csb1-paimos-pharos-verification-handoff-secret";
  };

  # ── Janus dependency reporter (JANUS-441) ────────────────────────────────
  janus = {
    # 🔴 FIXED by the binary — janus-host/src/paimos.rs SYSTEM_CONFIG_PATH.
    # The reporter takes no arguments and reads nothing else.
    configFile = "/run/janus-paimos-dependency-reporter/config.json";

    # Durable, deliberately NOT under /run: the exact-replay journal must
    # survive reboot, and PAI-810 acceptance criterion 7 retains journals
    # until evidence is accepted. Mode is checked as exactly 0700 root.
    journalDirectory = "/var/lib/janus-paimos-dependency-reporter/journal";

    # Root-only, distinct inodes, 0400.
    apiKeyFile = "/run/agenix/csb1-paimos-janus-dependency-api-key";
    handoffSecretFile = "/run/agenix/csb1-paimos-janus-dependency-handoff-secret";
  };
}
