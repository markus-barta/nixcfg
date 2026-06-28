# Janus Non-Prod Engine Smoke

Host-local smoke for the disabled `janus-engine-staged` profile.

This path uses only non-prod generated material. It creates a Docker-volume age
identity and encrypted `JANUS_SMOKE` value, mounts the non-prod metadata overlay,
asks `janus-warden` for a `UsePermit`, then consumes that permit with
`janusd run`. The Warden and runner containers are launched through the disabled
`janus-engine-staged` compose profile and use the engine image's default
non-root `janus` user. The expected command output is redacted as
`smoke:[REDACTED]`.

Run on csb1 from `hosts/csb1/docker`:

```bash
./janus/nonprod-smoke/run.sh
```

Or from the repository root:

```bash
just janus-engine-smoke
```

To keep the staged Rust engine running as an internal, networkless MCP stdio
process after the smoke has primed the non-prod volumes:

```bash
just janus-engine-up
just janus-engine-status
```

The running container has no public ports, no Traefik route, and
`network_mode: none`. Its Docker healthcheck launches a fresh value-free Warden
health probe against the same mounted non-prod config. Stop it with:

```bash
just janus-engine-down
```

The script reads the signed, digest-pinned engine image from
`docker-compose.yml`; the current staged promotion target is
`rust-engine-v0.1.1@sha256:0117ac452992d510e8ad0cdd3b895f77492a77f7b0e860e155f54a680867125c`.
It does not use production secrets or the host SSH key.
By default it uses Docker volumes named `janus_engine_smoke_age`,
`janus_engine_smoke_secrets`, and `janus_engine_smoke_permits`; set
`JANUS_SMOKE_VOLUME_PREFIX` to isolate another smoke state.

## Safety Boundaries

The smoke harness must never run project-wide Docker Compose lifecycle commands
against the live `csb1` project. Do not use `docker compose down`, `rm`,
`restart`, broad `up`, or `--remove-orphans` from this workflow.

The script runs Compose with an isolated project name,
`janus_engine_smoke` by default. Override with `JANUS_SMOKE_COMPOSE_PROJECT`
only for another isolated smoke project; the script refuses `csb1`.

The only Compose operations in the harness are:

- `config --quiet --no-env-resolution`
- `run --rm --no-deps` for `janus-engine-staged`

After any compose-adjacent smoke on csb1, verify the routing path as well as the
Janus result: all expected csb1 services are running, `docker-proxy-traefik`
and Traefik are both up, `https://jhw22.hausv.org/healthz` is OK, WEG login and
OIDC redirect work, and public services such as Docmost and Paperless return
their expected statuses.
