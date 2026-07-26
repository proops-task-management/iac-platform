#!/usr/bin/env bash
# ===========================================================================
# seed-ssm.sh — one-time SSM Parameter Store seeding (IRD-019).
#
# Single source of truth for every secret value = SSM (SecureString). This
# script NEVER writes secrets through Terraform (keeps values out of tfstate),
# never prints a value, and is idempotent (--overwrite).
#
# Reads plaintext inputs from a gitignored env file (default ~/.proops-secrets.env,
# template: scripts/seed-ssm.env.example). Values not supplied are generated:
#   DB/Redis/Grafana passwords -> openssl rand -base64 24
#   JWT keypair                -> openssl genrsa 2048 (+ rsa -pubout)
# Two inputs must be supplied by you (external systems):
#   DISCORD_WEBHOOK_URL, SONAR_TOKEN
#
# Usage:
#   ./scripts/seed-ssm.sh            # seed env=dev in ap-southeast-1
#   ENV=dev REGION=ap-southeast-1 SECRETS_FILE=~/.proops-secrets.env ./scripts/seed-ssm.sh
# ===========================================================================
set -euo pipefail

ENV="${ENV:-dev}"
REGION="${REGION:-ap-southeast-1}"
SECRETS_FILE="${SECRETS_FILE:-$HOME/.proops-secrets.env}"

# --- Secure scratch dir for values (0700; shredded on exit) ------------------
WORKDIR="$(mktemp -d)"
chmod 700 "$WORKDIR"
cleanup() {
  if command -v shred >/dev/null 2>&1; then
    find "$WORKDIR" -type f -exec shred -u {} + 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# --- Load operator-supplied inputs (optional overrides) ----------------------
if [[ -f "$SECRETS_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$SECRETS_FILE"; set +a
  echo "Loaded inputs from $SECRETS_FILE"
else
  echo "No $SECRETS_FILE found — generating all passwords, skipping externally-supplied secrets."
fi

gen_pw() { openssl rand -base64 24; }

# Write a value to a temp file (never echoed) and return its path.
val_file() {
  local name="$1" value="$2" f="$WORKDIR/$1"
  printf '%s' "$value" > "$f"
  chmod 600 "$f"
  printf '%s' "$f"
}

# put a SecureString from a file (file:// keeps the value off the process list).
put_secure() {
  local path="$1" file="$2"
  aws ssm put-parameter \
    --region "$REGION" \
    --name "$path" \
    --type SecureString \
    --overwrite \
    --value "file://$file" \
    --output text --query 'Version' >/dev/null
  echo "  seeded $path"
}

echo "== Seeding SSM (env=$ENV, region=$REGION) =="

# --- Generated passwords (override via env file) -----------------------------
# NO associative arrays — macOS ships bash 3.2, which lacks `declare -A` (that
# fails with "operand expected"). Portable helper + explicit calls instead.
seed_generated() {
  local path="$1" var="$2" value
  eval "value=\${$var:-}"                 # read $MYSQL_ROOT_PASSWORD etc. (var name is a trusted literal)
  [[ -z "$value" ]] && value="$(gen_pw)"  # blank/unset -> generate
  put_secure "$path" "$(val_file "$(echo "$path" | tr '/' '_')" "$value")"
}

seed_generated "/proops/$ENV/mysql/root_password"      MYSQL_ROOT_PASSWORD
seed_generated "/proops/$ENV/mysql/user_svc_password"  MYSQL_USER_SVC_PASSWORD
seed_generated "/proops/$ENV/mysql/task_svc_password"  MYSQL_TASK_SVC_PASSWORD
seed_generated "/proops/$ENV/mysql/notif_svc_password" MYSQL_NOTIF_SVC_PASSWORD
seed_generated "/proops/$ENV/redis/password"           REDIS_PASSWORD
seed_generated "/proops/global/grafana/admin_password" GRAFANA_ADMIN_PASSWORD

# --- JWT keypair (RS256, IRD-019) -------------------------------------------
# Reuse the D6 keypair if pointed at it; otherwise generate a fresh 2048-bit key.
JWT_PRIV="$WORKDIR/jwt_private.pem"
JWT_PUB="$WORKDIR/jwt_public.pem"
if [[ -n "${JWT_PRIVATE_KEY_FILE:-}" && -f "${JWT_PRIVATE_KEY_FILE}" ]]; then
  cp "$JWT_PRIVATE_KEY_FILE" "$JWT_PRIV"
  openssl rsa -in "$JWT_PRIV" -pubout -out "$JWT_PUB" 2>/dev/null
  echo "  using JWT private key from $JWT_PRIVATE_KEY_FILE"
else
  openssl genrsa -out "$JWT_PRIV" 2048 2>/dev/null
  openssl rsa -in "$JWT_PRIV" -pubout -out "$JWT_PUB" 2>/dev/null
  echo "  generated fresh JWT keypair"
fi
chmod 600 "$JWT_PRIV" "$JWT_PUB"
put_secure "/proops/$ENV/jwt/private_key" "$JWT_PRIV"
put_secure "/proops/$ENV/jwt/public_key" "$JWT_PUB"

# --- Externally-supplied secrets (skip with a warning if absent) -------------
if [[ -n "${DISCORD_WEBHOOK_URL:-}" ]]; then
  put_secure "/proops/global/discord/webhook_url" "$(val_file discord "$DISCORD_WEBHOOK_URL")"
else
  echo "  SKIP /proops/global/discord/webhook_url (set DISCORD_WEBHOOK_URL in $SECRETS_FILE)"
fi
if [[ -n "${SONAR_TOKEN:-}" ]]; then
  put_secure "/proops/ci/sonar_token" "$(val_file sonar "$SONAR_TOKEN")"
else
  echo "  SKIP /proops/ci/sonar_token (set SONAR_TOKEN in $SECRETS_FILE)"
fi

# --- Inventory diff (present vs the IRD-019 inventory) -----------------------
echo
echo "== Inventory check (IRD-019) =="
EXPECTED=(
  "/proops/$ENV/mysql/root_password"
  "/proops/$ENV/mysql/user_svc_password"
  "/proops/$ENV/mysql/task_svc_password"
  "/proops/$ENV/mysql/notif_svc_password"
  "/proops/$ENV/redis/password"
  "/proops/$ENV/jwt/private_key"
  "/proops/$ENV/jwt/public_key"
  "/proops/global/grafana/admin_password"
  "/proops/global/discord/webhook_url"
  "/proops/ci/sonar_token"
)
PRESENT="$(aws ssm get-parameters-by-path --region "$REGION" --path "/proops" --recursive \
  --query 'Parameters[].Name' --output text 2>/dev/null | tr '\t' '\n' || true)"
for p in "${EXPECTED[@]}"; do
  if grep -qxF "$p" <<<"$PRESENT"; then echo "  ✅ $p"; else echo "  ❌ MISSING $p"; fi
done
echo
echo "  ℹ  /proops/dev/k3s/token + /proops/dev/k3s/server-ip are written by"
echo "     Ansible at D10 (IRD-016) — not by this script. Inventory reaches 12 then."
echo "== Done =="
