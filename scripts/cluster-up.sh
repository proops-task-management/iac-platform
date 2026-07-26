#!/usr/bin/env bash
# ===========================================================================
# cluster-up.sh — bring the k3s-dev cluster from STOPPED to a 2-node Ready
# cluster with Argo CD, in one command (IRD-016 §daily-ops, IRD-014 standards).
#
# Sequence: discover instances by tag -> start -> wait SSM online ->
# ansible-playbook site.yml (idempotent; fetches + rewrites kubeconfig) ->
# upsert Route 53 A records to the new public IP -> gate on 2 nodes Ready.
# Target: <= 5 minutes from stopped (AC-10-18). The AWS meter is running while up.
#
# Usage: ./scripts/cluster-up.sh
#   Overrides: PROJECT, ENV, REGION, DOMAIN
# ===========================================================================
set -euo pipefail

PROJECT="${PROJECT:-proops-taskmgmt}"
REGION="${REGION:-ap-southeast-1}"
DOMAIN="${DOMAIN:-proops-taskmgmt.dpdns.org}"
SUBDOMAINS=(app api argocd grafana)
ANSIBLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../ansible" && pwd)"
ARTIFACTS="$ANSIBLE_DIR/.artifacts"
KUBECONFIG_ARTIFACT="$ARTIFACTS/kubeconfig"
START_TS="$(date +%s)"

log()  { printf '\033[1;34m[up]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[up] WARN:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[up] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v aws >/dev/null            || die "aws CLI not found"
command -v ansible-playbook >/dev/null || die "ansible-playbook not found (install collections: ansible-galaxy collection install -r ansible/requirements.yml)"

# 1) Discover instance IDs by tag — same source of truth as the Ansible inventory.
ids_by_role() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Role,Values=$1" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}
SERVER_ID="$(ids_by_role k3s-server)"
AGENT_ID="$(ids_by_role k3s-agent)"
[[ -n "$SERVER_ID" && -n "$AGENT_ID" ]] || die "instances not found by tag — is envs/k3s-dev applied?"
ALL_IDS="$SERVER_ID $AGENT_ID"
log "server=$SERVER_ID agent=$AGENT_ID"

# 2) Start (idempotent: start on a running instance is a no-op).
mkdir -p "$ARTIFACTS"
log "starting instances…"
aws ec2 start-instances --region "$REGION" --instance-ids $ALL_IDS >/dev/null
date +%s > "$ARTIFACTS/last-up-epoch"     # cost marker for cluster-down.sh
aws ec2 wait instance-running --region "$REGION" --instance-ids $ALL_IDS

# 3) Wait for the SSM agent to report Online (no SSH — SSM is the transport).
# 60×5s = 300s: a cold first boot (right after apply, cloud-init + dnf still running)
# registers slower than a warm stop→start; 180s was too tight on a fresh rebuild (TSG-022).
log "waiting for SSM online…"
for id in $ALL_IDS; do
  status=""
  for _ in $(seq 1 60); do
    status="$(aws ssm describe-instance-information --region "$REGION" \
      --filters "Key=InstanceIds,Values=$id" \
      --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)"
    [[ "$status" == "Online" ]] && break
    sleep 5
  done
  [[ "$status" == "Online" ]] || die "SSM never came Online for $id"
done

# 4) Configure the cluster (idempotent; the k3s-server role fetches + URL-rewrites
#    the kubeconfig into $KUBECONFIG_ARTIFACT and bootstraps Argo CD).
log "ansible-playbook site.yml…"
( cd "$ANSIBLE_DIR" && ansible-playbook site.yml )

# 5) Upsert Route 53 A records → the server's (new) public IP (IP churns each start).
PUBLIC_IP="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$SERVER_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
[[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "None" ]] || die "server has no public IP"
ZONE_ID="$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN." \
  --query 'HostedZones[0].Id' --output text | sed 's#/hostedzone/##')"
[[ -n "$ZONE_ID" && "$ZONE_ID" != "None" ]] || die "hosted zone for $DOMAIN not found"
log "upserting A records → $PUBLIC_IP (zone $ZONE_ID)…"
changes=""
for sub in "${SUBDOMAINS[@]}"; do
  changes+="{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$sub.$DOMAIN\",\"Type\":\"A\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"$PUBLIC_IP\"}]}},"
done
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --change-batch "{\"Changes\":[${changes%,}]}" >/dev/null

# 6) Readiness gate: 2 nodes Ready.
export KUBECONFIG="$KUBECONFIG_ARTIFACT"
[[ -f "$KUBECONFIG" ]] || die "kubeconfig artifact missing — did the server role run?"
log "waiting for 2 nodes Ready…"
ready=0
for _ in $(seq 1 30); do
  ready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')"
  [[ "$ready" -ge 2 ]] && break
  sleep 5
done
kubectl get nodes || die "kubectl get nodes failed"
[[ "$ready" -ge 2 ]] || die "only $ready/2 nodes Ready"

ELAPSED=$(( $(date +%s) - START_TS ))
log "UP in ${ELAPSED}s · Argo CD in ns 'platform' · endpoints: ${SUBDOMAINS[*]/%/.$DOMAIN}"
log "KUBECONFIG=$KUBECONFIG_ARTIFACT"
warn "meter is RUNNING — run ./scripts/cluster-down.sh at EOD."
