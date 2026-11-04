# ===========================================================================
# k3s-dev — the daily cluster root. Assembles network + compute-k3s.
# DNS A records are NOT here — cluster-up.sh (D10) upserts them into the zone
# owned by the `global` root (the node IP changes on every start).
#
# THIS ROOT IS METERED (~$1/day, 2x t3.medium). Merging a change here does NOT
# necessarily apply it: `iac-pr-merged` is reconcile-only on this root, so
# `guard-k3s-dev` skips the apply (warning + job summary, green run) whenever no
# k3s-server instance exists. Creating the cluster from empty state is a human
# cost decision — `iac-manual` (root=envs/k3s-dev, action=apply,
# confirm=envs/k3s-dev) or a local `terraform apply` here. NOT cluster-up.sh:
# that is a stopped -> running script and hard-fails against empty state.
# So after a `terraform destroy`, expect your merged change to sit UNAPPLIED
# until the next window — that is by design (MIN-56 / TSG-026), not a failure.
#
# Conversely: the `changes` paths-filter keys on FILE PATHS, not on plan content.
# A comment-only edit to this file therefore still triggers the full
# plan -> guard-k3s-dev -> apply chain, with a zero-diff plan.
# That is deliberate and useful: it is how the pipeline is exercised end-to-end
# against a live cluster without changing any infrastructure (MIN-15, MIN-56 AC-2,
# MIN-58 AC-4/AC-5 were all proven this way, in one merge, at a metered window).
#
# No operator IP is an input any more (MIN-50 / ADR-017). The k3s API has no public
# ingress — operator kubectl goes through an SSM port-forward (scripts/k8s-tunnel.sh) —
# so `plan` is a pure function of config + state: no `data "http" "myip"`, no
# `admin_cidr`, and no way for "who ran apply" to change desired state (the MIN-58 class).
# ===========================================================================

module "network" {
  source = "../../modules/network"

  name_prefix = var.name_prefix
  region_code = var.region_code
}

module "compute_k3s" {
  source = "../../modules/compute-k3s"

  name_prefix       = var.name_prefix
  region_code       = var.region_code
  subnet_id         = element(module.network.subnet_ids, 0)
  security_group_id = module.network.sg_node_id
  instance_type     = var.instance_type
  root_volume_gb    = var.root_volume_gb
  enable_auto_stop  = var.enable_auto_stop

  # S3 ARN built from the deterministic bucket name (no live lookup — works
  # before `global` is applied). Grants the node role the aws_ssm transfer
  # access the D10 Ansible run needs (P0-5).
  ssm_transfer_bucket_arn = "arn:aws:s3:::${var.ssm_transfer_bucket_name}"
}
