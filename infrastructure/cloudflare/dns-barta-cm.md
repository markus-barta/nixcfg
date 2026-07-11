# DNS Configuration - barta.cm

**Domain**: barta.cm  
**Registrar**: TBD  
**DNS Provider**: Cloudflare  
**Status**: Manually managed (target: declarative with Terraform/OpenTofu)

---

## Current DNS Records

### A Records (Direct IP)

| Subdomain   | IP Address    | Proxy Status | Target Server | Notes                   |
| ----------- | ------------- | ------------ | ------------- | ----------------------- |
| `cs0`       | 89.58.63.96   | DNS only     | csb0          | Direct server access    |
| `cs1`       | 152.53.64.166 | DNS only     | csb1          | Direct server access    |
| `docmost`   | 152.53.64.166 | ⚠️ Proxied   | csb1          | Via Cloudflare proxy    |
| `paperless` | 152.53.64.166 | ⚠️ Proxied   | csb1          | Via Cloudflare proxy    |
| `traefik`   | 89.58.63.96   | DNS only     | csb0          | Reverse proxy dashboard |

### CNAME Records (Aliases)

| Subdomain   | Target                 | Server | Service Type            |
| ----------- | ---------------------- | ------ | ----------------------- |
| `bitwarden` | cs0.barta.cm           | csb0   | Password manager        |
| `home`      | cs0.barta.cm           | csb0   | Home Assistant (likely) |
| `mosquitto` | cs0.barta.cm           | csb0   | MQTT broker             |
| `wedding24` | markus-barta.github.io | GitHub | Static site             |

**Note**: `hdoc.barta.cm` (Hedgedoc) - **DECOMMISSIONED** (scheduled for removal during csb1 migration)

**Note**: `grafana.barta.cm` + `influxdb.barta.cm` - **RETIRED 2026-06-12** (NIX-193; Cloudflare records pending manual deletion)

### Redirects (Cloudflare Page Rules)

| Source           | Target                       | Code | Rule ID (Cloudflare)               | Notes                                                               |
| ---------------- | ---------------------------- | ---- | ---------------------------------- | ------------------------------------------------------------------- |
| `fleet.barta.cm` | `https://pharos.barta.cm/$1` | 301  | `f81a85b0e4f5e544a855d957d0118699` | FleetCom decommissioned (FLEET-202); path-preserving forwarding URL |

`fleet.barta.cm` stays proxied (orange) so Cloudflare serves the 301 at the edge; the CNAME still points at `cs1` but the origin FleetCom server was removed (FLEET-199). Created via API with the barta.cm-scoped `CF_ZONE_TOKEN` (Page Rules permission; the token lacks Rulesets/Redirect-Rules perm). Manage in the dashboard until DNS goes declarative.

---

## Server Service Distribution

### csb0 (89.58.63.96)

Services accessible via subdomains:

- `bitwarden.barta.cm` - Password manager
- `home.barta.cm` - Home Assistant
- `mosquitto.barta.cm` - MQTT broker
- `traefik.barta.cm` - Reverse proxy dashboard

### csb1 (152.53.64.166)

Services accessible via subdomains:

- `docmost.barta.cm` - Documentation (Cloudflare proxied)
- `paperless.barta.cm` - Document management (Cloudflare proxied)

---

## Cloudflare Proxy Status

**Proxied** (🟠 Orange cloud):

- `docmost.barta.cm` - Benefits from CDN, DDoS protection
- `paperless.barta.cm` - Benefits from CDN, DDoS protection

**DNS Only** (⛅ Gray cloud):

- All other subdomains - Direct connection to servers

---

## Future: Declarative DNS Management

### Current State

- ⚠️ **Manual**: DNS records managed via Cloudflare web UI
- ⚠️ **No Version Control**: Changes not tracked in git
- ⚠️ **No Documentation**: This file is first attempt

### Target State

Use Terraform/OpenTofu with Cloudflare provider to manage DNS declaratively:

```hcl
# Example structure (not implemented yet)
resource "cloudflare_record" "cs0" {
  zone_id = var.cloudflare_zone_id
  name    = "cs0"
  value   = "89.58.63.96"
  type    = "A"
  proxied = false
}

```

**Benefits**:

- ✅ Version controlled DNS configuration
- ✅ Audit trail of all changes
- ✅ Easy to replicate/disaster recovery
- ✅ Can review changes before applying
- ✅ Integrates with secrets management (Cloudflare API token)

**Required**:

- Cloudflare API token (store in encrypted secrets)
- Terraform/OpenTofu state management
- CI/CD pipeline for DNS changes (optional)

---

## DNS Management TODO

### Immediate

- [x] Document current DNS records (this file)
- [ ] Export current Cloudflare DNS zone (backup)
- [ ] Add Cloudflare API credentials to secrets management

### Short Term

- [ ] Create Terraform configuration for DNS
- [ ] Import existing DNS records to Terraform state
- [ ] Test changes in Terraform plan mode
- [ ] Document DNS change workflow

### Long Term

- [ ] Integrate with nixos-rebuild (update DNS when deploying)
- [ ] Automate SSL certificate management (cert-manager or similar)
- [ ] Monitor DNS propagation and health

---

## Related Services

### Reverse Proxy Architecture

**csb0 (Traefik)**:

- Routes: bitwarden, home, mosquitto
- SSL termination for HTTP services
- Dashboard at traefik.barta.cm

**csb1 (Likely Traefik or Caddy)**:

- Routes: grafana, influxdb, docmost, paperless
- Cloudflare proxy for docmost/paperless
- Direct connections for grafana/influxdb

---

## Security Considerations

### Cloudflare Proxy

**Proxied services** (docmost, paperless):

- ✅ Hide real server IP
- ✅ DDoS protection
- ✅ CDN for static assets
- ❌ Cloudflare can decrypt traffic (if not using Full SSL)

**DNS-only services**:

- ✅ Direct connection (lower latency)
- ✅ Full control over SSL/TLS
- ❌ Real server IP exposed
- ❌ No DDoS protection from Cloudflare

### Recommendations

- Use Cloudflare proxy for public-facing services (docmost, paperless)
- Use DNS-only for services requiring:
  - SSH access (cs0, cs1)
  - MQTT (mosquitto)
  - Direct database connections (influxdb)
  - Admin interfaces (grafana, traefik)

---

## References

- Cloudflare DNS: [dash.cloudflare.com](https://dash.cloudflare.com/)
- Terraform Cloudflare Provider: [registry.terraform.io/providers/cloudflare/cloudflare](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs)
- [csb0 README](../hosts/csb0/README.md)
- [csb1 README](../hosts/csb1/README.md)
