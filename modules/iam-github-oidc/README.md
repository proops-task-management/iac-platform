# module: iam-github-oidc

GitHub Actions → AWS **OIDC** trust: one OIDC provider + four scoped `gha-*` roles, so CI
assumes short-lived roles with **zero long-lived AWS keys** in GitHub (DOP-015 / IRD-015).
Authored at **D4**; lives in the `global` root (apply-once).

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `org` | string | — | GitHub org, e.g. `proops-task-management`. |
| `iac_repos` | list(string) | — | Repos allowed to assume the IaC plan/apply roles (usually `iac-platform`). |
| `ci_repos` | list(string) | — | Service repos allowed to read CI secrets from SSM (the 5 services). |
| `ecr_repos` | list(string) | — | Repos allowed to push to ECR (EKS window only, IRD-023). |
| `ssm_ci_path` | string | `/proops/ci/*` | SSM path the ssm-read role may read. |
| `plan_artifacts_bucket_name` | string | — | Plan-artifacts bucket the plan role gets RW on (must match the `storage` module). |
| `iac_apply_actions` | list(string) | — | Service-scoped apply permissions (TODO: tighten to ARNs). |

## Outputs

| Name | Description |
|---|---|
| `oidc_provider_arn` | The GitHub OIDC provider ARN. |
| `gha_iac_plan_role_arn` | ReadOnly + plan-artifacts RW (thin-caller `plan`). |
| `gha_iac_apply_role_arn` | Service-scoped apply (thin-caller `merge`). |
| `gha_ecr_push_role_arn` | ECR auth + push (EKS window). |
| `gha_ssm_read_role_arn` | Read `/proops/ci/*` (CI secrets). |

## The four roles (least-privilege on the identity side)

| Role | Trusts (repos) | Grants |
|---|---|---|
| `gha-iac-plan` | `iac_repos` | `ReadOnlyAccess` + RW on the plan-artifacts bucket |
| `gha-iac-apply` | `iac_repos` | `iac_apply_actions` (service-scoped; tighten to ARNs) |
| `gha-ecr-push` | `ecr_repos` | `ecr:GetAuthorizationToken` + push (EKS window) |
| `gha-ssm-read` | `ci_repos` | `ssm:GetParameter*` on `/proops/ci/*` + `kms:Decrypt` |

## Design notes

- OIDC thumbprint is **derived dynamically** (`tls_certificate` data source) — never hardcoded,
  survives GitHub cert rotation (IRD-013 "no literals").
- Trust `sub` is `StringLike` on `repo:<org>/<repo>:*`; `aud` pinned to `sts.amazonaws.com`.
- `max_session_duration = 3600` on every role.

## Naming exception (why not the 6-part resource pattern)

IAM roles here use **short functional names** (`gha-iac-plan`, …) instead of
`{project}-{env}-{type}-{region}-{purpose}`. IAM is a **global** service (region-less), and these
are org-wide CI identities referenced by name in GitHub Actions variables — a stable functional
name is clearer and is the convention set at D4. Region-scoped resources (SG, EC2, S3) follow the
full 6-part pattern.
