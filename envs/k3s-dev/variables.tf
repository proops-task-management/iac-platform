# Inputs for the daily k3s cluster root (IRD-016). Defaults are the known-good
# values so `terraform plan` runs with an empty tfvars; override in
# terraform.tfvars (gitignored) when they change.

variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "owner" {
  type    = string
  default = "minh_dt"
}

variable "email" {
  type    = string
  default = "tuanminh.dinh.work@gmail.com"
}

variable "project" {
  type    = string
  default = "proops-taskmgmt"
}

variable "cost_center" {
  type    = string
  default = "training"
}

variable "name_prefix" {
  type        = string
  default     = "proops-taskmgmt-dev"
  description = "Resource-name prefix (IRD-013 naming)."
}

variable "region_code" {
  type        = string
  default     = "apse1"
  description = "Short region code for 6-part resource names (ap-southeast-1 -> apse1)."
}

# ⏳ SUNSET — this variable is deleted by MIN-50 (private k3s API via SSM
# port-forward): no public 6443 rule => nothing consumes admin_cidr. IRD-016 §Sunset.
# admin_cidr: null => auto-detect the applier's public IP (laptop applies, D9/D10).
# From CI it is supplied as TF_VAR_admin_cidr, sourced from the iac-platform ADMIN_CIDR
# secret via reusable-iac@v6's `tf-vars` channel — so the SG opens 6443 to YOU, never to
# the runner (MIN-58). See envs/k3s-dev/main.tf for the full path table.
variable "admin_cidr" {
  type        = string
  default     = null
  description = "Operator /32 allowed on k3s API 6443. null => auto-detect via checkip.amazonaws.com (laptop); set via TF_VAR_admin_cidr from the ADMIN_CIDR secret in CI."
}

variable "instance_type" {
  type        = string
  default     = "t3.medium"
  description = "amd64 (x86_64) node size, 2 vCPU / 4 GiB. MUST be amd64 to match CI's linux/amd64-only images (ADR-011/ADR-015)."
}

variable "root_volume_gb" {
  type    = number
  default = 20
}

variable "enable_auto_stop" {
  type        = bool
  default     = true
  description = "Nightly EC2 auto-stop at 23:00 ICT (cost guardrail)."
}

# The plan-artifacts bucket (created in the `global` root) doubles as the
# community.aws.aws_ssm file-transfer bucket for the D10 Ansible run (IRD-016).
# Name is deterministic → build the ARN from it (no live data lookup, so a
# k3s-dev plan works even before `global` is applied). See P0-5.
variable "ssm_transfer_bucket_name" {
  type        = string
  default     = "proops-taskmgmt-global-s3-apse1-planartifacts"
  description = "Global plan-artifacts S3 bucket used as the aws_ssm transfer bucket. Node role gets scoped s3 access to it (P0-5)."
}
