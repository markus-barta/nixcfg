# csb1 — Pharos Flow host wiring (NIX-442 / PHAROS-257).
#
# 🔴 VALUE-FREE BY CONSTRUCTION. This file is the single reviewed source of
# truth for whether pharosd receives PHAROS_FLOW_CONFIG_FILE. It carries
# paths and symbolic references and one readiness switch. It MUST NEVER
# carry an API-key value — that lives only in a future agenix ciphertext and,
# at runtime, in a container-uid-only file that this file merely names.
#
# Imported by BOTH hosts/csb1/configuration.nix (module wiring) and
# hosts/csb1/docker/compose-spec.nix (pharosd env + bind mounts) so the two
# sides can never disagree about whether Flow is live. tests/T71 asserts
# that agreement.
#
# ── Why `active` is a manual switch, and the only one ──────────────────────
# pharosd PANICS at startup when PHAROS_FLOW_CONFIG_FILE is set but the
# config or the referenced API key is missing, malformed, or not owned by
# the container uid with no group/other permission bits
# (crates/pharosd/src/main.rs -> panic!("flow host startup failed")). A
# half-provisioned activation therefore does not degrade — it crash-loops
# the live fleet dashboard.
#
# Live project/host/operator facts cannot be invented here. The fail-closed
# design is: everything declarative lands first with `active = false`
# (inert, pharosd untouched, no Flow env or mounts), and flipping this one
# boolean — after the operator preflight in hosts/csb1/docs/RUNBOOK.md
# confirms the API-key file exists with the right owner, mode and parent
# directory — is the reviewed activation. Source/module completion is not
# proof of an authenticated four-app stream.
{
  # 🔴 THE READINESS SWITCH. Flip only after the RUNBOOK preflight passes on
  # csb1, with a reviewed nonempty binding. Flipping it with `bindings = [ ]`
  # fails the build, not the host.
  active = false;

  # Same canonical production Paimos origin as NIX-381. https, no userinfo,
  # query, fragment or path — pharosd `parse_origin` requires path empty or "/".
  paimosOrigin = "https://pm.barta.cm";

  # Pharos Flow host_id (valid_host_id): first alphabetic, then [A-Za-z0-9._-].
  hostId = "pharos-csb1";

  # Optional UI label. When null, pharosd uses host_id.
  instanceLabel = "Pharos csb1";

  # Host path published by the pharos-flow-host-config unit and bound into
  # pharosd as the directory parent (0700, uid 10001). Never a store path:
  # pharosd requires mode & 0o077 == 0, uid == its own euid, nlink == 1, and
  # a matching parent directory.
  configFile = "/run/pharos/flow-host/config.json";

  # In-container credential path. Distinct inode from the PHAROS-206
  # delivery API key; pharosd and this module both refuse implicit reuse.
  apiKeyFile = "/run/pharos/flow-host/api-key";

  # Host-side future agenix output backing the mount above. Named only —
  # this change does not create, declare or enrol the ciphertext.
  hostApiKeyFile = "/run/agenix/csb1-pharos-flow-api-key";
}
