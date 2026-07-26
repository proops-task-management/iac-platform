# module: storage

Two long-lived S3 buckets (in the `global` root): **db-backups** and **plan-artifacts**.
Both versioned, SSE-AES256, all public access blocked. Provider 6.x tags at create
(this account denies untagged `s3:CreateBucket` — IRD-013).

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `dbbackups_bucket_name` | string | — | `proops-taskmgmt-global-s3-apse1-dbbackups`. |
| `planartifacts_bucket_name` | string | — | Must match `iam-github-oidc`'s `plan_artifacts_bucket_name`. |
| `backup_retention_days` | number | `14` | MySQL dump expiry. |
| `planartifacts_retention_days` | number | `30` | Plan-artifact expiry. |

## Outputs

| Name | Description |
|---|---|
| `dbbackups_bucket_name` / `_arn` | → backup/restore CronJob (D15). |
| `planartifacts_bucket_name` / `_arn` | → `gha-iac-plan` role + Ansible SSM transfer. |

> **No `force_destroy`** on the backups bucket — it holds the only off-cluster copy of MySQL.
