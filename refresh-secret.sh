#!/usr/bin/env bash
# =============================================================================
# refresh-secret.sh — Rebuild argocd-secret from AWS SSM
#
# Run this whenever argocd-secret is stale or missing values (e.g. after a
# cluster rebuild, secret rotation, or first-time SSO setup).
# This is the ONLY way secrets should be written to the cluster — never kubectl
# patch, never hardcoded values, never committed to Git.
#
# Usage:
#   chmod +x refresh-secret.sh
#   ./refresh-secret.sh [environment] [region]
#
# Example:
#   ./refresh-secret.sh prod us-east-1
# =============================================================================
set -euo pipefail
export MSYS_NO_PATHCONV=1

ENV="${1:-prod}"
REGION="${2:-us-east-1}"

echo "============================================================"
echo " Refreshing argocd-secret from SSM"
echo " Environment : ${ENV}"
echo " Region      : ${REGION}"
echo "============================================================"

# ── Pre-flight: check all required SSM parameters exist ──────────────────
echo ""
echo "── Checking SSM parameters ──"
MISSING=0
for PARAM in \
  "/${ENV}/argocd/github-client-id" \
  "/${ENV}/argocd/github-client-secret" \
  "/${ENV}/argocd/admin-password-bcrypt"; do
  if ! aws ssm get-parameter --name "${PARAM}" --region "${REGION}" > /dev/null 2>&1; then
    echo " ✗ Missing: ${PARAM}"
    MISSING=1
  else
    echo " ✓ Found:   ${PARAM}"
  fi
done
if [ "${MISSING}" -eq 1 ]; then
  echo ""
  echo " Store missing parameters in SSM first. See README.md → Pre-requisites."
  exit 1
fi

# ── Fetch values from SSM ────────────────────────────────────────────────
echo ""
echo "── Fetching values from SSM ──"

GITHUB_CLIENT_ID=$(aws ssm get-parameter \
  --name "/${ENV}/argocd/github-client-id" --with-decryption \
  --region "${REGION}" --query 'Parameter.Value' --output text)

GITHUB_CLIENT_SECRET=$(aws ssm get-parameter \
  --name "/${ENV}/argocd/github-client-secret" --with-decryption \
  --region "${REGION}" --query 'Parameter.Value' --output text)

ADMIN_PASSWORD_BCRYPT=$(aws ssm get-parameter \
  --name "/${ENV}/argocd/admin-password-bcrypt" --with-decryption \
  --region "${REGION}" --query 'Parameter.Value' --output text)

# server.secretkey: reuse existing if present, generate and store if not
SERVER_SECRET_KEY=$(aws ssm get-parameter \
  --name "/${ENV}/argocd/server-secret-key" --with-decryption \
  --region "${REGION}" --query 'Parameter.Value' --output text 2>/dev/null || \
  ( KEY=$(openssl rand -hex 32) && \
    aws ssm put-parameter \
      --name "/${ENV}/argocd/server-secret-key" \
      --value "${KEY}" --type SecureString --region "${REGION}" > /dev/null && \
    echo " ✓ Generated and stored new server.secretkey" >&2 && \
    echo "${KEY}" ))

echo " ✓ All values fetched"

# ── Write argocd-secret ──────────────────────────────────────────────────
echo ""
echo "── Writing argocd-secret to cluster ──"

kubectl create secret generic argocd-secret \
  --namespace argocd \
  --from-literal=clientID="${GITHUB_CLIENT_ID}" \
  --from-literal=clientSecret="${GITHUB_CLIENT_SECRET}" \
  --from-literal=admin.password="${ADMIN_PASSWORD_BCRYPT}" \
  --from-literal=admin.passwordMtime="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --from-literal=server.secretkey="${SERVER_SECRET_KEY}" \
  --save-config --dry-run=client -o yaml | \
  kubectl label --local -f - \
    app.kubernetes.io/name=argocd-secret \
    app.kubernetes.io/part-of=argocd \
    --dry-run=client -o yaml | \
  kubectl apply -f -

echo " ✓ argocd-secret updated"

# Wait for secret to propagate to all pods before restarting Dex
echo ""
echo "── Waiting 15s for secret to propagate ──"
sleep 15
echo " ✓ Secret propagated"

# ── Restart Dex so it picks up new clientID/clientSecret immediately ─────
echo ""
echo "── Restarting argocd-dex-server ──"
kubectl rollout restart deployment/argocd-dex-server -n argocd
kubectl rollout status deployment/argocd-dex-server -n argocd --timeout=180s
echo " ✓ Dex restarted"

# ── Restart argocd-server so it re-registers the SSO /auth/login/sso route ──
echo ""
echo "── Restarting argocd-server ──"
kubectl rollout restart deployment/argocd-server -n argocd
kubectl rollout status deployment/argocd-server -n argocd --timeout=180s
echo " ✓ argocd-server restarted"

echo ""
echo "============================================================"
echo " ✓ argocd-secret refreshed successfully"
echo ""
echo " SSO should now work. Open https://argocd.prashantgawali.site"
echo " and click 'LOGIN VIA GITHUB'."
echo "============================================================"
