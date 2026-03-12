# csb1-docker-compose-into-repo

**Host**: csb1
**Priority**: A10
**Status**: Backlog
**Created**: 2026-03-06

---

## Problem

csb1 docker-compose liegt auf dem Server unter `~/docker/` — nicht git-managed.
Secrets als plain `~/secrets/*.env` files, kein agenix.
Restic SSH-Key liegt unverschlüsselt im Docker-Ordner.

csb0 ist das Vorbild: compose im Repo, Secrets via agenix, Arbeitsverzeichnis `~/Code/nixcfg/hosts/csb0/docker/`.

## Solution

`hosts/csb1/docker/` analog zu csb0 aufbauen. Secrets nach agenix migrieren.
Compose-File und statische Configs ins Repo. Dann `~/docker/` auf csb1 ablösen.

## Was migriert werden muss

### Statische Files (direkt ins Repo)

| Quelle auf csb1                           | Ziel im Repo                             |
| ----------------------------------------- | ---------------------------------------- |
| `~/docker/docker-compose.yml`             | `hosts/csb1/docker/docker-compose.yml`   |
| `~/docker/traefik/static.yml`             | `hosts/csb1/docker/traefik/static.yml`   |
| `~/docker/traefik/dynamic.yml`            | `hosts/csb1/docker/traefik/dynamic.yml`  |
| `~/docker/traefik/acme.json`              | gitignore (generiert, nicht committen)   |
| `~/docker/restic-cron/Dockerfile`         | `hosts/csb1/docker/restic-cron/`         |
| `~/docker/restic-cron/hetzner/` (Scripts) | `hosts/csb1/docker/restic-cron/hetzner/` |
| `~/docker/restic-cron/ssh_known_hosts`    | `hosts/csb1/docker/restic-cron/`         |

### Secrets → agenix (neue Keys in `secrets.nix`)

| Aktuell                                      | Neuer agenix-Key                            |
| -------------------------------------------- | ------------------------------------------- |
| `~/docker/traefik/variables.env`             | `csb1-traefik-variables` (shared mit csb0?) |
| `~/docker/restic-cron/id_rsa`                | `restic-hetzner-ssh-key` (shared mit csb0)  |
| `~/docker/restic-cron/variables.hetzner.env` | `restic-hetzner-env` (shared mit csb0)      |
| `~/docker/smtp/variables.env`                | `csb1-smtp-variables`                       |
| `~/docker/watchtower.env`                    | `csb1-watchtower-env`                       |
| `~/secrets/docmost.config.env`               | `csb1-docmost-config`                       |
| `~/secrets/docmost.postgres.env`             | `csb1-docmost-postgres`                     |
| `~/secrets/influxdb3.env`                    | `csb1-influxdb3`                            |
| `~/secrets/nixfleet.env`                     | `csb1-nixfleet`                             |
| `~/secrets/paperless.config.env`             | `csb1-paperless-config`                     |
| `~/secrets/paperless.postgres.env`           | `csb1-paperless-postgres`                   |

Prüfen: `traefik/variables.env` und `restic-cron` Keys sind evtl. bereits als shared secret in agenix vorhanden (csb0 nutzt sie) — dann nur Berechtigungen in `secrets.nix` für csb1 ergänzen.

### Compose-File anpassen

- `env_file: ~/secrets/...` → `env_file: /run/agenix/...`
- `./restic-cron/id_rsa` → `/run/agenix/restic-hetzner-ssh-key`
- Pfade für `./traefik/`, `./smtp/` bleiben relativ (funktionieren aus Repo-Pfad)

### csb1 NixOS-Config

- Arbeitsverzeichnis für docker compose: `~/Code/nixcfg/hosts/csb1/docker/`
- Symlink oder `just`-Rezept analog csb0 anlegen

## Implementation

- [ ] Prüfen welche agenix-Keys bereits für csb0 existieren und für csb1 wiederverwendbar sind
- [ ] Statische Files ins Repo kopieren (`traefik/`, `restic-cron/`, compose)
- [ ] `.gitignore` für `traefik/acme.json` anlegen
- [ ] Neue agenix-Keys anlegen und verschlüsseln (`agenix -e`)
- [ ] `docker-compose.yml` anpassen (env-Pfade auf `/run/agenix/...`)
- [ ] NixOS-Config: agenix-Secrets für csb1 freischalten (`secrets.nix`)
- [ ] `just`-Rezepte für csb1 prüfen/anlegen
- [ ] Deploy: auf csb1 `~/Code/nixcfg` als Arbeitsverzeichnis nutzen
- [ ] `~/docker/` auf csb1 archivieren/entfernen (nach Verifikation)
- [ ] RUNBOOK.md: docker-Pfad aktualisieren

## Acceptance Criteria

- [ ] `docker compose up -d` läuft aus `~/Code/nixcfg/hosts/csb1/docker/`
- [ ] Alle Services laufen stabil (Grafana, InfluxDB, Paperless, Docmost, NixFleet)
- [ ] Keine plain-text Secrets mehr in `~/docker/` oder `~/secrets/` auf csb1
- [ ] `restic-cron/id_rsa` nicht mehr im Dateisystem unverschlüsselt

## Notes

- `traefik/acme.json` muss auf csb1 bleiben (wird von Traefik beschrieben) — bind-mount von lokalem Pfad außerhalb Repo, oder in `/var/lib/traefik/` verschieben
- csb1 hat bereits `nixfleet` Container — dessen `~/docker/nixfleet/` Repo-Clone prüfen ob relevant
- `~/docker/!archiv/` enthält alte Compose-Snapshots — kann nach Migration gelöscht werden
