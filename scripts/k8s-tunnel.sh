#!/usr/bin/env bash
# ===========================================================================
# k8s-tunnel.sh - own the lifecycle of the SSM port-forward to the k3s API
# (MIN-50 / ADR-017, IRD-016 §daily-ops, IRD-014 daily-ops standards).
#
# The k3s API server is not reachable from the internet. Operator kubectl reaches
# it through `aws ssm start-session --document-name AWS-StartPortForwardingSession`
# bound to 127.0.0.1:<local port>. The kubeconfig artifact targets that address,
# and 127.0.0.1 is in the server certificate's SANs, so TLS verifies normally.
#
# Usage: ./scripts/k8s-tunnel.sh {up|down|status|ready}
#   up      start the tunnel, or reuse a healthy one. Idempotent: safe to re-run,
#           and the fix when an idle session has been closed by SSM.
#   down    end the SSM session server-side (TerminateSession, so CloudTrail records
#           the end), then stop the local processes and remove the pid file.
#           Idempotent: no-op when there is neither a local tunnel nor an open session.
#   status  exit 0 only if OUR session holds the port AND the API answers /readyz.
#   ready   `up`, then poll /readyz to a deadline (cluster-up.sh uses this between
#           the node plays and the Argo CD bootstrap; k3s may still be restarting).
#   Overrides: PROJECT, REGION, K3S_API_LOCAL_PORT, TUNNEL_DEADLINE_S, API_DEADLINE_S
#
# Why a pid file and a process GROUP: the session is two processes - the aws CLI
# and its session-manager-plugin child, which is the one that actually listens.
# The tunnel is started as its own process group, so `down` can stop both at once
# and `up` can tell OUR listener apart from a foreign process holding the port.
# A tunnel is state in a script (ADR-017 §Costs): every subcommand reconciles
# against what is really running instead of trusting the pid file.
# ===========================================================================
set -euo pipefail

PROJECT="${PROJECT:-proops-taskmgmt}"
REGION="${REGION:-ap-southeast-1}"
LOCAL_PORT="${K3S_API_LOCAL_PORT:-6443}"   # must match k3s_api_local_port in ansible/group_vars/all.yml
REMOTE_PORT=6443                           # k3s API server port on the node
ANSIBLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../ansible" && pwd)"
ARTIFACTS="$ANSIBLE_DIR/.artifacts"
PIDFILE="$ARTIFACTS/k8s-tunnel.pid"
LOGFILE="$ARTIFACTS/k8s-tunnel.log"
KUBECONFIG_ARTIFACT="$ARTIFACTS/kubeconfig"
# Circuit breakers, not predictions (ADR-016). The listener normally appears in a few
# seconds; the API can take longer right after a tls-san change restarts k3s.
TUNNEL_DEADLINE_S="${TUNNEL_DEADLINE_S:-60}"
API_DEADLINE_S="${API_DEADLINE_S:-300}"

