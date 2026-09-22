# csb1 Janus Flow host wiring (NIX-481 / JANUS-458).
#
# This is the shared, value-free source for module and Compose wiring. It does
# not create or contain the API key. Activation requires a separately reviewed
# real Paimos project and exact authenticated Janus session subjects.
let
  credentialFile = ../../secrets + "/csb1-janus-flow-api-key.age";
in
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
  hostApiKeyFile = "/run/janus-flow-credential/api-key";
  # Only ciphertext is fingerprinted. Both consumers reject activation while
  # this is null; the real artifact and active=true receive one exact review.
  credentialRevision =
    if builtins.pathExists credentialFile then builtins.hashFile "sha256" credentialFile else null;

  # NIX-574: exact human test subject and dedicated throwaway project only.
  bindings = [
    {
      projectId = 33;
      projectRef = null;
      label = "UXQA sandbox";
      principalRefs = [ "391779593318563851" ];
    }
  ];
}
