# OPS-337: bytepoets.com is a memorial page (BYTEPOETS 2011–2026) served by csb1.
# Every other record was retired on 2026-10-15; the complete previous zone is backed up
# in OPS runbook domain-bytepoets-com (RUN-19). The domain sends and receives no mail.
locals {
  zone_id = "aec801e09d2346ae48eb7082bdb90b47" # bytepoets.com
  csb1_ip = "152.53.64.166"
}

# Public HTTP: proxied per OPS guideline cloudflare-dns-proxy-policy (zone SSL mode: full).
resource "cloudflare_record" "apex_a" {
  zone_id = local.zone_id
  type    = "A"
  name    = "bytepoets.com"
  content = local.csb1_ip
  proxied = true
  ttl     = 1
  comment = "OPS-337 memorial page on csb1"
  tags    = []
}

# A CNAME cannot coexist with A/AAAA on the same name: the 2026-10-15 migration removed the
# legacy www A/AAAA in a separate, earlier apply (runbook domain-bytepoets-com).
resource "cloudflare_record" "www_cname" {
  zone_id = local.zone_id
  type    = "CNAME"
  name    = "www"
  content = "bytepoets.com"
  proxied = true
  ttl     = 1
  comment = "OPS-337 memorial page on csb1"
  tags    = []
}

# No mail: null MX (RFC 7505), SPF that authorises nobody, DMARC reject.
resource "cloudflare_record" "apex_mx" {
  zone_id  = local.zone_id
  type     = "MX"
  name     = "bytepoets.com"
  content  = "."
  priority = 0
  proxied  = false
  ttl      = 1
  comment  = "OPS-337 null MX: this domain receives no mail"
  tags     = []
}

resource "cloudflare_record" "apex_spf_txt" {
  zone_id = local.zone_id
  type    = "TXT"
  name    = "bytepoets.com"
  content = "v=spf1 -all"
  proxied = false
  ttl     = 1
  comment = "OPS-337 this domain sends no mail"
  tags    = []
}

resource "cloudflare_record" "dmarc_txt" {
  zone_id = local.zone_id
  type    = "TXT"
  name    = "_dmarc"
  content = "v=DMARC1; p=reject;"
  proxied = false
  ttl     = 1
  comment = "OPS-337 reject mail claiming to be from this domain"
  tags    = []
}
