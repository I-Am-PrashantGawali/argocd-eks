#!/usr/bin/env bash
# =============================================================================
# reset-admin-password.sh — Set a new ArgoCD admin password via SSM
#
# Generates a bcrypt hash inside the cluster (no local htpasswd needed),
# stores it in SSM, then calls refresh-secret.sh to push it to the cluster.
#
# Usage:
#   chmod +x reset-admin-password.sh
#   ./reset-admin-password.sh <new-password> [environment] [region]
#
# Example:
#   ./reset-admin-password.sh 'MyNewPass@123' prod us-east-1
# =============================================================================
set -euo pipefail
export MSYS_NO_PATHCONV=1

NEW_PASS="${1:-}"
ENV="${2:-prod}"
REGION="${3:-us-east-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${NEW_PASS}" ]; then
  echo " ERROR: Provide a password as the first argument."
  echo " Usage: ./reset-admin-password.sh 'MyNewPass@123' prod us-east-1"
  exit 1
fi

echo "============================================================"
echo " Resetting ArgoCD admin password"
echo " Environment : ${ENV}"
echo " Region      : ${REGION}"
echo "============================================================"

# Generate bcrypt hash inside the argocd-server container
# argocd-server ships with the argocd binary which includes bcrypt support
echo ""
echo "── Generating bcrypt hash inside cluster ──"
HASH=$(kubectl -n argocd exec deploy/argocd-server -- \
  argocd account bcrypt --password "${NEW_PASS}" 2>/dev/null)

if [ -z "${HASH}" ]; then
  echo " ERROR: Failed to generate bcrypt hash. Is argocd-server running?"
  exit 1
fi
echo " ✓ Hash generated"

# Store in SSM
echo ""
echo "── Storing hash in SSM ──"
aws ssm put-parameter \
  --name "/${ENV}/argocd/admin-password-bcrypt" \
  --value "${HASH}" \
  --type SecureString \
  --overwrite \
  --region "${REGION}" > /dev/null
echo " ✓ Stored in SSM: /${ENV}/argocd/admin-password-bcrypt"

# Push to cluster
echo ""
"${SCRIPT_DIR}/refresh-secret.sh" "${ENV}" "${REGION}"

echo ""
echo "============================================================"
echo " ✓ Admin password reset complete"
echo ""
echo " Login at: https://argocd.prashantgawali.site"
echo " Username: admin"
echo " Password: ${NEW_PASS}"
echo "============================================================"
