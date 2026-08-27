#!/usr/bin/env bash
# ============================================================================
# Creates a scoped, OIDC-enabled service principal for Azure Migrate deploys.
#
# Sets up (idempotently):
#   1. A least-privilege custom role ("Azure Migrate Project Deployer").
#   2. An Entra app registration + service principal.
#   3. A role assignment for the SP at the chosen scope.
#   4. A federated credential so GitHub Actions can log in via OIDC — no secret.
#
# Custodian teams never get direct Azure access; the pipeline uses this SP.
# Run once, by a subscription Owner / User Access Administrator.
#
# Usage:
#   ./create-service-principal.sh <subscription-id> <github-org/repo> [resource-group] [branch]
#
# Example:
#   ./create-service-principal.sh 594e0bd0-... jaxywaxy/AzureMigrate rg-migrate-dev main
#
# On success it prints AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_SUBSCRIPTION_ID
# for you to store as GitHub repo secrets (see scripts/set-github-secrets.sh).
# ============================================================================
set -euo pipefail

SUBSCRIPTION_ID="${1:?subscription id required}"
GH_REPO="${2:?github org/repo required, e.g. jaxywaxy/AzureMigrate}"
RESOURCE_GROUP="${3:-}"          # optional — omit to scope at subscription level
BRANCH="${4:-main}"             # branch the federated credential trusts
GH_ENVIRONMENT="${5:-dev}"     # GitHub environment the workflow declares

APP_NAME="sp-azure-migrate-automation"
ROLE_NAME="Azure Migrate Project Deployer"
FIC_NAME="github-${GH_REPO//\//-}-${BRANCH}"   # federated credential name

if [[ -n "$RESOURCE_GROUP" ]]; then
  SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}"
else
  SCOPE="/subscriptions/${SUBSCRIPTION_ID}"
fi

TENANT_ID="$(az account show --query tenantId -o tsv)"

echo ">> Subscription : ${SUBSCRIPTION_ID}"
echo ">> Scope        : ${SCOPE}"
echo ">> GitHub repo  : ${GH_REPO} (branch: ${BRANCH})"
echo ""

# ---------------------------------------------------------------------------
# 1. Custom role (least privilege)
# ---------------------------------------------------------------------------
if ! az role definition list --name "$ROLE_NAME" --query "[0].roleName" -o tsv 2>/dev/null | grep -q "$ROLE_NAME"; then
  echo ">> Creating custom role '${ROLE_NAME}'"
  ROLE_JSON="$(mktemp)"
  cat > "$ROLE_JSON" <<EOF
{
  "Name": "${ROLE_NAME}",
  "IsCustom": true,
  "Description": "Deploy and manage Azure Migrate projects and supporting storage.",
  "Actions": [
    "Microsoft.Migrate/*",
    "Microsoft.OffAzure/*",
    "Microsoft.Storage/storageAccounts/read",
    "Microsoft.Storage/storageAccounts/write",
    "Microsoft.Storage/storageAccounts/delete",
    "Microsoft.Storage/storageAccounts/listKeys/action",
    "Microsoft.Resources/deployments/*",
    "Microsoft.Resources/subscriptions/resourceGroups/read",
    "Microsoft.Resources/subscriptions/resourceGroups/write"
  ],
  "NotActions": [],
  "AssignableScopes": [
    "/subscriptions/${SUBSCRIPTION_ID}"
  ]
}
EOF
  az role definition create --role-definition "$ROLE_JSON" --output none
  rm -f "$ROLE_JSON"
else
  echo ">> Custom role '${ROLE_NAME}' already exists — skipping."
fi

# ---------------------------------------------------------------------------
# 2. App registration + service principal (idempotent)
# ---------------------------------------------------------------------------
APP_ID="$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)"
if [[ -z "$APP_ID" ]]; then
  echo ">> Creating app registration '${APP_NAME}'"
  APP_ID="$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)"
else
  echo ">> App registration '${APP_NAME}' already exists (${APP_ID}) — reusing."
fi

if [[ -z "$(az ad sp list --filter "appId eq '${APP_ID}'" --query "[0].id" -o tsv)" ]]; then
  echo ">> Creating service principal for app"
  az ad sp create --id "$APP_ID" --output none
else
  echo ">> Service principal already exists — reusing."
fi

# ---------------------------------------------------------------------------
# 3. Role assignment at scope (idempotent)
# ---------------------------------------------------------------------------
echo ">> Assigning '${ROLE_NAME}' to SP at scope"
az role assignment create \
  --assignee "$APP_ID" \
  --role "$ROLE_NAME" \
  --scope "$SCOPE" \
  --output none 2>/dev/null \
  && echo "   assigned." \
  || echo "   assignment already present — skipping."

# ---------------------------------------------------------------------------
# 4. Federated credential for GitHub Actions OIDC (idempotent)
#    subject must match GitHub's OIDC token for this repo/branch.
# ---------------------------------------------------------------------------
# Idempotently create a federated credential with a given name/subject.
create_fic() {
  local name="$1" subject="$2" desc="$3"
  if [[ -n "$(az ad app federated-credential list --id "$APP_ID" --query "[?name=='${name}'].name" -o tsv 2>/dev/null)" ]]; then
    echo ">> Federated credential '${name}' already exists — skipping."
    return
  fi
  echo ">> Creating federated credential '${name}'"
  local fic_json; fic_json="$(mktemp)"
  cat > "$fic_json" <<EOF
{
  "name": "${name}",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "${subject}",
  "description": "${desc}",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF
  az ad app federated-credential create --id "$APP_ID" --parameters "$fic_json" --output none
  rm -f "$fic_json"
}

# The workflow declares `environment: <env>`, so GitHub's OIDC token subject is
# environment-scoped (repo:OWNER/REPO:environment:<env>) — that's the credential
# that actually fires. We add the branch-scoped one too for flexibility.
create_fic "$FIC_NAME" \
  "repo:${GH_REPO}:ref:refs/heads/${BRANCH}" \
  "GitHub Actions OIDC for ${GH_REPO}@${BRANCH}"

create_fic "github-${GH_REPO//\//-}-env-${GH_ENVIRONMENT}" \
  "repo:${GH_REPO}:environment:${GH_ENVIRONMENT}" \
  "GitHub Actions OIDC for ${GH_REPO}, environment=${GH_ENVIRONMENT}"

# ---------------------------------------------------------------------------
# Output the three values for GitHub secrets
# ---------------------------------------------------------------------------
cat <<EOF

============================================================================
DONE. Set these as GitHub repo secrets (no client secret needed for OIDC):

  AZURE_CLIENT_ID        ${APP_ID}
  AZURE_TENANT_ID        ${TENANT_ID}
  AZURE_SUBSCRIPTION_ID  ${SUBSCRIPTION_ID}

Do it in one step:
  ./scripts/set-github-secrets.sh ${GH_REPO} ${APP_ID} ${TENANT_ID} ${SUBSCRIPTION_ID}
============================================================================
EOF
