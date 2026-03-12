# merlin-agent-permissions-matrix

**Host**: alle (hsb0, hsb1, csb0, csb1, gpc0)
**Priority**: P40
**Status**: Backlog
**Created**: 2026-03-06

---

## Problem

Merlin soll als zentraler Assistent für die gesamte Infrastruktur ausgebaut werden —
Observer-only bis hin zu gezielten Aktionen (HA steuern, Container neustarten etc.).

Aktuell ist der Zugriff ungeplant gewachsen:

- hsb1: `merlin` user mit `wheel + docker` — faktisch root, uneingeschränkt
- alle anderen Hosts: kein Zugriff

Es fehlt ein klares, nachvollziehbares Konzept: **wer darf was, in welchem Container, auf welchem Host.**

## Konzept

Flache Liste. Jeder Eintrag = ein konkreter Zugangspunkt:

```
host | service/container | erlaubte Aktionen | Notiz
```

Zugriff immer via SSH vom openclaw-gateway (hsb0) auf den Ziel-Host.
Auf dem Ziel-Host: `merlin` NixOS-User + sudo-Whitelist (keine wheel/docker-Gruppe).
Ausnahme hsb0: Merlin läuft dort selbst im Container — SSH auf localhost wenn nötig.

## Permission List

### hsb0

| Service / Container | Erlaubte Aktionen                                            | Notiz                                                                    |
| ------------------- | ------------------------------------------------------------ | ------------------------------------------------------------------------ |
| _(host)_            | `journalctl`, `systemctl status *`, `docker ps/logs/inspect` | Observer; eigener Gateway-Host                                           |
| `adguard`           | `leases.json` lesen                                          | mode 0644 via systemd.tmpfiles; `querylog.json` zu groß → ausgeschlossen |
| `openclaw-gateway`  | `docker logs`, `docker inspect`                              | Kein exec in eigenen Container                                           |
| `ncps`              | `docker logs`                                                | Nur Monitoring                                                           |

### hsb1

| Service / Container   | Erlaubte Aktionen                                            | Notiz                                                                  |
| --------------------- | ------------------------------------------------------------ | ---------------------------------------------------------------------- |
| _(host)_              | `journalctl`, `systemctl status *`, `docker ps/logs/inspect` | Observer-only auf Host-Ebene                                           |
| `homeassistant`       | `docker exec`, `docker restart`                              | HA CLI, Automationen debuggen; exec-Breakout akzeptiert (privates LAN) |
| `nodered`             | `docker exec`, `docker restart`                              | Flows lesen/debuggen                                                   |
| `opus-stream-to-mqtt` | `docker restart`, `docker logs`                              | Restart bei Hängern                                                    |
| `pidicon-light`       | `docker restart`, `docker logs`                              | Restart bei Hängern                                                    |
| `zigbee2mqtt`         | `docker logs`, `docker inspect`                              | Privileged container — kein exec, kein restart                         |
| `mosquitto`           | `docker logs`                                                | Nur Monitoring                                                         |
| `scrypted`            | `docker logs`, `docker inspect`                              | Nur Monitoring                                                         |
| `matter-server`       | `docker logs`                                                | Nur Monitoring                                                         |
| `apprise`             | `docker logs`                                                | Nur Monitoring                                                         |
| `plex`                | `docker logs`                                                | Nur Monitoring                                                         |
| `restic-cron-hetzner` | `docker logs`                                                | Backup-Container, keine Eingriffe                                      |
| `watchtower-weekly`   | `docker logs`                                                | Automatisch, keine Eingriffe                                           |
| _(filesystem)_        | `/home/mba/docker/mounts/` lesen (ro)                        | HA/MQTT Config-Files einsehen                                          |

### csb0

| Service / Container   | Erlaubte Aktionen                                            | Notiz                             |
| --------------------- | ------------------------------------------------------------ | --------------------------------- |
| _(host)_              | `journalctl`, `systemctl status *`, `docker ps/logs/inspect` | Observer                          |
| `uptime-kuma`         | `docker logs`, `docker inspect`                              | Nur Monitoring                    |
| `headscale`           | `docker logs`, `docker inspect`                              | Nur Monitoring                    |
| `traefik`             | `docker logs`                                                | Nur Monitoring                    |
| `nodered`             | `docker logs`, `docker inspect`                              | Nur Monitoring                    |
| `mosquitto`           | `docker logs`                                                | Nur Monitoring                    |
| `restic-cron-hetzner` | `docker logs`                                                | Backup-Container, keine Eingriffe |

### csb1

| Service / Container | Erlaubte Aktionen                                            | Notiz          |
| ------------------- | ------------------------------------------------------------ | -------------- |
| _(host)_            | `journalctl`, `systemctl status *`, `docker ps/logs/inspect` | Observer       |
| `traefik`           | `docker logs`                                                | Nur Monitoring |
| `mosquitto`         | `docker logs`                                                | Nur Monitoring |

### gpc0

| Service / Container | Erlaubte Aktionen                  | Notiz                |
| ------------------- | ---------------------------------- | -------------------- |
| _(host)_            | `journalctl`, `systemctl status *` | Desktop, kein Docker |

