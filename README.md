# iac-platform

Terraform + Ansible + daily-ops for the ProOps production platform.
Governed by [DOP-010](../docs/dops/DOP-010-iac-automation.md) and
[IRD-016](../docs/irds/platform/IRD-016-iac-platform.md); module/tagging
standards per [IRD-013](../docs/irds/platform/IRD-013-terraform-module-standards.md).

## Layout

```
modules/            reusable Terraform modules (DRY)
  iam-github-oidc/  GitHub->AWS OIDC provider + gha-* roles   [D4]
  network/          default-VPC lookup + node Security Group  [D9]
  compute-k3s/      2× amd64 EC2 + instance profile + auto-stop [D9]
  dns/              Route 53 hosted zone (zone only)          [D9]
  storage/          db-backups + plan-artifacts S3 buckets    [D9]
  cost-guardrails/  AWS Budgets $30/mo + $180 total           [D9]
envs/               Terraform roots, grouped by LIFECYCLE (not by app env)
  global/           long-lived, apply-once: OIDC + dns zone + buckets + budgets [D4/D9]
  k3s-dev/          the daily k3s cluster: network + compute  [D9]
  eks-window/       time-boxed EKS window (IRD-023)            [Phase 9]
scripts/            daily-ops bash suite
  seed-ssm.sh       one-time SSM secret seeding (IRD-019)     [D9]
```

> **DNS A records** (`app/api/argocd/grafana`) are NOT Terraform-managed — the node IP
> changes on every `cluster-up`, so `cluster-up.sh` (D10) upserts them into the `global`
> zone. Terraform owns the zone only, to avoid daily drift.

> App environments **dev / staging / prod** are Kubernetes namespaces + Kustomize
> overlays in the `deploy` repo (GitOps) — not Terraform roots (ADR-003).

## Conventions

- Terraform `>= 1.7, < 2.0`; AWS provider `~> 6.0` (6.x tags S3 at create — this
  account denies untagged `s3:CreateBucket`; see IRD-013/IRD-016).
- Remote state: S3 `proops-taskmgmt-tfstate-apse1-339529820957` +
  DynamoDB `proops-taskmgmt-tflock-apse1`, one key per root.
- No long-lived AWS keys anywhere — CI assumes the `gha-*` OIDC roles.

## Plan each root (D9 — authoring only, still $0)

```bash
# global: OIDC (D4) + dns zone + 2 buckets + 2 budgets
cd envs/global
terraform init
terraform fmt -recursive -check && terraform validate
terraform plan          # NO apply — that's D10

# k3s-dev: node SG + 2 EC2 + instance profile + nightly auto-stop
cd ../k3s-dev
terraform init
terraform fmt -recursive -check && terraform validate
terraform plan          # admin_cidr auto-detects your public IP; NO apply
```

Seed secrets once (IRD-019), never via Terraform:

```bash
cp scripts/seed-ssm.env.example ~/.proops-secrets.env   # fill DISCORD_WEBHOOK_URL + SONAR_TOKEN
chmod 600 ~/.proops-secrets.env
./scripts/seed-ssm.sh                                    # seeds 10 SSM params + prints inventory diff
```
