#!/usr/bin/env bash
# ============================================================================
# Pre-creates the Microsoft Entra identity an Azure Migrate appliance uses to
# register — the "preconfigured Entra ID application" flow:
#   https://learn.microsoft.com/azure/migrate/how-to-register-appliance-using-entra-app
#
# This moves the tenant-level (Application Developer) work OFF the custodian and
# into the pipeline. The pipeline SP (with Application.ReadWrite.OwnedBy) creates:
#   1. an app registration + service principal for the appliance
#   2. a self-signed cert IN Key Vault (private key never leaves the vault)
#   3. attaches the cert's public key to the app
#   4. assigns the app the built-in "Azure Migrate Decide and Plan Expert" role
#      on the project resource group (covers key-gen + appliance registration)
#
# It then prints the 6 values the appliance's registry script needs, plus how to
# download the .pfx from Key Vault. Installing that .pfx on the on-prem appliance
# and running the registry script remain manual (they happen on the customer box).
#
# HARD LIMIT (Microsoft): one app registration per appliance. Each appliance
# needs its own run with a distinct applianceName.
#
# Usage:
#   ./prepare-appliance-identity.sh <resource-group> <project-name> <appliance-name> <key-vault-name>
# ============================================================================
set -euo pipefail

RESOURCE_GROUP="${1:?resource group required}"
PROJECT_NAME="${2:?project name required}"
APPLIANCE_NAME="${3:?appliance name required (unique per appliance)}"
KEY_VAULT_NAME="${4:?key vault name required}"

APP_NAME="migrate-appliance-${APPLIANCE_NAME}"
CERT_NAME="appliance-${APPLIANCE_NAME}"

# Built-in role: Azure Migrate Decide and Plan Expert (key-gen + appliance reg).
MIGRATE_DECIDE_PLAN_ROLE_ID="7859c0b0-0bb9-4994-bd12-cd529af7d646"

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
PROJECT_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}"

echo ">> Appliance     : ${APPLIANCE_NAME}"
echo ">> App reg name  : ${APP_NAME}"
echo ">> Key Vault     : ${KEY_VAULT_NAME}  (cert: ${CERT_NAME})"
echo ">> Project scope : ${PROJECT_SCOPE}"
echo ""

# ---------------------------------------------------------------------------
# 1. App registration + service principal (idempotent)
# ---------------------------------------------------------------------------
APP_ID="$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)"
if [[ -z "$APP_ID" ]]; then
  echo ">> Creating app registration '${APP_NAME}'"
  APP_ID="$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)"
else
  echo ">> App registration '${APP_NAME}' already exists (${APP_ID}) — reusing."
fi
APP_OBJECT_ID="$(az ad app show --id "$APP_ID" --query id -o tsv)"

SP_OBJECT_ID="$(az ad sp list --filter "appId eq '${APP_ID}'" --query "[0].id" -o tsv)"
if [[ -z "$SP_OBJECT_ID" ]]; then
  echo ">> Creating service principal for the app"
  SP_OBJECT_ID="$(az ad sp create --id "$APP_ID" --query id -o tsv)"
else
  echo ">> Service principal already exists — reusing."
fi

# ---------------------------------------------------------------------------
# 2. Key Vault certificate (private key stays in the vault)
# ---------------------------------------------------------------------------
if [[ -z "$(az keyvault certificate list --vault-name "$KEY_VAULT_NAME" --query "[?name=='${CERT_NAME}'].name" -o tsv 2>/dev/null)" ]]; then
  echo ">> Generating self-signed cert '${CERT_NAME}' in Key Vault"
  POLICY_JSON="$(mktemp)"
  # Default self-signed policy, RSA2048/SHA256, CN matches the app.
  az keyvault certificate get-default-policy > "$POLICY_JSON"
  # Set the subject to the appliance app CN.
  python3 - "$POLICY_JSON" "CN=${APP_NAME}" <<'PY'
import json, sys
path, subject = sys.argv[1], sys.argv[2]
with open(path) as f: policy = json.load(f)
policy["x509CertificateProperties"]["subject"] = subject
with open(path, "w") as f: json.dump(policy, f)
PY
  az keyvault certificate create \
    --vault-name "$KEY_VAULT_NAME" \
    --name "$CERT_NAME" \
    --policy "@${POLICY_JSON}" \
    --output none
  rm -f "$POLICY_JSON"
else
  echo ">> Certificate '${CERT_NAME}' already exists in the vault — reusing."
fi

# Cert thumbprint (x5t) — the appliance registry needs it.
CERT_THUMBPRINT="$(az keyvault certificate show --vault-name "$KEY_VAULT_NAME" --name "$CERT_NAME" --query x509ThumbprintHex -o tsv)"

# ---------------------------------------------------------------------------
# 3. Attach the cert's PUBLIC key to the app registration
# ---------------------------------------------------------------------------
echo ">> Attaching the public certificate to the app registration"
CER_FILE="$(mktemp).cer"
# Download the public portion (PEM/CER); credential reset uploads it as a keyCredential.
az keyvault certificate download \
  --vault-name "$KEY_VAULT_NAME" \
  --name "$CERT_NAME" \
  --file "$CER_FILE" \
  --encoding PEM \
  --output none
az ad app credential reset \
  --id "$APP_ID" \
  --cert "@${CER_FILE}" \
  --append \
  --output none
rm -f "$CER_FILE"

# ---------------------------------------------------------------------------
# 4. Assign the appliance app its role on the project scope (idempotent)
# ---------------------------------------------------------------------------
echo ">> Assigning 'Azure Migrate Decide and Plan Expert' to the appliance app"
az role assignment create \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "$MIGRATE_DECIDE_PLAN_ROLE_ID" \
  --scope "$PROJECT_SCOPE" \
  --output none 2>/dev/null \
  && echo "   assigned." \
  || echo "   assignment already present — skipping."

# ---------------------------------------------------------------------------
# Output — the block the appliance registry script consumes
# ---------------------------------------------------------------------------
cat <<EOF

============================================================================
APPLIANCE IDENTITY READY — '${APPLIANCE_NAME}'

Paste these into the appliance registry script (MS docs, step 7):

  Display name              : ${APP_NAME}
  Application (client) ID   : ${APP_ID}
  Object ID                 : ${APP_OBJECT_ID}
  Tenant ID                 : ${TENANT_ID}
  Service principal Obj ID  : ${SP_OBJECT_ID}
  Certificate Thumbprint    : ${CERT_THUMBPRINT}

Get the private cert (.pfx) onto the appliance machine (audited download):

  az keyvault secret download \\
    --vault-name ${KEY_VAULT_NAME} \\
    --name ${CERT_NAME} \\
    --encoding base64 \\
    --file ${CERT_NAME}.pfx

Then, on the appliance: install ${CERT_NAME}.pfx into LocalMachine\\Personal,
run the MS registry script with the values above, and complete registration in
the appliance Config Manager.
============================================================================
EOF
