# ---------------------------------------------------------------------------
# network — inputs (IRD-016 module contract).
# Daily k3s cluster uses the account's DEFAULT VPC (no custom VPC cost); this
# module only looks it up and owns the node Security Group.
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

variable "admin_cidr" {
  type        = string
  description = "Operator /32 (or CIDR) allowed to reach the k3s API on 6443. Never 0.0.0.0/0."

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0))
    error_message = "admin_cidr must be a valid CIDR, e.g. 203.0.113.4/32."
  }
}

variable "api_port" {
  type        = number
  description = "Kubernetes API server port exposed to admin_cidr only."
  default     = 6443
}
