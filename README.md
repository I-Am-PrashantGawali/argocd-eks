# gitops-argocd

ArgoCD configuration repo. Every file here is the source of truth for the ArgoCD server itself and for all application/infrastructure deployments it manages.

```
gitops-argocd/
├── bootstrap.sh          # Run once to install ArgoCD and hand off to GitOps
├── 08-argocd-irsa.yaml   # CloudFormation — IRSA roles for ArgoCD service accounts
│
├── install/              # ArgoCD installation (Kustomize)
│   ├── namespace.yaml
│   ├── kustomization.yaml  ← pins ArgoCD version + patches resources
│   └── ingress.yaml        ← ALB ingress for ArgoCD UI
│
├── config/               # ArgoCD runtime config (auto-synced by argocd-config app)
│   ├── argocd-cm.yaml      ← repos, SSO, UI banner
│   ├── argocd-rbac-cm.yaml ← role policies
│   └── argocd-secret.yaml  ← placeholder only — NEVER committed with real values
│
├── projects/             # AppProjects (access control per team)
│   ├── infra-project.yaml
│   └── apps-project.yaml
│
└── apps/                 # App-of-Apps tree (the only thing root-app watches)
    ├── root-app.yaml         ← apply this once manually
    ├── infra/
    │   ├── argocd-config-app.yaml         ← syncs config/ (this repo)
    │   ├── eks-infra-app.yaml             ← syncs gitops-eks-infra/post-deploy-k8s/
    │   └── external-secrets-app.yaml      ← installs ESO via Helm
    └── workloads/
        └── three-tier-app.yaml            ← syncs gitops-app/k8s_manifests/
```

## Repos this config depends on

| Repo | What ArgoCD reads from it |
|---|---|
| `gitops-argocd` (this repo) | `config/`, `apps/` — ArgoCD self-config |
| `gitops-eks-infra` | `post-deploy-k8s/` — StorageClass, Cluster Autoscaler, etc. |
| `gitops-app` | `k8s_manifests/` — frontend, backend, MongoDB deployments |

## Secret management

Secrets are never stored in Git. They live in AWS SSM Parameter Store and are written to the cluster by scripts.

**If SSO stops working or the secret is missing keys** (e.g. after a cluster rebuild):
```bash
./refresh-secret.sh prod us-east-1
```
This fetches all values from SSM, rewrites `argocd-secret`, and restarts Dex. Safe to run at any time — it is fully idempotent.

**To rotate the GitHub OAuth secret:**
1. Generate a new secret in your GitHub OAuth App settings.
2. Update SSM: `aws ssm put-parameter --name /prod/argocd/github-client-secret --value "NEW_SECRET" --type SecureString --overwrite`
3. Run `./refresh-secret.sh prod us-east-1`

## How to make a change

**ArgoCD config change** (e.g. add a new repo, change RBAC):
1. Edit `config/argocd-cm.yaml` or `config/argocd-rbac-cm.yaml`.
2. Commit and push to `main`.
3. ArgoCD syncs `argocd-config` app within 3 minutes (or immediately via webhook).

**Add a new application**:
1. Create a new `Application` YAML under `apps/workloads/`.
2. Commit and push. The `root-app` picks it up automatically.

**Upgrade ArgoCD**:
1. Change the version pin in `install/kustomization.yaml`.
2. Commit and push. ArgoCD will apply the new manifests to itself.

## One-time bootstrap

### Pre-requisites

Store these in AWS SSM Parameter Store before running bootstrap:

```bash
# GitHub OAuth client secret (from your GitHub OAuth App)
aws ssm put-parameter \
  --name "/prod/argocd/github-client-secret" \
  --value "YOUR_GITHUB_CLIENT_SECRET" \
  --type SecureString

# bcrypt-hashed admin password  (generate: htpasswd -bnBC 10 "" password | tr -d ':\n')
aws ssm put-parameter \
  --name "/prod/argocd/admin-password-bcrypt" \
  --value "YOUR_BCRYPT_HASH" \
  --type SecureString
```

### Run bootstrap

```bash
# 1. EKS cluster must already be up (run gitops-eks-infra/deploy.sh first)
# 2. Update all I-Am-PrashantGawali placeholders in this repo to your real GitHub org/repo names
# 3. Bootstrap ArgoCD
./bootstrap.sh prod us-east-1
```

After bootstrap, ArgoCD owns everything. You never need to `kubectl apply` again —
just commit to the relevant repo.
