# joe-board (csb0)

Small Node service: static Joe household UI + latest snapshot + token inbox.

- `GET /joe/`, `/joe/data.json`, `/joe/data.schema.json` — behind Traefik **hostdash-auth**
- `POST /joe/inbox` — Bearer token only (no OAuth); schema-validated; atomic store
- Paper projection only — no IB credentials on this host

See `SECURITY.md`. Token: agenix `secrets/joe-board-push-token.age`.
