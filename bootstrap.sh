#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — Install ArgoCD on EKS and hand control to GitOps
#
# Run ONCE after the EKS cluster is up (after gitops-eks-infra deploy.sh).
# After this script completes, everything is managed by ArgoCD via Git.
#
# Usage:
#   chmod +x bootstrap.sh
#   ./bootstrap.sh [environment] [region]
#
# Example:
#   ./bootstrap.sh prod us-east-1
#
# Prerequisites:
#   - kubectl configured for the target cluster
#   - helm installed
#   - aws cli configured with sufficient IAM permissions
#   - SSM parameters set (see README.md)
# =============================================================================
set -euo pipefail
export MSYS_NO_PATHCONV=1   # prevent Git Bash path mangling on Windows

ENV="${1:-prod}"
REGION="${2:-us-east-1}"
STACK_PREFIX="${ENV}-eks"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================================"
echo " Bootstrapping ArgoCD"
echo " Environment : ${ENV}"
echo " Region      : ${REGION}"
echo "============================================================"

# ── Pre-flight: required SSM parameters ──────────────────────────────────
echo ""
echo "── Pre-flight: checking SSM parameters ──"
MISSING=0
for PARAM in \
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

# ── Step 1: Deploy ArgoCD IRSA IAM roles ─────────────────────────────────
echo ""
echo "── Step 1: Deploy IRSA IAM roles ──"
OIDC_ARN=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_PREFIX}-oidc" --region "${REGION}" \
  --query 'Stacks[0].Outputs[?OutputKey==`OIDCProviderArn`].OutputValue' \
  --output text)
OIDC_URL=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_PREFIX}-oidc" --region "${REGION}" \
  --query 'Stacks[0].Outputs[?OutputKey==`OIDCProviderUrl`].OutputValue' \
  --output text)

aws cloudformation deploy \
  --stack-name "${STACK_PREFIX}-argocd-irsa" \
  --template-file "${SCRIPT_DIR}/iam/argocd-irsa.yaml" \
  --parameter-overrides \
    EnvironmentName="${ENV}" \
    OIDCProviderArn="${OIDC_ARN}" \
    OIDCProviderUrl="${OIDC_URL}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "${REGION}" \
  --no-fail-on-empty-changeset
echo " ✓ IRSA roles deployed"

# ── Step 2: Create argocd namespace ──────────────────────────────────────
echo ""
echo "── Step 2: argocd namespace ──"
kubectl apply -f "${SCRIPT_DIR}/install/namespace.yaml"
echo " ✓ Namespace ready"

# ── Step 3: Populate argocd-secret from SSM ──────────────────────────────
echo ""
echo "── Step 3: argocd-secret from SSM ──"

GITHUB_CLIENT_ID=$(aws ssm get-parameter \
  --name "/${ENV}/argocd/github-client-id" --with-decryption \
  --region "${REGION}" --query 'Parameter.Value' --output text 2>/dev/null || echo "")
GITHUB_CLIENT_SECRET=$(aws ssm get-parameter \
  --name "/${ENV}/argocd/github-client-secret" --with-decryption \
  --region "${REGION}" --query 'Parameter.Value' --output text)
ADMIN_PASSWORD_BCRYPT=$(aws ssm get-parameter \
  --name "/${ENV}/argocd/admin-password-bcrypt" --with-decryption \
  --region "${REGION}" --query 'Parameter.Value' --output text)
SERVER_SECRET_KEY=$(aws ssm get-parameter \
  --name "/${ENV}/argocd/server-secret-key" --with-decryption \
  --region "${REGION}" --query 'Parameter.Value' --output text 2>/dev/null || \
  ( KEY=$(openssl rand -hex 32) && \
    aws ssm put-parameter --name "/${ENV}/argocd/server-secret-key" \
      --value "${KEY}" --type SecureString --region "${REGION}" > /dev/null && \
    echo "${KEY}" ))

kubectl create secret generic argocd-secret \
  --namespace argocd \
  --from-literal=clientID="${GITHUB_CLIENT_ID}" \
  --from-literal=clientSecret="${GITHUB_CLIENT_SECRET}" \
  --from-literal=admin.password="${ADMIN_PASSWORD_BCRYPT}" \
  --from-literal=admin.passwordMtime="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --from-literal=server.secretkey="${SERVER_SECRET_KEY}" \
  --save-config --dry-run=client -o yaml | kubectl apply -f -
echo " ✓ argocd-secret populated"

# ── Step 4: Install ArgoCD via Kustomize ─────────────────────────────────
echo ""
echo "── Step 4: Install ArgoCD ──"
kubectl apply -k "${SCRIPT_DIR}/install/"

for DEPLOY in argocd-server argocd-repo-server argocd-dex-server; do
  echo -n "   waiting for ${DEPLOY}..."
  until kubectl get deployment "${DEPLOY}" -n argocd > /dev/null 2>&1; do
    echo -n "."; sleep 3
  done
  kubectl rollout status deployment/"${DEPLOY}" -n argocd --timeout=300s
done
echo -n "   waiting for argocd-application-controller..."
until kubectl get statefulset argocd-application-controller -n argocd > /dev/null 2>&1; do
  echo -n "."; sleep 3
done
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
echo " ✓ ArgoCD installed"

# ── Step 5: Apply AppProjects ─────────────────────────────────────────────
echo ""
echo "── Step 5: AppProjects ──"
kubectl apply -f "${SCRIPT_DIR}/projects/"
echo " ✓ AppProjects applied"

# ── Step 6: Bootstrap root App-of-Apps ───────────────────────────────────
echo ""
echo "── Step 6: Root App-of-Apps ──"
kubectl apply -f "${SCRIPT_DIR}/apps/root-app.yaml"
echo " ✓ Root Application applied — ArgoCD now manages everything from Git"

echo ""
echo "============================================================"
echo " ✓ Bootstrap complete!"
echo ""
echo " ArgoCD will now automatically sync:"
echo "   infra/argocd-config          ← config/          (this repo)"
echo "   infra/eks-infra              ← post-deploy-k8s/ (gitops-eks-infra)"
echo "   infra/external-secrets-operator ← Helm chart"
echo "   apps/three-tier-app          ← k8s_manifests/   (gitops-app)"
echo ""
echo " ArgoCD UI: https://argocd.prashantgawali.site"
echo " Port-forward: kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "============================================================"
