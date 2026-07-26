# Provider pins per IRD-013 (TF >=1.7,<2.0 ; AWS ~>6.0). One provider version
# per repo — inherits the root's provider (and its 6 default_tags).
terraform {
  required_version = ">= 1.7, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
