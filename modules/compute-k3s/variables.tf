# ---------------------------------------------------------------------------
# compute-k3s — inputs (IRD-016 module contract).
# 2 EC2 nodes (server + agent), amd64 (x86_64) AL2023, SSM-managed (no SSH).
# amd64 is REQUIRED: CI builds linux/amd64-only images (ADR-011), so the k3s
# runtime arch must match or every pod CrashLoops (exec format error). See ADR-015.
# k3s itself is installed by Ansible (D10) — user_data stays MINIMAL (IRD-014/IRD-016).
# Also owns the nightly EC2 auto-stop scheduler (needs the instance IDs).
# ---------------------------------------------------------------------------

variable "name_prefix" {
  type        = string
  description = "Resource-name prefix, e.g. proops-taskmgmt-dev (IRD-013 naming)."
}

variable "region_code" {
  type        = string
  description = "Short region code for the 6-part name {project}-{env}-{type}-{region}-{purpose}."
  default     = "apse1"
}

variable "subnet_id" {
  type        = string
  description = "Subnet for both nodes (same AZ so flannel VXLAN stays simple)."
}

variable "security_group_id" {
  type        = string
  description = "Node Security Group id (from the network module)."
}

variable "instance_type" {
  type        = string
  description = "amd64 (x86_64) instance type. Default t3.medium = 2 vCPU / 4 GiB. MUST be amd64 to match CI's linux/amd64-only images (ADR-011/ADR-015) — an arm64 type (t4g.*) makes every pod CrashLoop."
  default     = "t3.medium"
}

variable "ami_id" {
  type        = string
  description = "Override AMI id. null => latest AL2023 x86_64 (al2023-ami-2023.*, NOT minimal — Day 31 lesson)."
  default     = null
}

variable "root_volume_gb" {
  type        = number
  description = "Root gp3 volume size (GiB)."
  default     = 20
}

variable "ssm_param_arn_prefix" {
  type        = string
  description = "SSM parameter ARN glob the node role may read (ESO node-IAM auth, IRD-019). null => /proops/* in this account/region."
  default     = null
}

variable "ssm_transfer_bucket_arn" {
  type        = string
  description = "ARN of the S3 bucket the community.aws.aws_ssm connection stages its ephemeral Ansible module in (the plan-artifacts bucket, IRD-016 §Ansible). The node pulls/pushes the transfer object with its OWN role, so it needs s3 access here — without it the SSM connection authenticates but the first file transfer fails AccessDenied and no task runs (P0-5)."
}

variable "enable_auto_stop" {
  type        = bool
  description = "Create the nightly EC2 auto-stop scheduler (cost guardrail)."
  default     = true
}

variable "stop_cron_expression" {
  type        = string
  description = "EventBridge Scheduler expression. Default 16:00 UTC = 23:00 ICT (IRD-016)."
  default     = "cron(0 16 * * ? *)"
}

variable "stop_timezone" {
  type        = string
  description = "Timezone for stop_cron_expression."
  default     = "UTC"
}