### Explizit ausgeschlossen

| Host            | Grund                                                           |
| --------------- | --------------------------------------------------------------- |
| `imac0`         | Workstation, persönliche Daten                                  |
| `miniserver-bp` | Percy's Domäne                                                  |
| `hsb8`          | Eltern-Server, anderer User (`gb`), kein Merlin-Account geplant |
| `hsb2`          | Archiviert / inaktiv                                            |

## Umsetzung

### merlin NixOS-User (pro Host)

```nix
users.users.merlin = {
  isNormalUser = true;
  # KEIN wheel, KEIN docker
  openssh.authorizedKeys.keys = [ "<merlin-pubkey>" ];
};
```

SSH-Key: via agenix, bereits für hsb1 vorhanden (`hsb0-merlin-ssh-key.age`).
Neue Hosts: SSH-Key via agenix hinzufügen.

SSH-Key-Optionen härten:

```
no-port-forwarding,no-agent-forwarding,no-X11-forwarding <pubkey>
```

### sudo-Whitelist (NixOS-Modul)

Wiederverwendbares Modul `modules/merlin-observer.nix` für Observer-only Hosts (csb0, csb1, gpc0):

```nix
security.sudo.extraRules = [{
  users = ["merlin"];
  commands = [
    { command = "/run/current-system/sw/bin/journalctl"; options = ["NOPASSWD"]; }
    { command = "/run/current-system/sw/bin/systemctl status *"; options = ["NOPASSWD"]; }
    { command = "/run/current-system/sw/bin/docker ps"; options = ["NOPASSWD"]; }
    { command = "/run/current-system/sw/bin/docker logs *"; options = ["NOPASSWD"]; }
    { command = "/run/current-system/sw/bin/docker inspect *"; options = ["NOPASSWD"]; }
  ];
}];
```

Für hsb1 (mit Service-spezifischen Aktionen): eigene extraRules direkt in `hosts/hsb1/`.

### hsb1: vollständige sudo-Whitelist

```nix
security.sudo.extraRules = [{
  users = ["merlin"];
  commands = [
    { command = "/run/current-system/sw/bin/journalctl"; options = ["NOPASSWD"]; }
    { command = "/run/current-system/sw/bin/systemctl status *"; options = ["NOPASSWD"]; }
    { command = "/run/current-system/sw/bin/docker ps"; options = ["NOPASSWD"]; }
    { command = "/run/current-system/sw/bin/docker logs *"; options = ["NOPASSWD"]; }
    { command = "/run/current-system/sw/bin/docker inspect *"; options = ["NOPASSWD"]; }
    { command = "/run/current-system/sw/bin/docker exec homeassistant *"; options = ["NOPASSWD"]; }
    { command = "/run/current-system/sw/bin/docker exec nodered *"; options = ["NOPASSWD"]; }
    { command = "/run/current-system/sw/bin/docker restart homeassistant"; options = ["NOPASSWD"]; }
    { command = "/run/current-system/sw/bin/docker restart nodered"; options = ["NOPASSWD"]; }
    { command = "/run/current-system/sw/bin/docker restart opus-stream-to-mqtt"; options = ["NOPASSWD"]; }
    { command = "/run/current-system/sw/bin/docker restart pidicon-light"; options = ["NOPASSWD"]; }
  ];
}];
```

## Implementation

- [ ] hsb1: `merlin` user — wheel + docker entfernen, sudo-Whitelist setzen
- [ ] hsb1: SSH-AuthorizedKeys mit `no-port-forwarding` etc. härten
- [ ] hsb0: AdGuard `leases.json` lesbar machen (systemd.tmpfiles mode 0644)
- [ ] csb0: `merlin` user + Observer-Whitelist via `modules/merlin-observer.nix`
- [ ] csb1: `merlin` user + Observer-Whitelist
- [ ] gpc0: `merlin` user + Observer-Whitelist (kein Docker)
- [ ] `modules/merlin-observer.nix` erstellen
- [ ] SSH-Keys für csb0, csb1, gpc0 via agenix
- [ ] Merlin-Workspace `TOOLS.md`: Permission List eintragen
- [ ] `OPENCLAW-RUNBOOK.md`: Abschnitt "Merlin Infra Access" hinzufügen

## Acceptance Criteria

- [ ] Flache Permission List vollständig + korrekt für alle aktiven Hosts
- [ ] hsb1: kein wheel/docker mehr, nur Whitelist-Befehle funktionieren
- [ ] csb0/csb1/gpc0: Observer-Zugriff via SSH funktioniert
- [ ] Kein Zugriff auf `.age`-Datei-Inhalte möglich

## Notes

- `zigbee2mqtt` läuft privileged → kein `docker exec` (Breakout-Risiko)
- `docker exec` in homeassistant/nodered = akzeptiertes Risiko (privates LAN)
- hsb1 ist Breaking Change für Merlin — Workspace TOOLS.md **vorher** updaten
- csb1: docker-compose nicht im Repo → Liste evtl. unvollständig, vor Deployment prüfen
