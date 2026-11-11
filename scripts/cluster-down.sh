#!/usr/bin/env bash
# ===========================================================================
# cluster-down.sh — stop the k3s-dev cluster, remove its app A records, and
# print today's cost estimate (IRD-016 §daily-ops). Instances STOP (not
# terminate) — EBS + the k3s state persist, so cluster-up.sh brings the same
# cluster back. The `global` guardrails (budgets, zone, buckets) are a
# different root and stay untouched.
#
# DNS contract (MIN-84): the app A records exist ONLY while the cluster is up.
# A stopped node has no public IP — AWS hands it back to the pool — so a record
# left behind points at an address another AWS customer may receive, which is a
# subdomain takeover (they serve content and can pass an HTTP-01 ACME challenge
# on our names). A record is deleted only when its value EQUALS this cluster's
# IP: the name alone is not proof of ownership (D23's DNS cutover repoints the
# same names at EKS, and a k3s cluster-down must not delete those).
#
# Before `terraform destroy` of k3s-dev, run this script FIRST: it hard-fails
# once the instances are gone, so the records could no longer be cleaned here.
#
# Usage: ./scripts/cluster-down.sh
#   Overrides: PROJECT, REGION, DOMAIN, HOURLY_RATE (per-node on-demand $/h)
# ===========================================================================
set -euo pipefail

PROJECT="${PROJECT:-proops-taskmgmt}"
REGION="${REGION:-ap-southeast-1}"
DOMAIN="${DOMAIN:-taskmgmt.dpdns.org}"
# Keep in lockstep with cluster-up.sh's SUBDOMAINS: these are the names it upserts.
SUBDOMAINS=(app api argocd grafana)
HOURLY_RATE="${HOURLY_RATE:-0.0368}"     # t4g.medium on-demand apse1 (approx), per node
ANSIBLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../ansible" && pwd)"
MARKER="$ANSIBLE_DIR/.artifacts/last-up-epoch"
IP_MARKER="$ANSIBLE_DIR/.artifacts/last-up-ip"   # written by cluster-up.sh (MIN-84)

