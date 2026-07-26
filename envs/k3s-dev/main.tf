# ===========================================================================
# k3s-dev — the daily cluster root. Assembles network + compute-k3s.
# DNS A records are NOT here — cluster-up.sh (D10) upserts them into the zone
# owned by the `global` root (the node IP changes on every start).
# ===========================================================================

# --- admin_cidr: hybrid (explicit var OR auto-detected public IP) -----------
# checkip.amazonaws.com returns the egress IP AWS actually sees (more reliable
# than third-party services under CGNAT). Used only when var.admin_cidr is null.
# WARNING: auto-detect binds the SG to whoever runs `apply` — correct for
# laptop applies (D9/D10); at D11 the CI runner applies, so pin admin_cidr in
# the pipeline's TF_VAR_admin_cidr to avoid locking yourself out (MIN-13).
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
