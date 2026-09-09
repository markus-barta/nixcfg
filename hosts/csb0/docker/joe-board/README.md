# joe-board (csb0)

Small Node service: static Joe household UI + latest snapshot + history + token inbox.

- `GET /joe/`, `/joe/data.json`, `/joe/history.json`, `/joe/data.schema.json` — behind Traefik **hostdash-auth**
- `POST /joe/inbox` — Bearer token only (no OAuth); schema-validated; atomic store of `data.json` and append to `history.json` (`inspr.joe.household.history.v1`, capped ~10k points / 14 days)
- Paper projection only — no IB credentials on this host

Chart.js is loaded from jsDelivr CDN by the UI (no local vendor copy required).

See `SECURITY.md`. Token: agenix `secrets/joe-board-push-token.age`.
