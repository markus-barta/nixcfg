# Cloudflare - DNS & CDN Infrastructure

**Provider**: Cloudflare  
**Primary Domain**: barta.cm  
**Management**: OpenTofu for the zones listed below; every other zone is still managed in the Cloudflare Dashboard.

## OpenTofu stacks

Each stack lives in its own directory. It uses a local state under `~/.local/share/ops-tofu/` on mbp2607 (never committed) and the personal-zone agent token through `TF_VAR_cloudflare_api_token`; `providers.tf` holds the exact commands. Never keep saved plan files: they contain the token.

| Zone          | Directory        | Since      | Ticket  | Notes                                                           |
| ------------- | ---------------- | ---------- | ------- | --------------------------------------------------------------- |
| bytepoets.com | `bytepoets.com/` | 2026-10-15 | OPS-337 | Memorial page on csb1; runbook RUN-19 (backup and restore)      |
| hausv.org     | `hausv.org/`     | 2026-10-15 | OPS-340 | All 12 records imported unchanged; 4 are owned by Email Routing |

---

## Quick Reference

| Item             | Value                                               |
| ---------------- | --------------------------------------------------- |
| **Dashboard**    | [dash.cloudflare.com](https://dash.cloudflare.com/) |
| **Domain**       | barta.cm                                            |
| **Registrar**    | TBD                                                 |
| **DNS Provider** | Cloudflare                                          |
| **Account**      | See `secrets/SECRETS.md`                            |

---

## Services Hosted

### csb0 (89.58.63.96)

| Subdomain          | Service              | Proxy    |
| ------------------ | -------------------- | -------- |
| cs0.barta.cm       | Direct server access | DNS only |
| home.barta.cm      | Node-RED             | DNS only |
| bitwarden.barta.cm | Bitwarden (TEST)     | DNS only |
| mosquitto.barta.cm | MQTT Broker          | DNS only |
| traefik.barta.cm   | Reverse proxy        | DNS only |

### csb1 (152.53.64.166)

| Subdomain          | Service              | Proxy      |
| ------------------ | -------------------- | ---------- |
| cs1.barta.cm       | Direct server access | DNS only   |
| grafana.barta.cm   | Monitoring           | DNS only   |
| influxdb.barta.cm  | Time series DB       | DNS only   |
| docmost.barta.cm   | Documentation        | ⚠️ Proxied |
| paperless.barta.cm | Document management  | ⚠️ Proxied |

### Other

| Subdomain          | Target       | Purpose     |
| ------------------ | ------------ | ----------- |
| wedding24.barta.cm | GitHub Pages | Static site |

---

## Documentation

- **DNS Records**: See `dns-barta-cm.md` for complete DNS inventory
- **Credentials**: See `secrets/SECRETS.md` (gitignored)

---

## Future: Terraform/OpenTofu

When ready to automate DNS management:

1. Create Terraform configuration in this directory
2. Store API token in `secrets/cloudflare-api-token.age`
3. Use `terraform plan` before applying changes

---

## Related

- [csb0 README](../../hosts/csb0/README.md) - Cloud server 0
- [csb1 README](../../hosts/csb1/README.md) - Cloud server 1
