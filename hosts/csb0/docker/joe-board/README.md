# joe-board (csb0)

Small Node service: static Joe household UI + latest snapshot + history + token inbox.

- `GET /joe/`, `/joe/data.json`, `/joe/history.json`, `/joe/data.schema.json` — behind Traefik **hostdash-auth**
- `POST /joe/inbox` — Bearer token only (no OAuth); schema-validated; atomic store + history append
- Paper projection only — no IB credentials on this host

History schema: `inspr.joe.household.history.v1` (cap ~4000 points). Seed/import may prepend
documented day-0 (first SXR8 paper fill 2026-09-01, virt stand €15k / totalPnl 0) plus legacy
hsb1 points so the chart shows the path from week 0 instead of a fresh underwater baseline.

See `SECURITY.md`. Token: agenix `secrets/joe-board-push-token.age`.
