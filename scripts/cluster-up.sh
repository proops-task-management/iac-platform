#!/usr/bin/env bash
# ===========================================================================
# cluster-up.sh — bring the k3s-dev cluster from STOPPED to a 2-node Ready
# cluster with Argo CD, in one command (IRD-016 §daily-ops, IRD-014 standards).
#
# Sequence: discover instances by tag -> start -> wait SSM online ->
# upsert Route 53 A records to the new public IP + wait for DNS -> ansible-playbook
# site.yml (idempotent; fetches + rewrites kubeconfig) -> gate on 2 nodes Ready.
# DNS BEFORE ANSIBLE is load-bearing (MIN-54): the kubeconfig targets k8s.<domain>, and
# the same playbook run bootstraps Argo CD through it, so the name must already point at
# today's IP. (Before MIN-54 the kubeconfig held the raw IP, so DNS could lag safely.)
# Target: <= 5 minutes from stopped (AC-10-18). The AWS meter is running while up.
#
# Usage: ./scripts/cluster-up.sh
#   Overrides: PROJECT, ENV, REGION, DOMAIN
# ===========================================================================
set -euo pipefail

PROJECT="${PROJECT:-proops-taskmgmt}"
REGION="${REGION:-ap-southeast-1}"
DOMAIN="${DOMAIN:-taskmgmt.dpdns.org}"
# `k8s` is the control-plane endpoint the kubeconfig targets (MIN-54) — it must stay in
# this list and must match `k3s_api_host` in ansible/group_vars/all.yml.
SUBDOMAINS=(app api argocd grafana k8s)
API_HOST="k8s.$DOMAIN"
ANSIBLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../ansible" && pwd)"
ARTIFACTS="$ANSIBLE_DIR/.artifacts"
KUBECONFIG_ARTIFACT="$ARTIFACTS/kubeconfig"
START_TS="$(date +%s)"

