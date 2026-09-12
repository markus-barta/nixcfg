# csb1 Janus Flow host wiring (NIX-481 / JANUS-458).
#
# This is the shared, value-free source for module and Compose wiring. It does
# not create or contain the API key. Activation requires a separately reviewed
# real Paimos project and exact authenticated Janus session subjects.
{
  # Keep false until the runbook preflight proves every prerequisite. While
  # false, Compose receives no JANUS_FLOW_CONFIG_FILE and no related mounts.
  active = false;

  paimosOrigin = "https://pm.barta.cm";
  # Chosen only with the common-origin deployment. Null makes Janus use the
  # server origin for browser navigation without inventing a route here.
  paimosBrowserUrl = null;
  hostId = "janus-csb1";
  instanceLabel = "Janus csb1";

  # Config and API key share the private uid-100 parent Janus validates. The
  # API key is mounted as a separate inode over the directory bind.
  configFile = "/run/janus/flow-host/config.json";
  apiKeyFile = "/run/janus/flow-host/api-key";
  hostApiKeyFile = "/run/agenix/csb1-janus-flow-api-key";

  # No live binding is inferred. Later activation must use a real project id,
  # optional exact project ref, and exact non-email Janus session subjects.
  bindings = [ ];
}
