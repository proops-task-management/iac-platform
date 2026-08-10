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
# ===========================================================================

# --- admin_cidr: hybrid (explicit var OR auto-detected public IP) -----------
# ⏳ SUNSET — this entire block is deleted by MIN-50 (private k3s API via SSM
# port-forward). Once there is no public 6443 ingress rule there is no
# `admin_cidr` to get wrong: the data source, the local, the variable, the
# ADMIN_CIDR secret, the `tf-vars` pass-through in all 5 call-sites and the
# `guard-tfvars` jobs all go with it. MIN-58 is a BRIDGE, deliberately — it
# unblocks the Phase-3 gate that MIN-50 is too large and too access-path-risky
# to sit in front of. Full teardown list: IRD-016 §Sunset.
# checkip.amazonaws.com returns the egress IP AWS actually sees (more reliable
# than third-party services under CGNAT). Used only when var.admin_cidr is null,
# so supplying the variable removes the lookup entirely rather than overriding it.
#
# Auto-detect binds the 6443 SG rule to WHOEVER RUNS apply. That is correct on a
# laptop (self-heals when the ISP rotates your IP) and wrong from CI, where the
# runner's IP is ephemeral: the apply locks the operator out of kubectl, and the
# plan shows an `<operator>/32 -> <runner>/32` diff that never converges.
#
# BOTH PATHS ARE NOW WIRED (MIN-58, was a bare TODO here from D9 to D11):
#   * local  — leave var.admin_cidr null (auto-detect) or set it in terraform.tfvars
#   * CI     — the iac-* workflows pass the ADMIN_CIDR repo secret to reusable-iac@v6
#              as `tf-vars: admin_cidr=...`, which exports TF_VAR_admin_cidr.
#              A `guard-tfvars` job FAILS RED if that secret is missing, so the
#              auto-detect fallback can never silently return in CI.
# Contract: IRD-015 §reusable-iac.yml (tf-vars) + IRD-016 §IaC pipelines.
data "http" "myip" {
  count = var.admin_cidr == null ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

locals {
  admin_cidr = var.admin_cidr != null ? var.admin_cidr : "${chomp(data.http.myip[0].response_body)}/32"
}

module "network" {
  source = "../../modules/network"

  name_prefix = var.name_prefix
  region_code = var.region_code
  admin_cidr  = local.admin_cidr
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
