# Remote state (IRD-016 §Rules). Same bucket + lock table as the other roots,
# distinct key. Backend config cannot use variables — literals required by
# Terraform's design.
terraform {
  backend "s3" {
    bucket         = "proops-taskmgmt-tfstate-apse1-339529820957"
    key            = "k3s-dev/terraform.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "proops-taskmgmt-tflock-apse1"
    encrypt        = true
  }
}
