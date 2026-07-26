# module: cost-guardrails

Account-level **AWS Budgets** with email alerts (DOP-011 AC-11-01). Lives in the `global`
root so a `terraform destroy` of `k3s-dev` never removes your spend alarms.

- **Monthly** budget: `$30/mo`, alerts at ACTUAL 80 % / 100 % + FORECASTED 100 %.
- **Total** budget: `$180`, modeled as an ANNUALLY budget (AWS has no lifetime budget).
- AWS Budgets emails subscribers directly — **no SNS topic needed**.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `monthly_limit_usd` | number | `30` | Monthly cap. |
| `total_limit_usd` | number | `180` | Program total cap. |
| `alert_email` | string | — | Subscribed email. |
| `total_budget_period_start` | string | `2026-07-01_00:00` | Total-budget window start. |

## Outputs

| Name | Description |
|---|---|
| `monthly_budget_name` / `total_budget_name` | Budget names. |

> The nightly **EC2 auto-stop (23:00 ICT)** lives in `compute-k3s` (it needs the instance
> IDs and must be destroyed with the cluster) — not here. See IRD-016 audit log 2026-07-14.
