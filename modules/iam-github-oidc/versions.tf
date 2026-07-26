# Provider pins per IRD-013 (TF >=1.7,<2.0 ; AWS ~>6.0 — 6.x tags S3 at create,
# required by this account's tag-at-create guardrail; see IRD-013/IRD-016).
# `tls` is used only to derive GitHub's OIDC thumbprint dynamically.
terraform {
  required_version = ">= 1.7, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
