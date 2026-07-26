# ---------------------------------------------------------------------------
# dns — inputs (IRD-016 module contract).
# This module owns the long-lived public HOSTED ZONE only. The A records
# (app/api/argocd/grafana) point at the daily node IP, which changes on every
# cluster-up — so they are upserted imperatively by `cluster-up.sh` (D10),
# NOT by Terraform, to avoid daily state drift (IRD-016 §Module contracts).
# ---------------------------------------------------------------------------

variable "domain" {
  type        = string
  description = "Apex domain for the platform, e.g. proops-taskmgmt.dpdns.org. A free DigitalPlat domain whose nameservers are delegated to this Route 53 zone (decision: MIN-13 option B)."

  validation {
    condition     = can(regex("^([a-z0-9-]+\\.)+[a-z]{2,}$", var.domain))
    error_message = "domain must be a valid DNS name, e.g. proops-taskmgmt.dpdns.org."
  }
}
