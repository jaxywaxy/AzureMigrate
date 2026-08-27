#!/usr/bin/env bash
# ============================================================================
# Creates a scoped service principal for Azure Migrate deployments.
#
# The SP is granted ONLY what's needed to stand up Migrate projects in one
# subscription (optionally narrowed to a single RG). Custodian teams never get
# direct Azure access — the pipeline uses this SP.
#
# Run once, by a subscription Owner/User Access Administrator. Capture the
# JSON output into your pipeline secret store.
#
# Usage:
#   ./create-service-principal.sh <subscription-id> [resource-group]
# ============================================================================
set -euo pipefail

SUBSCRIPTION_ID="${1:?subscription id required}"
RESOURCE_GROUP="${2:-}"      # optional — omit to scope at subscription level
SP_NAME="sp-azure-migrate-automation"

if [[ -n "$RESOURCE_GROUP" ]]; then
  SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}"
else
  SCOPE="/subscriptions/${SUBSCRIPTION_ID}"
fi

echo ">> Creating service principal '${SP_NAME}' scoped to: ${SCOPE}"

# Contributor is broad; we prefer a least-privilege custom role. Create it if
# it doesn't already exist, then assign it. Contributor on the scope is the
# fallback if you'd rather not manage a custom role for the prototype.
ROLE_NAME="Azure Migrate Project Deployer"

if ! az role definition list --name "$ROLE_NAME" --query "[0].roleName" -o tsv 2>/dev/null | grep -q "$ROLE_NAME"; then
  echo ">> Creating custom role '${ROLE_NAME}'"
  cat > /tmp/migrate-role.json <<EOF
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
  az role definition create --role-definition /tmp/migrate-role.json
  rm -f /tmp/migrate-role.json
fi

echo ">> Creating SP and assigning role at scope"
az ad sp create-for-rbac \
  --name "$SP_NAME" \
  --role "$ROLE_NAME" \
  --scopes "$SCOPE" \
  --json-auth

echo ""
echo ">> DONE. Store the JSON above as the pipeline secret AZURE_CREDENTIALS."
echo ">> (Rotate/replace with OIDC federated credentials for production — see README.)"
