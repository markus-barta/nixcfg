# Cloudflare - DNS & CDN Infrastructure

**Provider**: Cloudflare  
**Primary Domain**: barta.cm  
**Management**: Manual (Cloudflare Dashboard) - Future: Terraform/OpenTofu

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

### csb0 (85.235.65.226)

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
