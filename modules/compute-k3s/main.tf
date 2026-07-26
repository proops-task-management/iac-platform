# ===========================================================================
# compute-k3s — 2× amd64 (x86_64) EC2 (server + agent) + node IAM instance
# profile + nightly auto-stop scheduler. No SSH: management is SSM-only. k3s is
# Ansible's job (D10) — user_data only enables SSM + sets hostname.
# amd64 is load-bearing: CI ships linux/amd64-only images (ADR-011), so the
# node arch MUST be amd64 or every pod CrashLoops (exec format error). See ADR-015.
# ===========================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Latest AL2023 x86_64 (full image, NOT the minimal glob — Day 31 lesson: minimal
# lacks packages Ansible/k3s expect). owners=amazon; arch pinned to x86_64 (amd64)
# to match CI's linux/amd64-only images (ADR-011/ADR-015).
data "aws_ami" "al2023_x86_64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  ami_id = var.ami_id != null ? var.ami_id : data.aws_ami.al2023_x86_64.id

  ssm_param_arn = coalesce(
    var.ssm_param_arn_prefix,
    "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/proops/*"
  )

  # Minimal user_data per role (IRD-016): python3 (Ansible), ssm-agent, hostname.
  roles = ["server", "agent"]
  user_data = { for role in local.roles : role => base64encode(<<-EOT
    #!/bin/bash
    set -euo pipefail
    dnf install -y python3
    systemctl enable --now amazon-ssm-agent
    hostnamectl set-hostname ${var.name_prefix}-k3s-${role}
  EOT
  ) }
}

# --------------------------- Node IAM role ----------------------------------
data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name_prefix}-k3s-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

# SSM Session Manager + agent baseline (no SSH).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ESO node-IAM auth (IRD-019): read /proops/* + decrypt the SecureString CMK.
data "aws_iam_policy_document" "node_secrets" {
  statement {
    sid       = "SsmReadProops"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [local.ssm_param_arn]
  }
  statement {
    sid       = "KmsDecryptSecureString"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"] # SSM SecureString default key; scope to a CMK ARN if introduced.
  }

  # Ansible-over-SSM file transfer (P0-5): the community.aws.aws_ssm connection
  # stages its ephemeral module in the plan-artifacts bucket and the INSTANCE
  # pulls/pushes it with THIS role. Without it the connection authenticates but the
  # first transfer fails AccessDenied → no task runs. Scoped to the one bucket.
  statement {
    sid    = "S3AnsibleSsmTransfer"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:GetObjectVersion",
    ]
    resources = ["${var.ssm_transfer_bucket_arn}/*"]
  }
  statement {
    sid       = "S3AnsibleSsmTransferList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [var.ssm_transfer_bucket_arn]
  }
}

resource "aws_iam_role_policy" "node_secrets" {
  name   = "proops-ssm-read"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.node_secrets.json
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.name_prefix}-k3s-node"
  role = aws_iam_role.node.name
}

# --------------------------- Instances --------------------------------------
resource "aws_instance" "server" {
  ami                    = local.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.node.name
  user_data_base64       = local.user_data["server"]

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  tags = {
    # 6-part name (IRD-013); Role stays k3s-server — Ansible inventory filters on it.
    Name = "${var.name_prefix}-ec2-${var.region_code}-server"
    Role = "k3s-server"
  }
}

resource "aws_instance" "agent" {
  ami                    = local.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.node.name
  user_data_base64       = local.user_data["agent"]

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  tags = {
    Name = "${var.name_prefix}-ec2-${var.region_code}-agent"
    Role = "k3s-agent"
  }
}

# --------------------- Nightly auto-stop scheduler --------------------------
# EventBridge Scheduler → ec2:StopInstances on both nodes at 23:00 ICT.
# Co-located here because it needs the instance IDs and must die with the
# cluster (no orphan schedule pointing at dead IDs). Cost guardrail, IRD-016.
data "aws_iam_policy_document" "scheduler_assume" {
  count = var.enable_auto_stop ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  count              = var.enable_auto_stop ? 1 : 0
  name               = "${var.name_prefix}-nightly-stop"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume[0].json
}

data "aws_iam_policy_document" "scheduler_stop" {
  count = var.enable_auto_stop ? 1 : 0
  statement {
    sid       = "StopClusterNodes"
    effect    = "Allow"
    actions   = ["ec2:StopInstances"]
    resources = [aws_instance.server.arn, aws_instance.agent.arn]
  }
}

resource "aws_iam_role_policy" "scheduler_stop" {
  count  = var.enable_auto_stop ? 1 : 0
  name   = "stop-cluster-nodes"
  role   = aws_iam_role.scheduler[0].id
  policy = data.aws_iam_policy_document.scheduler_stop[0].json
}

resource "aws_scheduler_schedule" "nightly_stop" {
  count = var.enable_auto_stop ? 1 : 0
  name  = "${var.name_prefix}-nightly-stop"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = var.stop_cron_expression
  schedule_expression_timezone = var.stop_timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler[0].arn
    input    = jsonencode({ InstanceIds = [aws_instance.server.id, aws_instance.agent.id] })
  }
}
