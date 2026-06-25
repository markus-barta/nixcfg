# Janus Non-Prod Engine Smoke

Host-local smoke for the disabled `janus-engine-staged` profile.

This path uses only non-prod generated material. It creates a local age identity
and encrypted `JANUS_SMOKE` value under `${XDG_STATE_HOME:-$HOME/.local/state}`
by default, asks `janus-warden` for a `UsePermit`, then consumes that permit with
`janusd run`. The expected command output is redacted as `smoke:[REDACTED]`.

Run on csb1 from `hosts/csb1/docker`:

```bash
./janus/nonprod-smoke/run.sh
```

The script reads the signed, digest-pinned engine image from
`docker-compose.yml`; it does not use production secrets or the host SSH key.
