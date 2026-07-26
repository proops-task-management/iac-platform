# module: dns

Owns the **public Route 53 hosted zone** for the platform domain (long-lived → lives in the
`global` root). A records (`app/api/argocd/grafana`) are **not** managed here — the node IP
changes on every `cluster-up`, so `cluster-up.sh` (D10) upserts them via
`aws route53 change-resource-record-sets` to avoid daily Terraform drift (IRD-016).

## Domain (MIN-13 decision B)

Register a **free DigitalPlat domain** (e.g. `proops-taskmgmt.dpdns.org`), then set its
**custom nameservers** to this zone's `name_servers` output — one-time delegation.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `domain` | string | — | Apex domain, e.g. `proops-taskmgmt.dpdns.org`. Validated. |

## Outputs

| Name | Description |
|---|---|
| `zone_id` | Zone id → `cluster-up.sh` A-record upserts. |
| `zone_name` | The delegated domain. |
| `name_servers` | 4 NS records → paste into DigitalPlat (delegation). |
