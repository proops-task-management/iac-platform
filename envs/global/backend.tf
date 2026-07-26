# Remote state (IRD-016 §Rules — no local-only state). The bucket + lock table
# already exist in account 339529820957 (verified 2026-07-09). Backend config
# cannot use variables — these literals are required by Terraform's design.
terraform {
  backend "s3" {
    bucket         = "proops-taskmgmt-tfstate-apse1-339529820957"
    key            = "global/terraform.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "proops-taskmgmt-tflock-apse1"
    encrypt        = true
  }
}
