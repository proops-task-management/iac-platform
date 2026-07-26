# ===========================================================================
# dns — public Route 53 hosted zone (zone only).
# After first apply, delegate the domain at the registrar (DigitalPlat free
# domain) by setting its custom nameservers to `name_servers` output below.
# A records are managed by cluster-up.sh (see variables.tf note).
# ===========================================================================

resource "aws_route53_zone" "this" {
  name    = var.domain
  comment = "proops-taskmgmt platform zone (A records upserted by cluster-up.sh)"

  # A hosted zone's NS values are what you delegate to at the registrar. Guard
  # against an accidental destroy that would force re-delegation.
  # why: re-creating the zone changes the 4 NS records and breaks delegation.
  lifecycle {
    prevent_destroy = false # k3s-dev rebuild drills never touch this (global root)
  }
}
