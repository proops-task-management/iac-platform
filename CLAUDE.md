# iac-platform - Claude Agent

## Read these first
- DOP-010 (IaC + Automation, primary): https://app.notion.com/p/365354ccbdbf81d08d61da27c3a1c999
- IRD-016 (iac-platform contract): https://app.notion.com/p/397354ccbdbf81128069d163d6970943
- IRD-019 (secrets: ESO + SSM): https://app.notion.com/p/397354ccbdbf815298c1e88fd8dee79b
- IRD-013 (Terraform module standards): `../docs/irds/platform/IRD-013-terraform-module-standards.md`
- IRD-014 (automation-tooling doctrine — tool boundaries): `../docs/irds/platform/IRD-014-automation-tooling-doctrine.md`
- IRD-015 (OIDC roles for CI): `../docs/irds/platform/IRD-015-cicd-platform-v6.md`
- ADR-003 (roots-by-lifecycle; app envs = k8s namespaces, not TF roots) — repo-only, `../docs/adr/`

> DOPs define **what** success is; IRDs define **how**; ADRs record **why**. Implement from these
> — not from general knowledge. Where an older IRD (001–013) conflicts with IRD-014+, the newer wins.

---

## Scope
This repo is the **Terraform + Ansible + daily-ops** layer that provisions and operates the AWS
runtime for the ProOps platform. Implement only what IRD-016 / IRD-013 / IRD-019 define.

**This repo owns:**
- All AWS infrastructure as Terraform (network, EC2 k3s nodes, IAM/OIDC, Route 53 zone, S3, budgets).
- The Ansible layer (over SSM, no SSH) that installs k3s + bootstraps Argo CD.
- The daily-ops bash suite (`cluster-up/down`, `seed-ssm`, `smoke`).
- The IaC pipelines (`iac-pr-opened/merged/manual`, `review-plan`).

**This repo does NOT own:**
- Application manifests / Helm / Kustomize / Argo CD `Application`s → the **`deploy`** repo (IRD-017).
- Service source code, Dockerfiles, or app CI → the 5 service repos + **`cicd-platform`**.
- App environments **dev / staging / prod** — those are **k8s namespaces + Kustomize overlays** in
  `deploy` (GitOps), **NOT** Terraform roots (ADR-003).
- Secret **values** — those live only in SSM, seeded by `scripts/seed-ssm.sh` (IRD-019).

---

## Ground state (facts an agent must not re-derive)
- **Account:** `339529820957` · **Region:** `ap-southeast-1` (`apse1`).
- **Terraform** `>= 1.7, < 2.0` · **AWS provider** `~> 6.0` (6.x tags S3 at create — this account
  denies untagged `s3:CreateBucket`; 5.x tags only post-create → rejected).
- **Remote state:** S3 `proops-taskmgmt-tfstate-apse1-339529820957` + DynamoDB lock
  `proops-taskmgmt-tflock-apse1`, **one key per root**. The backend already exists — `init` directly.
- **No long-lived AWS keys** anywhere — CI assumes the `gha-*` OIDC roles; nodes use their instance role.
- **No SSH** — node access is SSM-only; no key pairs exist by design.

---

## Repository layout

```text
modules/            reusable Terraform modules (named by CONCERN, not by primitive)
  iam-github-oidc/  GitHub->AWS OIDC provider + 4 gha-* roles      [D4]
  network/          default-VPC lookup + node Security Group        [D9]
  compute-k3s/      2x amd64 EC2 + instance profile + auto-stop      [D9]
  dns/              Route 53 hosted zone (zone only)                 [D9]
  storage/          db-backups + plan-artifacts S3 buckets           [D9]
  cost-guardrails/  AWS Budgets $30/mo + $180 total                  [D9]
envs/               Terraform ROOTS, grouped by LIFECYCLE (not app env)
  global/           long-lived apply-once: OIDC + dns zone + buckets + budgets
  k3s-dev/          the daily k3s cluster: network + compute
  eks-window/       time-boxed EKS window (IRD-023)                  [Phase 9]
ansible/            roles over SSM: os-baseline, k3s-server/agent, argocd-bootstrap [D10]
scripts/            daily-ops bash suite (IRD-014 standards)
  seed-ssm.sh       one-time SSM secret seeding (IRD-019)            [D9]
.github/workflows/  iac pipelines (thin callers of reusable-iac.yml@v6) [D11]
```

