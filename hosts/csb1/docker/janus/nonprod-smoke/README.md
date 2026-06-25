# Janus Non-Prod Engine Smoke

Host-local smoke for the disabled `janus-engine-staged` profile.

This path uses only non-prod generated material. It creates a Docker-volume age
identity and encrypted `JANUS_SMOKE` value, asks `janus-warden` for a
`UsePermit`, then consumes that permit with `janusd run`. The Warden and runner
containers use the engine image's default non-root `janus` user. The expected
command output is redacted as `smoke:[REDACTED]`.

Run on csb1 from `hosts/csb1/docker`:

```bash
./janus/nonprod-smoke/run.sh
```

Or from the repository root:

```bash
just janus-engine-smoke
```

The script reads the signed, digest-pinned engine image from
`docker-compose.yml`; it does not use production secrets or the host SSH key.
By default it uses Docker volumes named `janus_engine_smoke_age`,
`janus_engine_smoke_secrets`, and `janus_engine_smoke_permits`; set
`JANUS_SMOKE_VOLUME_PREFIX` to isolate another smoke state.
