# 6 mandatory default_tags (IRD-013 / IRD-016). Every resource inherits them.
# Environment = "global" for this long-lived, apply-once root.
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Owner       = var.owner
      Email       = var.email
      Project     = var.project
      Environment = "global"
      ManagedBy   = "terraform"
      CostCenter  = var.cost_center
    }
  }
}
