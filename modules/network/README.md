# module: network

Looks up the account **default VPC** + subnets and owns the **k3s node Security Group**.
No custom VPC (cost = $0; default VPC is fine for the daily cluster — IRD-016).

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | string | — | Resource-name prefix, e.g. `proops-taskmgmt-dev` (IRD-013). |
| `region_code` | string | `apse1` | Region segment of the 6-part name. |
| `api_port` | number | `6443` | k3s API/supervisor port — opened node-to-node (self) only. |

`admin_cidr` was removed by MIN-50 (ADR-017): operator `kubectl` reaches the API through an SSM
port-forward (`scripts/k8s-tunnel.sh`), so there is no public 6443 rule and nothing to allowlist.

## Outputs

| Name | Description |
|---|---|
| `sg_node_id` | Node SG id (→ compute-k3s). |
| `vpc_id` | Default VPC id. |
| `subnet_ids` | Default subnet ids (node placement). |

## SG rule matrix

| Port | Proto | Source | Why |
|---|---|---|---|
| 6443 | tcp | **no public source** | operator `kubectl` uses an SSM port-forward (MIN-50 / ADR-017); break-glass = a temporary `iac-manual` rule, reverted |
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
}
```
