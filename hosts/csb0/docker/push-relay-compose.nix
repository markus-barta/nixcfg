# Public, digest-pinned spec for the independent OPS-528 relay project.
{
  apnsKeyPath,
  apnsKeyId,
  appAttestAppIdPrefix,
}:
{
  name = "paimos-push-relay";
  services.relay = {
    image = "ghcr.io/inspr-at/paimos-push-relay:261110064212.0.0@sha256:7aa37725c00310b512fc83d8197ea356cf750a624d78c840d9fea0b516d26a9a";
    platform = "linux/amd64";
    user = "65532:65532";
    read_only = true;
    cap_drop = [ "ALL" ];
    security_opt = [ "no-new-privileges:true" ];
    tmpfs = [ "/tmp:rw,noexec,nosuid,size=16m" ];
    environment = {
      PUBLIC_URL = "https://push.inspr.at";
      LISTEN_ADDR = ":8080";
      DATA_PATH = "/data";
      APNS_KEY_FILE = "/run/keys/apns.p8";
      APNS_KEY_ID = apnsKeyId;
      APNS_TEAM_ID = "P66J39QV6V";
      APNS_BUNDLE_IDS = "at.inspr.paimos";
      APP_ATTEST_APP_ID_PREFIX = appAttestAppIdPrefix;
      APP_ATTEST_ENVIRONMENT = "production";
    };
    volumes = [
      "relay-data:/data"
      "${apnsKeyPath}:/run/keys/apns.p8:ro"
    ];
    expose = [ "8080" ];
    networks.relay-ingress.aliases = [ "paimos-push-relay" ];
    restart = "unless-stopped";
    stop_grace_period = "20s";
    mem_limit = "256m";
    cpus = 1.0;
    pids_limit = 64;
    labels."traefik.enable" = "false";
  };
  networks.relay-ingress.external = true;
  volumes.relay-data.name = "paimos-push-relay-data";
}
