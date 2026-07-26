# module: network

Looks up the account **default VPC** + subnets and owns the **k3s node Security Group**.
No custom VPC (cost = $0; default VPC is fine for the daily cluster — IRD-016).

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | string | — | Resource-name prefix, e.g. `proops-taskmgmt-dev` (IRD-013). |
| `region_code` | string | `apse1` | Region segment of the 6-part name. |
| `admin_cidr` | string | — | Operator CIDR allowed on 6443. Validated; never `0.0.0.0/0`. |
| `api_port` | number | `6443` | k3s API port exposed to `admin_cidr`. |

## Outputs

| Name | Description |
|---|---|
| `sg_node_id` | Node SG id (→ compute-k3s). |
| `vpc_id` | Default VPC id. |
| `subnet_ids` | Default subnet ids (node placement). |

## SG rule matrix

| Port | Proto | Source | Why |
|---|---|---|---|
| 6443 | tcp | `admin_cidr` | kubectl → API server (operator only) |
| 6443 | tcp | self | k3s API/supervisor node-to-node — **agent joins the server**; without this self rule the agent never registers (kubelet never comes up) |
| 80 / 443 | tcp | `0.0.0.0/0` | Traefik ingress (only public surface) |
| 8472 | udp | self | flannel VXLAN (node ↔ node) |
| 10250 | tcp | self | kubelet (node ↔ node) |
| 22 | — | — | **none** — SSM-only management, no SSH keys exist (IRD-016) |

## Usage

```hcl
module "network" {
  source      = "../../modules/network"
  name_prefix = "proops-taskmgmt-dev"
  admin_cidr  = local.admin_cidr # coalesce(var.admin_cidr, checkip)
}
```

<!-- CI plan-proof (MIN-15): a modules/** change fires iac-pr-opened → per-root `terraform plan` (gha-iac-plan OIDC, read-only) + a plan comment on the PR. Discarded, not merged. -->

