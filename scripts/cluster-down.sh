#!/usr/bin/env bash
# ===========================================================================
# cluster-down.sh — stop the k3s-dev cluster + print today's cost estimate
# (IRD-016 §daily-ops). Instances STOP (not terminate) — EBS + the k3s state
# persist, so cluster-up.sh brings the same cluster back. The `global`
# guardrails (budgets, zone, buckets) are a different root and stay untouched.
#
# Usage: ./scripts/cluster-down.sh
#   Overrides: PROJECT, REGION, HOURLY_RATE (per-node on-demand $/h)
# ===========================================================================
set -euo pipefail

PROJECT="${PROJECT:-proops-taskmgmt}"
REGION="${REGION:-ap-southeast-1}"
HOURLY_RATE="${HOURLY_RATE:-0.0368}"     # t4g.medium on-demand apse1 (approx), per node
ANSIBLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../ansible" && pwd)"
MARKER="$ANSIBLE_DIR/.artifacts/last-up-epoch"

log()  { printf '\033[1;34m[down]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[down] WARN:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[down] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v aws >/dev/null || die "aws CLI not found"

# Discover instances by tag (same as cluster-up).
IDS="$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Role,Values=k3s-server,k3s-agent" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"
[[ -n "$IDS" ]] || die "no k3s instances found by tag"
NODE_COUNT="$(wc -w <<<"$IDS" | tr -d ' ')"

# Stop (idempotent: stop on an already-stopped instance is a no-op).
log "stopping: $IDS"
aws ec2 stop-instances --region "$REGION" --instance-ids $IDS >/dev/null
aws ec2 wait instance-stopped --region "$REGION" --instance-ids $IDS
log "stopped $NODE_COUNT instance(s)."

# Cost estimate for today's session (compute only; excludes EBS/data transfer).
if [[ -f "$MARKER" ]]; then
  start="$(cat "$MARKER")"; now="$(date +%s)"
  hours="$(awk "BEGIN{printf \"%.2f\", ($now-$start)/3600}")"
  cost="$(awk "BEGIN{printf \"%.2f\", ($now-$start)/3600*$HOURLY_RATE*$NODE_COUNT}")"
  log "session ~${hours}h × ${NODE_COUNT} × \$${HOURLY_RATE}/h ≈ \$${cost} (compute only)."
  rm -f "$MARKER"
else
  warn "no start marker — check AWS Budgets / Cost Explorer for the real figure."
fi
log "guardrails (budgets, Route 53 zone, S3 buckets) remain — only compute is stopped."
