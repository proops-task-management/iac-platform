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

variable "api_port" {
  type        = number
  description = "k3s API/supervisor port, opened node-to-node (self) only — no public ingress (MIN-50 / ADR-017)."
  default     = 6443
}
