# Provider pins per IRD-013. (`hashicorp/http` was removed with admin_cidr — MIN-50.)
terraform {
  required_version = ">= 1.7, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
