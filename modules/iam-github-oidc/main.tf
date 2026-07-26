# ===========================================================================
# GitHub -> AWS OIDC: one provider + four scoped gha-* roles.
# Implements IRD-015 §OIDC and the IRD-016 module contract.
# Zero long-lived AWS keys in GitHub (DOP-015 / AC-11-10): CI assumes these
# roles via a short-lived OIDC token.
# ===========================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Derive GitHub's OIDC signing-cert thumbprint dynamically — never hardcode it
# (survives GitHub cert rotation; satisfies IRD-013 "no literals").
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

locals {
  # Subject claims per trust group: repo:<org>/<repo>:*  (any branch/tag/env).
  iac_subs = [for r in var.iac_repos : "repo:${var.org}/${r}:*"]
  ci_subs  = [for r in var.ci_repos : "repo:${var.org}/${r}:*"]
  ecr_subs = [for r in var.ecr_repos : "repo:${var.org}/${r}:*"]

  # ARNs built from live account/region so no account literal is committed.
  ssm_ci_arn       = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_ci_path}"
  plan_bucket_arn  = "arn:aws:s3:::${var.plan_artifacts_bucket_name}"
  plan_objects_arn = "arn:aws:s3:::${var.plan_artifacts_bucket_name}/*"
}

# ---------------------------------------------------------------------------
# Trust policies (one per subject set). aud is pinned to sts.amazonaws.com;
# sub is StringLike on the repo list.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "trust_iac" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.iac_subs
    }
  }
}

data "aws_iam_policy_document" "trust_ci" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.ci_subs
    }
  }
}

data "aws_iam_policy_document" "trust_ecr" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.ecr_subs
    }
  }
}

# ---------------------------------------------------------------------------
# Role 1: gha-iac-plan — ReadOnly + RW on the plan-artifacts bucket.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "gha_iac_plan" {
  name                 = "gha-iac-plan"
  assume_role_policy   = data.aws_iam_policy_document.trust_iac.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "iac_plan_readonly" {
  role       = aws_iam_role.gha_iac_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "iac_plan_bucket" {
  statement {
    sid       = "PlanArtifactsRW"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
    resources = [local.plan_bucket_arn, local.plan_objects_arn]
  }
}

resource "aws_iam_role_policy" "iac_plan_bucket" {
  name   = "plan-artifacts-rw"
  role   = aws_iam_role.gha_iac_plan.id
  policy = data.aws_iam_policy_document.iac_plan_bucket.json
}

# ---------------------------------------------------------------------------
# Role 2: gha-iac-apply — service-scoped now, tighten to ARNs at D9.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "gha_iac_apply" {
  name                 = "gha-iac-apply"
  assume_role_policy   = data.aws_iam_policy_document.trust_iac.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "iac_apply" {
  statement {
    sid       = "ServiceScopedApply"
    effect    = "Allow"
    actions   = var.iac_apply_actions
    resources = ["*"]
    # TODO(D9): replace resources=["*"] with the real root ARNs once the
    # global/k3s-dev modules exist. iam:* here allows role creation (needed to
    # manage the gha-* + instance roles) — add a permissions boundary at D9.
  }
}

resource "aws_iam_role_policy" "iac_apply" {
  name   = "iac-apply-service-scoped"
  role   = aws_iam_role.gha_iac_apply.id
  policy = data.aws_iam_policy_document.iac_apply.json
}

# ---------------------------------------------------------------------------
# Role 3: gha-ecr-push — ECR auth + push (used only in the EKS window, IRD-023).
# ---------------------------------------------------------------------------
resource "aws_iam_role" "gha_ecr_push" {
  name                 = "gha-ecr-push"
  assume_role_policy   = data.aws_iam_policy_document.trust_ecr.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "ecr_push" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # GetAuthorizationToken cannot be resource-scoped (AWS limitation).
  }
  statement {
    sid    = "EcrPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = ["*"] # TODO(IRD-023): scope to the ECR repo ARNs once created in the EKS window.
  }
}

resource "aws_iam_role_policy" "ecr_push" {
  name   = "ecr-push"
  role   = aws_iam_role.gha_ecr_push.id
  policy = data.aws_iam_policy_document.ecr_push.json
}

# ---------------------------------------------------------------------------
# Role 4: gha-ssm-read — read CI secrets under /proops/ci/* only.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "gha_ssm_read" {
  name                 = "gha-ssm-read"
  assume_role_policy   = data.aws_iam_policy_document.trust_ci.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "ssm_read" {
  statement {
    sid       = "SsmCiRead"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [local.ssm_ci_arn]
  }
  statement {
    sid       = "KmsDecryptSecureString"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"] # SSM SecureString default key; TODO: scope to a CMK ARN if one is introduced.
  }
}

resource "aws_iam_role_policy" "ssm_read" {
  name   = "ssm-ci-read"
  role   = aws_iam_role.gha_ssm_read.id
  policy = data.aws_iam_policy_document.ssm_read.json
}
