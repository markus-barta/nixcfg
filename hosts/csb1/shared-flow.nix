# NIX-501: one value-free activation boundary for csb1's shared Flow origin.
#
# `active` remains the sole deployment boundary for network, route, application
# public-path, credential-load, and private name-resolution effects. The nested
# value-free Paimos selector may be prepared only with its protected inputs.
let
  active = true;
  publicHost = "flow.inspr.at";
  publicOrigin = "https://${publicHost}";
  basePaths = {
    aithema = "/aithema";
    paimos = "/paimos";
    pharos = "/pharos";
    janus = "/janus";
  };
  browserUrls = builtins.mapAttrs (_: path: "${publicOrigin}${path}") basePaths;
  network = {
    composeKey = "shared-flow";
    dockerName = "csb1_shared-flow";
    bridgeInterface = "flow0";
    subnet = "10.253.253.0/28";
    gateway = "10.253.253.1";
    addresses = {
      host = "10.253.253.1";
      traefik = "10.253.253.2";
      janus = "10.253.253.3";
      paimos = "10.253.253.4";
      pharos = "10.253.253.5";
    };
  };
  ports = {
    aithema = 8787;
    paimos = 8888;
    pharos = 8080;
    janus = 8080;
  };
  contract = {
    contract_version = "inspr.routing/0.1-draft";
    evaluated_at = "2026-09-14T20:22:32Z";
    authority_disclaimer = "Schema validity is not live proxy proof, SSO proof, or runtime authentication. Each app remains its own authority and OIDC client verifier.";
    public_origin = {
      scheme = "https";
      host = publicHost;
    };
    landing = {
      kind = "connected_default_app";
      app = "aithema";
    };
    apps = {
      aithema = {
        enabled = true;
        public_base_path = basePaths.aithema;
        oidc = {
          client_ref = "aithema:zitadel:flow";
          redirect_path = "/oidc/callback";
          post_logout_path = "/logout";
        };
      };
      paimos = {
        enabled = true;
        public_base_path = basePaths.paimos;
        oidc = {
          client_ref = "paimos:zitadel:flow";
          redirect_path = "/api/auth/oidc/callback";
        };
      };
      pharos = {
        enabled = true;
        public_base_path = basePaths.pharos;
        oidc = {
          client_ref = "pharos:zitadel:flow";
          redirect_path = "/auth/callback";
        };
      };
      janus = {
        enabled = true;
        public_base_path = basePaths.janus;
        oidc = {
          client_ref = "janus:zitadel:flow";
          redirect_path = "/oidc/callback";
        };
      };
    };
    edge = {
      mode = "prefix_preserving_proxy";
      trust = {
        html_response_rewrite = false;
        iframe_gateway = false;
        permissive_cors = false;
        forwarded_identity_trust = false;
        shared_session_fallback = false;
      };
      optional_diagnostic_headers = [ "X-Forwarded-Prefix" ];
    };
  };
in
{
  inherit
    active
    basePaths
    browserUrls
    contract
    network
    ports
    publicHost
    publicOrigin
    ;

  aithema = {
    configFile = "/run/aithema-workspace-config.json";
    dataDirectory = "/var/lib/aithema-workspace";
    # NIX-504 / INSPR-439: non-secret speech settings for the coordinated
    # AIT-21 CLI. Host activation remains pending until the reviewed deployment
    # and separate browser/microphone acceptance are complete.
    speech = {
      kind = "openai-compatible-transcription";
      providerId = "openrouter";
      model = "openai/whisper-large-v3";
      allowedModels = [ "openai/whisper-large-v3" ];
      endpoint = "https://openrouter.ai/api/v1/audio/transcriptions";
      acceptedMediaTypes = [
        "audio/webm"
        "audio/mp4"
      ];
      limits = {
        maxAudioBytes = 524288;
        maxRequestBytes = 589824;
        maxRecordingMs = 10000;
        maxDurationMs = 30000;
        maxResponseBytes = 65536;
        maxTranscriptChars = 8000;
      };
    };
    paimosHarness = {
      # False preserves existing direct-API-only operation without requiring a
      # second credential. Enable only with the protected key and matching
      # paimos-harness provider entries ready for the same activation.
      enable = false;
      credentialSource = "/run/agenix/csb1-aithema-paimos-conversation-key";
      credentialName = "paimos-conversation-api-key";
      credentialFile = "/run/credentials/aithema-workspace.service/paimos-conversation-api-key";
    };
  };

  # Server-to-server callers retain origin-only HTTPS URLs. Resolution is
  # changed at the caller boundary instead of putting an app prefix into a
  # machine URL; Host and TLS SNI therefore stay on the established names.
  machineOrigins = {
    pharos = "https://pharos.barta.cm";
    janus = "https://vault.barta.cm";
  };

  privateSourceRanges = {
    # Only the Janus container calls Pharos private paths. The native host
    # agent uses Pharos's /agent/managed-services/* API instead.
    pharos = [ "${network.addresses.janus}/32" ];
    # The native host agent calls Janus /internal/* from the bridge gateway.
    janus = [ "${network.addresses.host}/32" ];
  };

  routingEdgeActivation = {
    contractFile = builtins.toFile "csb1-shared-flow-routing.json" (builtins.toJSON contract);
    upstreams = {
      aithema.url = "http://${network.addresses.host}:${toString ports.aithema}";
      paimos.url = "http://${network.addresses.paimos}:${toString ports.paimos}";
      pharos.url = "http://${network.addresses.pharos}:${toString ports.pharos}";
      janus.url = "http://${network.addresses.janus}:${toString ports.janus}";
    };
    external.existingTraefikVersion = "3.7.13";
  };
}
