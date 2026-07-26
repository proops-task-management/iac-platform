# module: compute-k3s

2× amd64 (x86_64) EC2 (`k3s-server` + `k3s-agent`), the node **IAM instance profile**, and the
**nightly auto-stop** scheduler. Management is **SSM-only — no SSH, no key pairs**. k3s is
installed by **Ansible (D10)**; `user_data` only installs python3, enables `amazon-ssm-agent`,
and sets the hostname (IRD-014/IRD-016).

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | string | — | e.g. `proops-taskmgmt-dev`. |
| `region_code` | string | `apse1` | Region segment of the 6-part name. |
| `subnet_id` | string | — | Both nodes, same AZ (flannel). |
| `security_group_id` | string | — | From the network module. |
| `instance_type` | string | `t3.medium` | amd64 (x86_64), 2 vCPU / 4 GiB. MUST be amd64 to match CI images (ADR-011/ADR-015). |
| `ami_id` | string | `null` | `null` → latest AL2023 x86_64 (`al2023-ami-2023.*`). |
| `root_volume_gb` | number | `20` | gp3, encrypted. |
| `ssm_param_arn_prefix` | string | `null` | `null` → `/proops/*` this account/region. |
| `ssm_transfer_bucket_arn` | string | — | Plan-artifacts bucket ARN; node role gets scoped `s3:*` for the `aws_ssm` Ansible file transfer (P0-5). |
| `enable_auto_stop` | bool | `true` | Nightly EC2 stop scheduler. |
| `stop_cron_expression` | string | `cron(0 16 * * ? *)` | 16:00 UTC = 23:00 ICT. |
| `stop_timezone` | string | `UTC` | Timezone for the cron. |

## Outputs

`server_instance_id`, `agent_instance_id`, `server_public_ip`, `server_private_ip`,
`agent_public_ip`, `node_role_arn`, `node_role_name`, `ami_id`.

## Node IAM (ESO node-IAM auth, IRD-019)

- `AmazonSSMManagedInstanceCore` (Session Manager, agent).
- Inline: `ssm:GetParameter*` on `/proops/*` + `kms:Decrypt` — so ESO reads secrets using the
  node role, no stored credentials.

## Security notes

- **IMDSv2 required** (`http_tokens = "required"`) — blocks SSRF-to-credentials.
- **No SSH ingress** (see network module) and no key pair set.
- Nightly auto-stop role can only `ec2:StopInstances` on **these two instances** (ARN-scoped).
