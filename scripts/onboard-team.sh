#!/usr/bin/env bash
# ============================================================================
# Onboards a custodian team onto the SHARED central Azure Migrate project.
#
# Central-project model: the platform team runs ONE Migrate project (with the
# private endpoint). Each custodian team registers their OWN appliance to that
# shared project and migrates VMs into their OWN target resource group. No new
# Migrate project is created per team.
#
# This script (pipeline-run, no elevated custodian rights) does, per team:
#   1. Pre-creates the team's appliance Entra identity (app + Key Vault cert)
#      and grants it "Azure Migrate Decide and Plan Expert" on the CENTRAL
#      project's resource group — so the appliance can register + discover.
#   2. Grants the team's principal "Azure Migrate Execute Expert" on the team's
#      OWN target resource group — so migrated VMs land there, with zero
#      standing elevation for the team.
#
# It reuses prepare-appliance-identity.sh for step 1.
#
# Usage:
#   ./onboard-team.sh \
#       <central-project-rg> <central-project-name> <central-key-vault> \
#       <team-name> <appliance-name> <target-rg-name> <team-principal-id>
#
#   team-principal-id: object ID of the custodian team's Entra GROUP (preferred)
#                      or user/SP that will execute migrations.
# ============================================================================
set -euo pipefail

CENTRAL_RG="${1:?central project resource group required}"
CENTRAL_PROJECT="${2:?central project name required}"
CENTRAL_KEY_VAULT="${3:?central key vault name required}"
TEAM_NAME="${4:?team name required}"
APPLIANCE_NAME="${5:?appliance name required (unique per appliance)}"
TARGET_RG_NAME="${6:?team target resource group required}"
TEAM_PRINCIPAL_ID="${7:?team principal (group/user/sp) object id required}"

# Built-in role: Azure Migrate Execute Expert (replication + migration).
MIGRATE_EXECUTE_ROLE_ID="1cfa4eac-9a23-481c-a793-bfb6958e836b"

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TARGET_RG_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${TARGET_RG_NAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ">> Onboarding team    : ${TEAM_NAME}"
echo ">> Central project    : ${CENTRAL_PROJECT} (rg: ${CENTRAL_RG})"
echo ">> Team appliance     : ${APPLIANCE_NAME}"
echo ">> Team target RG     : ${TARGET_RG_NAME}"
echo ">> Team principal     : ${TEAM_PRINCIPAL_ID}"
echo ""

# ---------------------------------------------------------------------------
# 1. Team appliance identity against the CENTRAL project
#    (app + KV cert + Decide-and-Plan on the central project RG)
# ---------------------------------------------------------------------------
echo ">> [1/2] Preparing appliance identity against the central project"
"${SCRIPT_DIR}/prepare-appliance-identity.sh" \
  "$CENTRAL_RG" \
  "$CENTRAL_PROJECT" \
  "$APPLIANCE_NAME" \
  "$CENTRAL_KEY_VAULT"

# ---------------------------------------------------------------------------
# 2. Execute Expert for the team on their OWN target resource group
#    Ensure the target RG exists first (create if missing).
# ---------------------------------------------------------------------------
echo ""
echo ">> [2/2] Granting Execute Expert to the team on '${TARGET_RG_NAME}'"
if ! az group show --name "$TARGET_RG_NAME" --output none 2>/dev/null; then
  echo "   target RG does not exist — creating it"
  az group create --name "$TARGET_RG_NAME" --location "$(az group show -n "$CENTRAL_RG" --query location -o tsv)" --output none
fi

az role assignment create \
  --assignee-object-id "$TEAM_PRINCIPAL_ID" \
  --assignee-principal-type Group \
  --role "$MIGRATE_EXECUTE_ROLE_ID" \
  --scope "$TARGET_RG_SCOPE" \
  --output none 2>/dev/null \
  && echo "   Execute Expert assigned to the team on the target RG." \
  || echo "   assignment already present (or principal is not a Group) — verify below."

echo ""
echo ">> Verifying the team's role assignment on the target RG"
az role assignment list \
  --assignee "$TEAM_PRINCIPAL_ID" \
  --scope "$TARGET_RG_SCOPE" \
  --query "[].{role:roleDefinitionName, scope:scope}" -o table 2>&1 || true

cat <<EOF

============================================================================
TEAM '${TEAM_NAME}' ONBOARDED.

  Central project : ${CENTRAL_PROJECT}  (appliance registers here)
  Team appliance  : ${APPLIANCE_NAME}   (see identity block above)
  Migrate targets : ${TARGET_RG_NAME}   (team holds Execute Expert here only)

Next (custodian, on-prem): install the appliance .pfx from Key Vault
'${CENTRAL_KEY_VAULT}', run the registry script with the printed values, and
register the appliance to '${CENTRAL_PROJECT}'. Discovery/assessment/migration
then run from the appliance + portal — no elevated Azure rights needed.
============================================================================
EOF