---

## Design rules (module + root organization)

- **Modules are named by CONCERN, not by AWS primitive.** `compute-k3s` bundles EC2 + IAM +
  instance-profile + user_data + scheduler — never call it `ec2`. A 1:1 wrapper of one resource
  that just re-exposes its knobs is the **thin-wrapper anti-pattern** — don't create it.
- **Reuse lives in tiers:** provider primitives → **versioned registry/shared modules**
  (`terraform-aws-modules/vpc`,`/eks` — consume, don't hand-write) → **project composition modules**
  (this repo, intentionally project-specific) → **roots**. Cross-project reuse = the registry tier;
  cross-env reuse = one module called with different tfvars.
- **Isolation comes from separate ROOTS (separate state), not from more sub-modules.**
- **Roots group by lifecycle** (`global` apply-once · `k3s-dev` daily · `eks-window` time-boxed),
  never by app-environment (ADR-003).
- Every module has `main/variables/outputs/versions.tf` **+ a `README.md`** (inputs/outputs tables).
- Every module has **≥1 output**. Every variable has `type` + `description`; secrets `sensitive = true`.

---

## Naming + tagging (IRD-013)

- **Region-scoped resources** (SG, EC2, S3): `{project}-{env}-{type}-{region}-{purpose}` —
  e.g. `proops-taskmgmt-dev-ec2-apse1-server`, `proops-taskmgmt-global-s3-apse1-dbbackups`.
- **IAM roles**: short functional names (global service, region-less) — e.g. `gha-iac-plan`.
- **6 mandatory `default_tags`** on the provider (every resource inherits): `Owner`, `Email`,
  `Project=proops-taskmgmt`, `Environment`, `ManagedBy=terraform`, `CostCenter`.
- Instance `Role` tag (`k3s-server`/`k3s-agent`) is load-bearing — Ansible inventory filters on it.

---

## NEVER
- Put any secret **value** into Terraform (tfstate/variables/outputs) — SSM only, via `seed-ssm.sh`.
- Use local state — remote S3 backend is mandatory, one key per root.
- Run `kubectl create secret` — Kubernetes Secrets exist only as ESO-materialized objects (IRD-019).
- Open **port 22** or create an SSH key pair — management is SSM-only.
- Open **6443** to `0.0.0.0/0` — only to `admin_cidr` (see MIN-50 for the production upgrade).
- Put literal values in `main.tf` — all inputs come from `terraform.tfvars` (+ committed `.example`).
- Use `force_destroy = true` on the backups bucket or any stateful resource without a `# why:` comment.
- Hardcode the account id / region / thumbprints — derive from `data` sources.
- `terraform apply` from a laptop against a metered root without the operator confirming the meter.
- Auto-run any stateful command (terraform/aws/ansible/kubectl) — present it, ask, wait (repo CLAUDE.md rule).
- Name a module after a resource type (`ec2`,`s3`) or a root after an app-env (`dev` without the cluster flavor).
- Manage the daily DNS **A records** in Terraform — `cluster-up.sh` upserts them (node IP changes daily).

---

## Technology Stack

| Component | Choice | Why |
| --- | --- | --- |
| IaC | Terraform `>= 1.7,<2.0` | Declarative AWS provisioning; remote state |
| Provider | `hashicorp/aws ~> 6.0` | Tags S3 at create (account guardrail); one version per repo |
| Config mgmt | Ansible (over `community.aws.aws_ssm`) | Install k3s + bootstrap Argo CD, no SSH |
| Cluster | k3s (Traefik ON) on 2× `t3.medium` amd64 | amd64 to match CI's linux/amd64-only images (ADR-011/ADR-015) |
| Secrets | SSM Parameter Store (SecureString) + ESO | Single source of truth; node-IAM auth |
| Public-IP detect | `hashicorp/http` (checkip.amazonaws.com) | Hybrid `admin_cidr` on laptop applies |
| Daily-ops | Bash (IRD-014 standards) | Idempotent, cost-printing, no orphans |
| CI | GitHub Actions (thin callers of `reusable-iac.yml@v6`) | OIDC roles, no stored keys |

---

## State management
- Backend already exists in `339529820957` — `terraform init` runs directly (no bootstrap).
- One state key per root: `global/`, `k3s-dev/`, `eks-window/terraform.tfstate`.
- `backend.tf` cannot use variables — the bucket/key/region literals are required by Terraform.
- Never share state across roots; never edit tfstate by hand.

---

## Secrets (IRD-019)
- Single source of truth for every value = **SSM SecureString**. Terraform creates IAM/policies,
  **never parameters**.
- Seed once with `scripts/seed-ssm.sh` (reads gitignored `~/.proops-secrets.env`; generates
  DB/Redis/Grafana passwords + RSA keypair; `put-parameter --type SecureString --overwrite`).
- Path convention `/proops/<env>/<scope>/<key>` (env ∈ dev|staging|prod|global|ci).
- `k3s/token` + `k3s/server-ip` are written by **Ansible** (D10), not `seed-ssm.sh`.
- Values never appear in git, tfstate, CI logs, Notion, or chat.

---

## Cost discipline
- `$0` through D8; Phase 3 (D10 apply) starts the meter (~$1/day). Budgets: `$30/mo` + `$180` total.
- Nightly EC2 auto-stop at **23:00 ICT** (EventBridge Scheduler in `compute-k3s`).
- `cluster-down.sh` stops instances + prints the day's estimate. `terraform destroy` of `k3s-dev`
  never removes the `global` guardrails (budgets, zone, buckets).
- Confirm with the operator before any `apply` on a metered root.

---

## Verify workflow (authoring is $0 — apply is not)

```bash
# one-word local gate via go-task (Taskfile.yml, mirrors cicd-platform)
task hooks     # ONCE per clone — installs .git/hooks/pre-commit; until then commits are NOT linted
task check     # fmt-check + validate (both roots) + every pre-commit hook. All $0, no AWS calls.

# static (read-only, $0) — what `task check` wraps
terraform -chdir=envs/<root> init -backend=false && terraform -chdir=envs/<root> validate
terraform fmt -recursive -check    # + tflint + gitleaks in CI / pre-commit

# plan (needs AWS SSO; read-only, $0 — NEVER apply here)
terraform -chdir=envs/<root> init && terraform -chdir=envs/<root> plan
```
A clean plan ends `Plan: N to add, 0 to change, 0 to destroy`, shows the 6 `default_tags` on every
resource, and has no hardcoded literals. **`apply` happens via the IaC pipeline (merge to main) or a
confirmed manual run — not casually from a laptop** (IRD-013).

---

## Ansible layer (D10) — quick contract
- Connection `community.aws.aws_ssm` (S3 transfer = plan-artifacts bucket). **No SSH keys anywhere.**
- Inventory `aws_ec2` filtered on `tag:Project=proops-taskmgmt` + running; groups from `tag:Role`.
- Roles: `os-baseline`, `k3s-server` (writes token + server-ip to SSM), `k3s-agent` (joins via SSM),
  `argocd-bootstrap` (helm install Argo CD in ns `platform` + app-of-apps → `deploy`).
- Every role passes a second-run `changed=0` check.

---

## Definition of done (any change here)
- `fmt`/`validate`/`tflint` pass; `plan` reviewed; module `README` updated; the 6 tags present.
- No secret value in tfstate/git/CI; no literal in `main.tf`.
- IRD-016 audit-log row added for any contract change (doc-sync); Linear issue moved via the skills.
