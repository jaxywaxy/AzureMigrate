#!/usr/bin/env bash
# ============================================================================
# Deploys the Azure Migrate Bicep to a resource group.
#
# Local test:   az login (or SP login), then:
#     ./deploy.sh <resource-group> environments/dev.params.json
#
# In the pipeline this same script runs after the SP has logged in.
# ============================================================================
set -euo pipefail

RESOURCE_GROUP="${1:?resource group required}"
PARAM_FILE="${2:?params file required, e.g. environments/dev.params.json}"
LOCATION="${3:-australiaeast}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="${SCRIPT_DIR}/main.bicep"

echo ">> Ensuring resource group '${RESOURCE_GROUP}' exists in ${LOCATION}"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none

echo ">> Validating deployment (what-if)"
az deployment group what-if \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$TEMPLATE" \
  --parameters "@${PARAM_FILE}"

echo ">> Deploying"
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$TEMPLATE" \
  --parameters "@${PARAM_FILE}" \
  --query "properties.outputs" \
  --output json

echo ">> DONE."
