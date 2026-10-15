# OPS-340: hausv.org DNS as code (personal zone, Markus's Cloudflare account; adopted 2026-10-15).
# Run from mbp2607 with the existing personal-zone agent token; state stays local and untracked:
#   ( set -a; source ~/.inspr/secrets/agents/CF_ZONE_TOKEN_AIA.env; set +a
#     export TF_VAR_cloudflare_api_token="$CF_ZONE_TOKEN_AIA"
#     tofu init -backend-config="path=$HOME/.local/share/ops-tofu/cloudflare-hausv.org/terraform.tfstate"
#     tofu plan )
# This stack manages ONLY the records declared in main.tf; every other hausv.org record stays as it is (not imported).
# Pre-change zone backup: ~/.local/share/ops-qa/hausv/ (BIND export + JSON), referenced on OPS-340.
terraform {
  required_version = ">= 1.6"
  backend "local" {}
  required_providers {
    cloudflare = {
      # Same provider line as inspr-services/services/cloudflare (v4 cloudflare_record schema).
      source  = "cloudflare/cloudflare"
      version = "~> 4.52"
    }
  }
}

variable "cloudflare_api_token" {
  description = "Personal-zone token from the agenix agent-secret pipeline, supplied through TF_VAR_cloudflare_api_token"
  type        = string
  sensitive   = true
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
