#!/usr/bin/env bash
# ===========================================================================
# cluster-up.sh — bring the k3s-dev cluster from STOPPED to a 2-node Ready
# cluster with Argo CD, in one command (IRD-016 §daily-ops, IRD-014 standards).
#
# Sequence: discover instances by tag -> start -> wait SSM online ->
# upsert Route 53 A records (app ingress) -> ansible-playbook --tags nodes ->
# SSM tunnel to the API + wait /readyz -> ansible-playbook --tags bootstrap (Argo CD)
# -> gate on 2 nodes Ready.
# THE TUNNEL BETWEEN THE TWO PLAYBOOK RUNS is load-bearing (MIN-50 / ADR-017): the k3s
# API has no public ingress, the kubeconfig targets 127.0.0.1, and Play 4 bootstraps
# Argo CD through it - so the tunnel must exist, and the API must answer through it,
# before Play 4 starts. It can only be proven after Play 2 has installed k3s.
# DNS is no longer on the API path at all (it was, MIN-54 → MIN-50): the A records
# serve app ingress only, so nothing in this run waits for them to resolve.
# Target: <= 5 minutes from stopped (AC-10-18). The AWS meter is running while up.
#
# Usage: ./scripts/cluster-up.sh
#   Overrides: PROJECT, ENV, REGION, DOMAIN (+ k8s-tunnel.sh's K3S_API_LOCAL_PORT etc.)
# ===========================================================================
set -euo pipefail

PROJECT="${PROJECT:-proops-taskmgmt}"
REGION="${REGION:-ap-southeast-1}"
DOMAIN="${DOMAIN:-taskmgmt.dpdns.org}"
# App-ingress names only. `k8s` was removed with MIN-50: the API is not served on a name.
# Keep in lockstep with cluster-down.sh's SUBDOMAINS: it deletes exactly these names (MIN-84).
SUBDOMAINS=(app api argocd grafana)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUNNEL="$SCRIPT_DIR/k8s-tunnel.sh"
ANSIBLE_DIR="$(cd "$SCRIPT_DIR/../ansible" && pwd)"
ARTIFACTS="$ANSIBLE_DIR/.artifacts"
KUBECONFIG_ARTIFACT="$ARTIFACTS/kubeconfig"
START_TS="$(date +%s)"

log()  { printf '\033[1;34m[up]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[up] WARN:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[up] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v aws >/dev/null            || die "aws CLI not found"
command -v kubectl >/dev/null        || die "kubectl not found — needed for the API readiness + nodes-Ready gates"
command -v session-manager-plugin >/dev/null \
  || die "session-manager-plugin not found — the k3s API is reachable only through an SSM tunnel (MIN-50); TSG-021 covers the install path"
command -v ansible-playbook >/dev/null || die "ansible-playbook not found (install collections: ansible-galaxy collection install -r ansible/requirements.yml)"
[[ -x "$TUNNEL" ]]                   || die "$TUNNEL missing or not executable"

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
#    These serve APP INGRESS only (Traefik 80/443). Since MIN-50 nothing in this run
#    consumes them — the API goes through the SSM tunnel — so we wait for INSYNC (cheap,
#    proves Route 53 accepted the change) but no longer for local resolution.
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

# Route 53 accepts the change before it is live on its nameservers — wait for INSYNC.
# (The 120s local-resolve gate that followed was removed with MIN-50: it existed only because
# the same run used k8s.<domain> as the kubeconfig address. That dependency no longer exists.)
log "waiting for the Route 53 change to be INSYNC…"
aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"
# Remember WHICH IP the records point at (MIN-84). cluster-down.sh deletes a record only when its
# value equals this cluster's IP, and a stopped server has no public IP left to compare against
# (e.g. after the 23:00 auto-stop), so the value must be recorded while it is still known.
printf '%s\n' "$PUBLIC_IP" > "$ARTIFACTS/last-up-ip"

# 5) Configure the nodes (Plays 1-3: OS baseline, k3s server, k3s agent). Idempotent; the
#    k3s-server role writes the kubeconfig artifact targeting 127.0.0.1 (the tunnel's end).
log "ansible-playbook site.yml --tags nodes…"
( cd "$ANSIBLE_DIR" && ansible-playbook site.yml --tags nodes )

# 6) Open the SSM tunnel to the API and wait until the API answers THROUGH it (MIN-50).
#    `ready` polls /readyz to a deadline (ADR-016) and re-establishes the session if SSM drops
#    it — the first run after MIN-50 restarts k3s once (tls-san changed), which can do that.
#    The tunnel is left running for the operator's kubectl; cluster-down.sh closes it.
"$TUNNEL" ready

# 7) Bootstrap Argo CD (Play 4, localhost) through the tunnel.
log "ansible-playbook site.yml --tags bootstrap…"
( cd "$ANSIBLE_DIR" && ansible-playbook site.yml --tags bootstrap )

# 8) Readiness gate: all nodes Ready. Adaptive, same contract as the SSM gate (ADR-016) — this was
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
log "KUBECONFIG=$KUBECONFIG_ARTIFACT (API via SSM tunnel on 127.0.0.1)"
log "tunnel: $TUNNEL status — if kubectl stops answering (SSM closes idle sessions), run: $TUNNEL up"
warn "meter is RUNNING — run ./scripts/cluster-down.sh at EOD."
