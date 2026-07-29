# module: dns

Owns the **public Route 53 hosted zone** for the platform domain (long-lived → lives in the
`global` root). A records (`app/api/argocd/grafana`) are **not** managed here — the node IP
changes on every `cluster-up`, so `cluster-up.sh` (D10) upserts them via
`aws route53 change-resource-record-sets` to avoid daily Terraform drift (IRD-016).

## Domain (MIN-13 decision B)

Register a **free DigitalPlat domain** (current: `taskmgmt.dpdns.org`, registered 2026-07-29),
then set its **custom nameservers** to this zone's `name_servers` output — one-time delegation.

**Creating the zone is not enough.** Delegation happens at the *registrar*, outside Terraform's
reach. An undelegated zone is an **orphan**: it accepts records happily and nothing in it resolves,
while `terraform apply` still goes green. Verify before anything metered runs:

```bash
dig +short NS taskmgmt.dpdns.org   # must return this zone's 4 awsdns names; empty = orphan
```

That check cost a whole Phase-3 window when it was missing — see **TSG-029** / **MIN-59**, and
IRD-016 §Prerequisites. Note also that **renaming the domain replaces the zone**
(`aws_route53_zone.name` is ForceNew) and issues a **new delegation set** — the nameservers must be
re-pasted at the registrar after any rename.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `domain` | string | — | Apex domain, e.g. `taskmgmt.dpdns.org`. Validated. **ForceNew** — changing it destroys and recreates the zone. |

## Outputs

| Name | Description |
|---|---|
| `zone_id` | Zone id → `cluster-up.sh` A-record upserts. |
| `zone_name` | The delegated domain. |
| `name_servers` | 4 NS records → paste into DigitalPlat (delegation). |
