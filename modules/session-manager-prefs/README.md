# module: session-manager-prefs

Owns the **Session Manager preferences document** `SSM-SessionManagerRunShell`, one per
account and region. It is long-lived and account-scoped, so it lives in the `global` root (MIN-83).

## Why it exists

The operator reaches the k3s API only through an SSM port-forward (`scripts/k8s-tunnel.sh`,
ADR-017). Session Manager closes a session after a period with no traffic. With no preferences
document the AWS default is **20 minutes**, so a tunnel left quiet while you read or edit dies,
and the next `kubectl` fails until `k8s-tunnel.sh up` is re-run. This module raises the idle
timeout to the AWS maximum (60) and puts the setting under Terraform, as IRD-016 requires
("Everything AWS is Terraform-owned").

## Things to know

- **The name is fixed by AWS.** Session Manager looks preferences up by exactly
  `SSM-SessionManagerRunShell`. A different name creates a document nothing reads.
- **The scope is the whole account and region.** The same settings govern every session,
  including Ansible's `community.aws.aws_ssm` connection. A longer idle timeout is harmless there.
- **Do not edit Preferences in the console.** Saving there rewrites the whole document. Every
  input is set explicitly here, so such an edit appears as a plan diff on the next PR rather
  than as silent drift.
- **Does it apply to port-forwarding sessions?** The tunnel uses `AWS-StartPortForwardingSession`,
  a different document from this one. MIN-83 AC-3 verifies in a metered window that a tunnel idle
  for 25 minutes stays UP. If it does not, the fallback is a client-side keepalive in
  `k8s-tunnel.sh`.
- **Session-content logging is off** (the AWS default, $0). Session start and end are still
  recorded by CloudTrail (`StartSession` / `TerminateSession`).
- **Pre-existing document:** if `SSM-SessionManagerRunShell` already exists in a fresh account
  (for example, created by a console visit), the create fails. Adopt it with an `import {}` block
  in `envs/global`, then remove the block. On 2026-11-11 the document did not exist in
  `339529820957` / `ap-southeast-1`.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `idle_session_timeout_minutes` | number | — | Minutes with no traffic before a session is closed. Validated as a whole number from 1 to 60. |

## Outputs

| Name | Description |
|---|---|
| `document_name` | `SSM-SessionManagerRunShell`. |
| `idle_session_timeout_minutes` | The configured idle timeout. |
