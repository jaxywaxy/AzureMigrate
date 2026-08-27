#!/usr/bin/env bash
# ============================================================================
# Grants the pipeline SP the ONE elevated permission it needs to pre-create
# appliance Entra app registrations: Microsoft Graph Application.ReadWrite.OwnedBy.
#
# This is the only step in the whole system that needs a privileged operator:
# admin-consenting a Graph application permission requires a Global Administrator
# or Privileged Role Administrator. Run it ONCE.
#
# After this, the pipeline SP can create/manage app registrations it owns —
# scoped to OwnedBy, so it CANNOT touch apps it didn't create.
#
# (The custom-role RBAC actions — roleAssignments/write, Key Vault — are added
# by create-service-principal.sh; re-run that too if you set the SP up before
# this feature existed.)
#
# Usage:
#   ./grant-pipeline-graph-permissions.sh [pipeline-sp-app-id]
#   (defaults to the sp-azure-migrate-automation app id)
# ============================================================================
set -euo pipefail

PIPELINE_APP_ID="${1:-e53f8fd1-f45e-451f-b642-929912afbfce}"

GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"                 # Microsoft Graph
PERM_ID="18a4783c-866b-4cc7-a460-3d5e5662c884"                      # Application.ReadWrite.OwnedBy (Role)

echo ">> Pipeline SP app id : ${PIPELINE_APP_ID}"
echo ">> Granting Microsoft Graph Application.ReadWrite.OwnedBy (app permission)"

# Idempotent: only add if not already present on the app's requiredResourceAccess.
ALREADY="$(az ad app permission list --id "$PIPELINE_APP_ID" \
  --query "[?resourceAppId=='${GRAPH_APP_ID}'].resourceAccess[?id=='${PERM_ID}'].id | [0]" \
  -o tsv 2>/dev/null || true)"

if [[ -z "$ALREADY" ]]; then
  echo ">> Adding permission to the app manifest"
  az ad app permission add \
    --id "$PIPELINE_APP_ID" \
    --api "$GRAPH_APP_ID" \
    --api-permissions "${PERM_ID}=Role" \
    --output none
else
  echo ">> Permission already on the app manifest — skipping add."
fi

echo ">> Granting admin consent by creating the appRoleAssignment directly"
# `az ad app permission admin-consent` is unreliable for app (Role) permissions —
# it can report success without materializing the grant. Create the
# appRoleAssignment on the SP explicitly instead (requires Global Admin /
# Privileged Role Admin). Idempotent: skip if already present.
SP_OBJECT_ID="$(az ad sp show --id "$PIPELINE_APP_ID" --query id -o tsv)"
GRAPH_SP_ID="$(az ad sp show --id "$GRAPH_APP_ID" --query id -o tsv)"

EXISTING="$(az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_OBJECT_ID}/appRoleAssignments" \
  --query "value[?appRoleId=='${PERM_ID}'].id | [0]" -o tsv 2>/dev/null || true)"

if [[ -z "$EXISTING" ]]; then
  az rest --method POST \
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_OBJECT_ID}/appRoleAssignments" \
    --headers "Content-Type=application/json" \
    --body "$(printf '{"principalId":"%s","resourceId":"%s","appRoleId":"%s"}' "$SP_OBJECT_ID" "$GRAPH_SP_ID" "$PERM_ID")" \
    --output none
  echo ">> App role assignment created."
else
  echo ">> App role assignment already present — skipping."
fi

echo ""
echo ">> Verifying the app-role assignment on the SP's service principal"
az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_OBJECT_ID}/appRoleAssignments" \
  --query "value[?appRoleId=='${PERM_ID}'].{resource:resourceDisplayName, appRoleId:appRoleId}" \
  -o table 2>&1 || echo "(could not read app role assignments — check manually)"

echo ""
echo ">> DONE. The pipeline SP can now pre-create appliance app registrations."
