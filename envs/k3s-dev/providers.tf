# 6 mandatory default_tags (IRD-013 / IRD-016). Every resource inherits them.
# Environment = "dev" for the daily k3s cluster root.
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Owner       = var.owner
      Email       = var.email
      Project     = var.project
      Environment = "dev"
      ManagedBy   = "terraform"
      CostCenter  = var.cost_center
    }
  }
}