log()  { printf '\033[1;34m[tunnel]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[tunnel] WARN:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[tunnel] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null || die "$1 not found - $2"; }

# PID of whatever is LISTENING on the local port (empty if nothing).
listener_pid() {
  lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN -t 2>/dev/null | head -n1 || true
}

# Process-group ID of a PID (empty if the process is gone).
pgid_of() {
  ps -o pgid= -p "$1" 2>/dev/null | tr -d ' ' || true
}

# Our recorded session leader, if the pid file exists AND that process is alive.
our_pid() {
  local pid
  [[ -f "$PIDFILE" ]] || return 0
  pid="$(cat "$PIDFILE")"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    echo "$pid"
  fi
}

# True when the port listener belongs to OUR session's process group.
tunnel_is_ours() {
  local pid lpid
  pid="$(our_pid)"
  lpid="$(listener_pid)"
  [[ -n "$pid" && -n "$lpid" && "$(pgid_of "$lpid")" == "$pid" ]]
}

api_ready() {
  [[ -f "$KUBECONFIG_ARTIFACT" ]] || return 1
  kubectl --kubeconfig "$KUBECONFIG_ARTIFACT" --request-timeout=5s \
    get --raw /readyz >/dev/null 2>&1
}

server_id() {
  local ids
  ids="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Role,Values=k3s-server" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' '\n' | sed '/^$/d')"
  [[ -n "$ids" ]] || die "no RUNNING k3s-server found by tag - run ./scripts/cluster-up.sh first"
  [[ "$(printf '%s\n' "$ids" | wc -l | tr -d ' ')" -eq 1 ]] \
    || die "expected exactly 1 running k3s-server, found: $(printf '%s ' "$ids")"
  echo "$ids"
}

# Marker appended to the log once a session has been terminated, so a second `down`
# does not try to end the same session again. `up` truncates the log for each new session.
TERMINATED_MARK="# k8s-tunnel.sh: terminated session"

# SSM session id of the CURRENT log's session, if it has not been terminated yet.
# The aws CLI prints "Starting session with SessionId: <id>" when the session opens.
open_session_id() {
  local id
  [[ -f "$LOGFILE" ]] || return 0
  id="$(sed -n 's/^Starting session with SessionId: \([A-Za-z0-9._-]*\).*$/\1/p' "$LOGFILE" | tail -n1)"
  [[ -n "$id" ]] || return 0
  grep -qF "${TERMINATED_MARK} ${id}" "$LOGFILE" && return 0
  echo "$id"
}

# End the session on the AWS side. Killing the local CLI alone leaves the session
# "Connected" until the idle timeout, and CloudTrail then shows a StartSession with no
# TerminateSession (MIN-50 AC-5, found in the 2026-11-04 window). A failure here must
# not block the local cleanup, but it must be visible (ADR-017: honest about failure).
terminate_session() {
  local id="$1"
  if aws ssm terminate-session --region "$REGION" --session-id "$id" >/dev/null 2>&1; then
    echo "${TERMINATED_MARK} ${id}" >>"$LOGFILE"
    log "SSM session ${id} terminated server-side."
  else
    warn "could not terminate SSM session ${id} server-side (expired credentials?). It stays open until the Session Manager idle timeout. End it manually: aws ssm terminate-session --region ${REGION} --session-id ${id}"
  fi
}

cmd_down() {
  local pid sess
  pid="$(our_pid)"
  sess="$(open_session_id)"
  # Server side first, so the session ends cleanly instead of being orphaned by the kill.
  # This also covers a laptop crash: no local process left, but the session still open.
  if [[ -n "$sess" ]]; then
    need aws "install the AWS CLI v2"
    terminate_session "$sess"
  fi
  if [[ -z "$pid" ]]; then
    rm -f "$PIDFILE"
    log "no tunnel running."
    return 0
  fi
  log "stopping tunnel (process group ${pid})..."
  kill -TERM -- "-${pid}" 2>/dev/null || true
  for _ in $(seq 1 20); do                # up to 10s for a clean exit, then force
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$pid" 2>/dev/null; then
    warn "session did not exit on TERM - sending KILL"
    kill -KILL -- "-${pid}" 2>/dev/null || true
  fi
  rm -f "$PIDFILE"
  log "tunnel stopped."
}

cmd_up() {
  local lpid sid pid start elapsed
  need aws "install the AWS CLI v2"
  need session-manager-plugin "required for SSM port-forwarding (TSG-021 covers the Apple Silicon path)"
  need lsof "used to find the process holding the local port"
  mkdir -p "$ARTIFACTS"

  if tunnel_is_ours; then
    log "tunnel already up on 127.0.0.1:${LOCAL_PORT} (pid $(our_pid)) - reusing."
    return 0
  fi

  # Reconcile a half-dead session (leader alive, listener gone) before starting a new one.
  if [[ -n "$(our_pid)" ]]; then
    warn "recorded session is alive but not listening - replacing it."
    cmd_down
  fi
  rm -f "$PIDFILE"

  lpid="$(listener_pid)"
  if [[ -n "$lpid" ]]; then
    die "127.0.0.1:${LOCAL_PORT} is held by a process this script did not start: \
pid ${lpid} ($(ps -o comm= -p "$lpid" 2>/dev/null || echo unknown)). Free the port, or set \
K3S_API_LOCAL_PORT and the matching k3s_api_local_port in ansible/group_vars/all.yml."
  fi

  sid="$(server_id)"
  log "opening SSM port-forward 127.0.0.1:${LOCAL_PORT} -> ${sid}:${REMOTE_PORT}..."
  # `set -m` gives the background job its OWN process group (pgid == its pid), which is
  # what lets `down` stop the CLI and the plugin together and `up` recognise our listener.
  set -m
  nohup aws ssm start-session --region "$REGION" --target "$sid" \
    --document-name AWS-StartPortForwardingSession \
    --parameters "{\"portNumber\":[\"${REMOTE_PORT}\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}" \
    >"$LOGFILE" 2>&1 </dev/null &
  pid=$!
  set +m
  echo "$pid" >"$PIDFILE"

  start="$(date +%s)"
  while :; do
    elapsed=$(( $(date +%s) - start ))
    if tunnel_is_ours; then
      log "tunnel up in ${elapsed}s (pid ${pid}, log ${LOGFILE})."
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$PIDFILE"
      die "SSM session exited before listening. Last log lines:
$(tail -n 5 "$LOGFILE" 2>/dev/null)"
    fi
    if [[ "$elapsed" -ge "$TUNNEL_DEADLINE_S" ]]; then
      cmd_down
      die "no listener on 127.0.0.1:${LOCAL_PORT} after ${elapsed}s - see ${LOGFILE}"
    fi
    sleep 1
  done
}

cmd_status() {
  if ! tunnel_is_ours; then
    log "DOWN - no tunnel owned by this script on 127.0.0.1:${LOCAL_PORT}. Run: $0 up"
    return 1
  fi
  need kubectl "needed to probe the API"
  if api_ready; then
    log "UP - tunnel pid $(our_pid), API /readyz OK via 127.0.0.1:${LOCAL_PORT}."
    return 0
  fi
  log "DEGRADED - tunnel is listening but the API does not answer /readyz (k3s restarting, or the session is dead upstream)."
  return 1
}

cmd_ready() {
  local start elapsed last_report=0
  need kubectl "needed to probe the API"
  [[ -f "$KUBECONFIG_ARTIFACT" ]] || die "kubeconfig artifact missing - did the k3s-server play run?"
  start="$(date +%s)"
  log "waiting for the API via the tunnel (ceiling ${API_DEADLINE_S}s)..."
  while :; do
    # Reconcile every round instead of trusting the session started earlier: if SSM
    # dropped it (k3s restart, idle timeout), `up` replaces it rather than masking it.
    cmd_up >/dev/null
    if api_ready; then
      log "API ready via tunnel in $(( $(date +%s) - start ))s."
      return 0
    fi
    elapsed=$(( $(date +%s) - start ))
    if [[ "$elapsed" -ge "$API_DEADLINE_S" ]]; then
      die "API not ready via 127.0.0.1:${LOCAL_PORT} after ${elapsed}s - check ${LOGFILE} and 'kubectl --kubeconfig ${KUBECONFIG_ARTIFACT} get --raw /readyz'"
    fi
    if [[ $(( elapsed - last_report )) -ge 30 ]]; then
      log "  ...API not ready after ${elapsed}s"
      last_report="$elapsed"
    fi
    sleep 5
  done
}

case "${1:-}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  ready)  cmd_ready ;;
  *)      die "usage: $0 {up|down|status|ready}" ;;
esac