log()  { printf '\033[1;34m[up]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[up] WARN:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[up] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v aws >/dev/null            || die "aws CLI not found"
command -v dig >/dev/null            || die "dig not found (bind tools) — needed to confirm DNS before the playbook"
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

# Collect the IDs into an ARRAY so every later use is "${ALL_IDS[@]}" — quoted, and never
# re-split by whatever IFS (or shell) happens to be in effect. This was `ALL_IDS="$A $B"`
# passed unquoted (SC2086, MIN-60): correct only because bash word-splits and IFS was
# untouched. `aws --output text` actually separates with TABs, so a hand-run variant of this
# same call died with InvalidInstanceId during the Phase-3 window — zsh does not word-split
# unquoted expansions at all, and the tab went through as part of one malformed value.
# Splitting ONCE here, at the source, removes the assumption instead of relying on it.
# Indexed arrays only: macOS ships bash 3.2 (no `mapfile`, no `declare -A`).
ALL_IDS=()
while IFS= read -r id; do
  if [[ -n "$id" ]]; then ALL_IDS+=("$id"); fi
done < <(printf '%s\n%s\n' "$SERVER_ID" "$AGENT_ID" | tr '\t' '\n')
[[ ${#ALL_IDS[@]} -ge 2 ]] || die "expected >= 2 instance IDs, got ${#ALL_IDS[@]}"
log "server=$SERVER_ID agent=$AGENT_ID (${#ALL_IDS[@]} instances)"

# 2) Start (idempotent: start on a running instance is a no-op).
mkdir -p "$ARTIFACTS"
log "starting instances…"
aws ec2 start-instances --region "$REGION" --instance-ids "${ALL_IDS[@]}" >/dev/null
date +%s > "$ARTIFACTS/last-up-epoch"     # cost marker for cluster-down.sh
aws ec2 wait instance-running --region "$REGION" --instance-ids "${ALL_IDS[@]}"

# 3) Wait for the SSM agent to report Online (no SSH — SSM is the transport).
#
# ADAPTIVE GATE (MIN-61 / ADR-016). This was `for _ in $(seq 1 60)` = a fixed 300s budget PER NODE,
# and it lost a race with a cold boot in 3 of TSG-022's 4 occurrences — twice with a window that had
# just been widened after the previous loss. Widening is not the fix: the pre-wait loop finally
# MEASURED the range at **1555s cold vs 17s warm on the same two nodes (~90x)**. No constant serves
# that. A first boot runs cloud-init + `dnf install python3` before the agent can even start its
# handshake; a stop->start does none of it, so the distribution is bimodal by nature.
#
# Two changes, per ADR-016:
#   * ONE wall-clock deadline for the WHOLE set, not a budget per node. The old form gave each node
#     its own 300s, so node 2's clock did not start until node 1 was Online — a run could burn ~10
#     minutes and still abort, and "is 300s enough?" was measured against the wrong number.
#   * Report elapsed time on success. That is what produced the 1555/17 figures at all; it is
#     instrumentation, not decoration. Deleting it removes the only thing keeping the ceiling honest.
#
# The InstanceIds filter is load-bearing: `describe-instance-information` retains rows for
# TERMINATED instances, so an unfiltered check passes in seconds against yesterday's destroyed
# cluster (it did, 2026-07-29). Values= takes the current IDs, comma-joined.
SSM_DEADLINE_S="${SSM_DEADLINE_S:-2400}"   # circuit breaker, NOT a prediction: 40min vs a worst
                                           # observed 1555s. A ceiling ~15% over the single worst
                                           # data point is just the next constant queued to lose.
ssm_wait_start="$(date +%s)"
ids_csv="$(IFS=,; echo "${ALL_IDS[*]}")"
want="${#ALL_IDS[@]}"
log "waiting for SSM online (${want} nodes, ceiling ${SSM_DEADLINE_S}s)…"
online=0
last_report=0
while :; do
  # One call for the whole set. `length(...)` counts only Online rows among the CURRENT ids.
  online="$(aws ssm describe-instance-information --region "$REGION" \
    --filters "Key=InstanceIds,Values=${ids_csv}" \
    --query "length(InstanceInformationList[?PingStatus=='Online'])" \
    --output text 2>/dev/null || echo 0)"
  [[ "$online" =~ ^[0-9]+$ ]] || online=0
  elapsed=$(( $(date +%s) - ssm_wait_start ))
  [[ "$online" -ge "$want" ]] && break
  if [[ "$elapsed" -ge "$SSM_DEADLINE_S" ]]; then
    die "SSM: only ${online}/${want} nodes Online after ${elapsed}s (ids: ${ids_csv}). Check \
'aws ssm describe-instance-information --filters Key=InstanceIds,Values=${ids_csv}'; a node stuck \
with healthy 2/2 EC2 status checks can be re-triggered with 'aws ec2 reboot-instances' (TSG-022)."
  fi
  # Progress at least every 30s — a 20-minute cold boot must look like waiting, with a running
  # clock, not like a hang. Without this the operator kills a healthy run.
  if [[ $(( elapsed - last_report )) -ge 30 ]]; then
    log "  …${online}/${want} Online after ${elapsed}s"
    last_report="$elapsed"
  fi
  sleep 10
done
log "SSM online: ${want}/${want} in $(( $(date +%s) - ssm_wait_start ))s"

# 4) Upsert Route 53 A records → the server's (new) public IP (the IP churns each start).
#    THIS MUST RUN BEFORE THE PLAYBOOK (MIN-54). The kubeconfig the k3s-server role writes
#    now targets k8s.<domain> instead of the raw IP, and Play 4 (argocd-bootstrap) uses that
#    kubeconfig in the same run — so the name has to resolve to TODAY's address before
#    Ansible starts, or the bootstrap would talk to yesterday's (dead) IP.
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
CHANGE_ID="$(aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --change-batch "{\"Changes\":[${changes%,}]}" --query 'ChangeInfo.Id' --output text)"

# Route 53 accepts the change before it is live on its nameservers — wait for INSYNC,
# then confirm THIS host actually resolves the new address (the previous record's 60s
# TTL can still be cached locally). Both waits are cheap and prevent a bootstrap that
# fails on stale DNS — the exact failure the reordering above exists to avoid.
log "waiting for the Route 53 change to be INSYNC…"
aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"
# NOTE: braces are load-bearing here. `$PUBLIC_IP…` (unbraced, immediately followed by the
# multi-byte ellipsis) made bash swallow the first byte of U+2026 into the identifier and abort
# under `set -u` with `PUBLIC_IP\xe2: unbound variable`. Brace any expansion that abuts non-ASCII.
log "waiting for ${API_HOST} to resolve → ${PUBLIC_IP}…"
resolved=""
# ADR-016 exemption, deliberate: this constant is DERIVED, not estimated — 120s is twice the 60s
# record TTL set above, which is the actual quantity being waited out. That is the narrow case where
# a fixed timeout is correct, and the ADR requires the derivation to be stated at the site. Do not
# "harmonise" it with the adaptive gates: nothing here is racing a boot.
for _ in $(seq 1 24); do                      # 24×5s = 120s > the 60s record TTL
  resolved="$(dig +short "$API_HOST" A | tail -n1)"
  [[ "$resolved" == "$PUBLIC_IP" ]] && break
  sleep 5
done
[[ "$resolved" == "$PUBLIC_IP" ]] \
  || die "$API_HOST still resolves to '${resolved:-nothing}' (want $PUBLIC_IP) — stale DNS cache; re-run in a minute"

# 5) Configure the cluster (idempotent; the k3s-server role fetches + URL-rewrites
#    the kubeconfig into $KUBECONFIG_ARTIFACT and bootstraps Argo CD).
log "ansible-playbook site.yml…"
( cd "$ANSIBLE_DIR" && ansible-playbook site.yml )

# 6) Readiness gate: all nodes Ready. Adaptive, same contract as the SSM gate (ADR-016) — this was
# a fixed `seq 1 30` (150s) with no derivation behind it. The agent's kubelet registers only after
# k3s installs and the join succeeds, so on a cold boot this races the same slow first boot the SSM
# gate does. Leaving one of two gates in the same file on a guessed constant, right after writing
# the doctrine, is the failure mode this ADR exists to stop.
export KUBECONFIG="$KUBECONFIG_ARTIFACT"
[[ -f "$KUBECONFIG" ]] || die "kubeconfig artifact missing — did the server role run?"
NODES_DEADLINE_S="${NODES_DEADLINE_S:-600}"   # circuit breaker; Ansible has already converged here,
                                              # so this is kubelet registration only — far shorter
                                              # than the SSM gate's cold-boot window.
nodes_wait_start="$(date +%s)"
log "waiting for ${want} nodes Ready (ceiling ${NODES_DEADLINE_S}s)…"
ready=0
last_report=0
while :; do
  ready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')"
  [[ "$ready" =~ ^[0-9]+$ ]] || ready=0
  elapsed=$(( $(date +%s) - nodes_wait_start ))
  [[ "$ready" -ge "$want" ]] && break
  if [[ "$elapsed" -ge "$NODES_DEADLINE_S" ]]; then
    kubectl get nodes || true               # show the real state before dying
    die "only ${ready}/${want} nodes Ready after ${elapsed}s"
  fi
  if [[ $(( elapsed - last_report )) -ge 30 ]]; then
    log "  …${ready}/${want} Ready after ${elapsed}s"
    last_report="$elapsed"
  fi
  sleep 10
done
log "nodes Ready: ${ready}/${want} in $(( $(date +%s) - nodes_wait_start ))s"
kubectl get nodes || die "kubectl get nodes failed"

ELAPSED=$(( $(date +%s) - START_TS ))
log "UP in ${ELAPSED}s · Argo CD in ns 'platform' · endpoints: ${SUBDOMAINS[*]/%/.$DOMAIN}"
log "KUBECONFIG=$KUBECONFIG_ARTIFACT"
warn "meter is RUNNING — run ./scripts/cluster-down.sh at EOD."
