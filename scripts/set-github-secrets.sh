#!/usr/bin/env bash
# ============================================================================
# Sets the GitHub repo secrets the OIDC pipeline needs.
# Requires: gh CLI authenticated with repo access.
#
# Usage:
#   ./set-github-secrets.sh <org/repo> <client-id> <tenant-id> <subscription-id>
# ============================================================================
set -euo pipefail

GH_REPO="${1:?org/repo required}"
CLIENT_ID="${2:?client id required}"
TENANT_ID="${3:?tenant id required}"
SUBSCRIPTION_ID="${4:?subscription id required}"

echo ">> Setting OIDC secrets on ${GH_REPO}"
gh secret set AZURE_CLIENT_ID       --repo "$GH_REPO" --body "$CLIENT_ID"
gh secret set AZURE_TENANT_ID       --repo "$GH_REPO" --body "$TENANT_ID"
gh secret set AZURE_SUBSCRIPTION_ID --repo "$GH_REPO" --body "$SUBSCRIPTION_ID"

echo ">> Done. Current secrets:"
gh secret list --repo "$GH_REPO"