log()  { printf '\033[1;34m[down]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[down] WARN:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[down] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v aws >/dev/null || die "aws CLI not found"

# Close the SSM tunnel to the k3s API FIRST (MIN-50): once the server stops, the session
# dies upstream but the local listener + pid file would linger as an orphan that the next
# `k8s-tunnel.sh up` must reconcile. Idempotent — a no-op when no tunnel is running.
TUNNEL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/k8s-tunnel.sh"
if [[ -x "$TUNNEL" ]]; then
  "$TUNNEL" down
else
  warn "$TUNNEL not executable — skipping tunnel cleanup"
fi

# Discover instances by tag (same as cluster-up).
# Read into an ARRAY, not a space-joined string. `aws --output text` separates with TABs, so
# `--instance-ids $IDS` (unquoted, SC2086) only worked because bash word-splits on the default
# IFS — an assumption that broke on a hand-run variant during the Phase-3 window (MIN-60).
# Normalise tabs to newlines and split once, here. Indexed arrays only (macOS bash 3.2).
IDS=()
while IFS= read -r id; do
  if [[ -n "$id" ]]; then IDS+=("$id"); fi
done < <(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Role,Values=k3s-server,k3s-agent" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' '\n')
NODE_COUNT="${#IDS[@]}"
[[ "$NODE_COUNT" -gt 0 ]] || die "no k3s instances found by tag"

# Resolve THIS cluster's IP BEFORE the stop (MIN-84) — a stopped instance has no public IP.
# Order of trust: the server's live public IP, then the marker cluster-up.sh wrote. With
# neither (e.g. the 23:00 auto-stop already ran AND the marker is gone), CLUSTER_IP stays
# empty and the cleanup deletes nothing: fail-safe, never "delete by name and hope".
LIVE_IP="$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Role,Values=k3s-server" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
MARKER_IP=""
if [[ -f "$IP_MARKER" ]]; then MARKER_IP="$(tr -d '[:space:]' < "$IP_MARKER")"; fi
is_ipv4() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }
CLUSTER_IP=""
if is_ipv4 "$LIVE_IP"; then
  CLUSTER_IP="$LIVE_IP"
  if [[ -n "$MARKER_IP" && "$MARKER_IP" != "$LIVE_IP" ]]; then
    warn "marker IP $MARKER_IP differs from the live server IP $LIVE_IP — trusting the live IP"
  fi
elif is_ipv4 "$MARKER_IP"; then
  CLUSTER_IP="$MARKER_IP"
  log "server has no live public IP — using the IP cluster-up.sh recorded: $CLUSTER_IP"
fi

# Stop (idempotent: stop on an already-stopped instance is a no-op).
# Stop runs BEFORE the DNS cleanup on purpose: cost control must never be blocked by a
# Route 53 error. The cost is a ~60 s window where the records outlive the IP, against the
# hours-to-days window this script used to leave behind.
log "stopping: ${IDS[*]}"
aws ec2 stop-instances --region "$REGION" --instance-ids "${IDS[@]}" >/dev/null
aws ec2 wait instance-stopped --region "$REGION" --instance-ids "${IDS[@]}"
log "stopped $NODE_COUNT instance(s)."

# Delete the app A records that point at this cluster's IP (MIN-84). Idempotent: absent
# records are a no-op and, with nothing to delete, no Route 53 change is submitted at all.
# Route 53 DELETE must match the record set exactly (name, type, TTL, values), so each
# record is READ first and deleted with the values it actually has.
cleanup_dns() {
  local ip="$1" zone_id sub fqdn row ttl values changes="" kept=0 change_id
  zone_id="$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN." \
    --query "HostedZones[?Name=='$DOMAIN.'] | [0].Id" --output text | sed 's#/hostedzone/##')"
  if [[ -z "$zone_id" || "$zone_id" == "None" ]]; then
    warn "hosted zone for $DOMAIN not found — DNS cleanup skipped"
    return 0
  fi
  for sub in "${SUBDOMAINS[@]}"; do
    fqdn="$sub.$DOMAIN."
    # One record per call, starting at its own name: the [?Name..] filter turns "the next
    # record in the zone" into None when ours is absent. An ALIAS record has no TTL and no
    # ResourceRecords — the `|| []` keeps join() from erroring, and it is never "ours".
    row="$(aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" \
      --start-record-name "$fqdn" --start-record-type A --max-items 1 \
      --query "ResourceRecordSets[?Name=='$fqdn' && Type=='A'] | [0].[TTL, join(',', ResourceRecords[].Value || \`[]\`)]" \
      --output text)"
    if [[ -z "$row" || "$row" == "None" ]]; then
      log "  $fqdn A — absent"
      continue
    fi
    IFS=$'\t' read -r ttl values <<< "$row"
    if [[ -n "$ip" && "$ttl" =~ ^[0-9]+$ && "$values" == "$ip" ]]; then
      log "  $fqdn A -> $values — this cluster's IP, deleting"
      changes+="{\"Action\":\"DELETE\",\"ResourceRecordSet\":{\"Name\":\"$fqdn\",\"Type\":\"A\",\"TTL\":$ttl,\"ResourceRecords\":[{\"Value\":\"$ip\"}]}},"
    else
      warn "$fqdn A -> ${values:-<alias>} is not this cluster's IP (${ip:-unknown}) — left in place"
      kept=$((kept + 1))
    fi
  done
  if [[ -z "$changes" ]]; then
    log "DNS: nothing to delete — no Route 53 change submitted."
  else
    change_id="$(aws route53 change-resource-record-sets --hosted-zone-id "$zone_id" \
      --change-batch "{\"Changes\":[${changes%,}]}" --query 'ChangeInfo.Id' --output text)"
    aws route53 wait resource-record-sets-changed --id "$change_id"
    log "DNS: owned A records deleted (change $change_id, INSYNC)."
  fi
  if [[ "$kept" -gt 0 && -z "$ip" ]]; then
    warn "this cluster's IP is unknown (no live IP, no valid $IP_MARKER). If the records above"
    warn "are dangling, inspect and delete them by hand:"
    warn "  aws route53 list-resource-record-sets --hosted-zone-id $zone_id --query \"ResourceRecordSets[?Type=='A']\""
  fi
}
cleanup_dns "$CLUSTER_IP"

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
log "guardrails (budgets, Route 53 zone, S3 buckets) remain — compute is stopped, app A records removed."
