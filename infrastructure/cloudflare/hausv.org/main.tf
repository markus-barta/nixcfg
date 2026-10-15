# OPS-340: hausv.org DNS as code (personal zone, Markus's Cloudflare account), adopted 2026-10-15 at Markus's request.
# All 12 pre-existing records were imported unchanged (contents, TTL, proxy, priority, comments); the full pre-adoption
# zone (BIND export + JSON) is in ~/.local/share/ops-qa/hausv/ and on OPS-340. Every value here is public DNS data.
# State: ~/.local/share/ops-tofu/cloudflare-hausv.org/ (local, untracked); the import blocks stayed in a private adoption folder.
# Web names: CNAME to csb1 (cs1.barta.cm), proxied, zone SSL mode strict. Mail: Cloudflare Email Routing (apex MX/SPF/DKIM)
# and the hausv app's outbound mail on send.notify / notify (Amazon SES via Resend).
locals {
  zone_id = "db977109656f248fdd07570e85e6eb4b" # hausv.org
}

resource "cloudflare_record" "apex_cname" {
  zone_id = local.zone_id
  type    = "CNAME"
  name    = "hausv.org"
  content = "cs1.barta.cm"
  proxied = true
  ttl     = 1
  tags    = []
}

resource "cloudflare_record" "www_cname" {
  zone_id = local.zone_id
  type    = "CNAME"
  name    = "www"
  content = "cs1.barta.cm"
  proxied = true
  ttl     = 1
  tags    = []
}

resource "cloudflare_record" "jhw22_cname" {
  zone_id = local.zone_id
  type    = "CNAME"
  name    = "jhw22"
  content = "cs1.barta.cm"
  proxied = true
  ttl     = 1
  comment = "WEG Portal tenant jhw22 on csb1"
  tags    = []
}

# Owned by Cloudflare Email Routing (locked): change it in the Email Routing settings; a tofu write fails with 1046.
resource "cloudflare_record" "apex_mx_13" {
  zone_id  = local.zone_id
  type     = "MX"
  name     = "hausv.org"
  content  = "route2.mx.cloudflare.net"
  priority = 13
  proxied  = false
  ttl      = 1
  tags     = []
}

# Owned by Cloudflare Email Routing (locked): change it in the Email Routing settings; a tofu write fails with 1046.
resource "cloudflare_record" "apex_mx_36" {
  zone_id  = local.zone_id
  type     = "MX"
  name     = "hausv.org"
  content  = "route1.mx.cloudflare.net"
  priority = 36
  proxied  = false
  ttl      = 1
  tags     = []
}

# Owned by Cloudflare Email Routing (locked): change it in the Email Routing settings; a tofu write fails with 1046.
resource "cloudflare_record" "apex_mx_66" {
  zone_id  = local.zone_id
  type     = "MX"
  name     = "hausv.org"
  content  = "route3.mx.cloudflare.net"
  priority = 66
  proxied  = false
  ttl      = 1
  tags     = []
}

resource "cloudflare_record" "apex_spf_txt" {
  zone_id = local.zone_id
  type    = "TXT"
  name    = "hausv.org"
  content = "\"v=spf1 include:_spf.mx.cloudflare.net ~all\""
  proxied = false
  ttl     = 1
  tags    = []
}

# Owned by Cloudflare Email Routing (locked): change it in the Email Routing settings; a tofu write fails with 1046.
resource "cloudflare_record" "apex_dkim_cf2024_txt" {
  zone_id = local.zone_id
  type    = "TXT"
  name    = "cf2024-1._domainkey"
  content = "\"v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAiweykoi+o48IOGuP7GR3X0MOExCUDY/BCRHoWBnh3rChl7WhdyCxW3jgq1daEjPPqoi7sJvdg5hEQVsgVRQP4DcnQDVjGMbASQtrY4WmB1VebF+RPJB2ECPsEDTpeiI5ZyUAwJaVX7r6bznU67g7LvFq35yIo4sdlmtZGV+i0H4cpYH9+3JJ78k\" \"m4KXwaf9xUJCWF6nxeD+qG6Fyruw1Qlbds2r85U9dkNDVAS3gioCvELryh1TxKGiVTkg4wqHTyHfWsp7KD3WQHYJn0RyfJJu6YEmL77zonn7p2SRMvTMP3ZEXibnC9gz3nnhR6wcYL8Q7zXypKTMD58bTixDSJwIDAQAB\""
  proxied = false
  ttl     = 1
  tags    = []
}

resource "cloudflare_record" "notify_send_mx" {
  zone_id  = local.zone_id
  type     = "MX"
  name     = "send.notify"
  content  = "feedback-smtp.eu-west-1.amazonses.com"
  priority = 10
  proxied  = false
  ttl      = 1
  tags     = []
}

resource "cloudflare_record" "notify_send_spf_txt" {
  zone_id = local.zone_id
  type    = "TXT"
  name    = "send.notify"
  content = "v=spf1 include:amazonses.com ~all"
  proxied = false
  ttl     = 1
  tags    = []
}

resource "cloudflare_record" "notify_dmarc_txt" {
  zone_id = local.zone_id
  type    = "TXT"
  name    = "_dmarc.notify"
  content = "v=DMARC1; p=none;"
  proxied = false
  ttl     = 1
  tags    = []
}

resource "cloudflare_record" "notify_resend_dkim_txt" {
  zone_id = local.zone_id
  type    = "TXT"
  name    = "resend._domainkey.notify"
  content = "p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC44/B3YM3Mjs1KyTUgaKoo5lEiDb4pEoSqEQgLgcQT5UbUbeA/aH4cfRpv24u3ump4NpTt29gjNgR1cLem5L58hLTU5SyFqtlgAQRFdGoqg6cWUSZvS5IpNl/3A7SFaf/lo7RpQ4jaGd71ghUUZS9isKaSxsfCQdOe6N6jtEo1nQIDAQAB"
  proxied = false
  ttl     = 1
  tags    = []
}


# OPS-340: public static page for a private WEG heat-pump project (in-page PIN only, noindex), served by csb1.
resource "cloudflare_record" "jhw22_wp_cname" {
  zone_id = local.zone_id
  type    = "CNAME"
  name    = "jhw22-wp"
  content = "cs1.barta.cm"
  proxied = true
  ttl     = 1
  comment = "OPS-340 public WEG heat-pump page on csb1"
  tags    = []
}

# OPS-340: contact alias for the page's "send your consumption" button. Retire it after the planning phase, as the page
# promises. The destination (a verified Email Routing address) is supplied through TF_VAR_erdwaerme_forward_to and never
# committed; the other hausv.org routing rules (hello@, hallo@, catch-all) are not managed here yet.
variable "erdwaerme_forward_to" {
  description = "Verified Email Routing destination for erdwaerme@hausv.org (TF_VAR_erdwaerme_forward_to)"
  type        = string
  sensitive   = true
}

resource "cloudflare_email_routing_rule" "erdwaerme" {
  zone_id = local.zone_id
  name    = "OPS-340 erdwaerme@hausv.org (WEG heat-pump page; retire after planning)"
  enabled = true
  matcher {
    type  = "literal"
    field = "to"
    value = "erdwaerme@hausv.org"
  }
  action {
    type  = "forward"
    value = [var.erdwaerme_forward_to]
  }
}
