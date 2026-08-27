#!/usr/bin/env bash
# ============================================================================
# Onboards a custodian team onto the SHARED central Azure Migrate project.
#
# Central-project model: the platform team runs ONE Migrate project (with the
# private endpoint). Each custodian team registers their OWN appliance to that
# shared project and migrates VMs into their OWN landing zone. No new Migrate
# project is created per team.
#
# This script does the ONE thing only the platform pipeline can do — the
# tenant-level work custodians can't do for themselves:
#   * pre-create the team's appliance Entra identity (app + Key Vault cert) and
#     grant it "Azure Migrate Decide and Plan Expert" on the CENTRAL project's
#     resource group, so the appliance can register + discover.
#
# It deliberately does NOT touch the team's landing-zone subscription. Custodian
# teams already own their landing zones and already hold the rights to create the
# migrated VMs there (Owner/Contributor or Azure Migrate Execute Expert, granted
# by the landing-zone process — out of scope for this pipeline).
#
# It reuses prepare-appliance-identity.sh.
#
# Usage:
#   ./onboard-team.sh \
#       <central-project-rg> <central-project-name> <central-key-vault> \
#       <team-name> <appliance-name>
# ============================================================================
set -euo pipefail

CENTRAL_RG="${1:?central project resource group required}"
CENTRAL_PROJECT="${2:?central project name required}"
CENTRAL_KEY_VAULT="${3:?central key vault name required}"
TEAM_NAME="${4:?team name required}"
APPLIANCE_NAME="${5:?appliance name required (unique per appliance)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ">> Onboarding team    : ${TEAM_NAME}"
echo ">> Central project    : ${CENTRAL_PROJECT} (rg: ${CENTRAL_RG})"
echo ">> Team appliance     : ${APPLIANCE_NAME}"
echo ""

# ---------------------------------------------------------------------------
# Team appliance identity against the CENTRAL project
# (app + KV cert + Decide-and-Plan on the central project RG)
# ---------------------------------------------------------------------------
echo ">> Preparing appliance identity against the central project"
"${SCRIPT_DIR}/prepare-appliance-identity.sh" \
  "$CENTRAL_RG" \
  "$CENTRAL_PROJECT" \
  "$APPLIANCE_NAME" \
  "$CENTRAL_KEY_VAULT"

cat <<EOF

============================================================================
TEAM '${TEAM_NAME}' ONBOARDED.

  Central project : ${CENTRAL_PROJECT}  (appliance registers here)
  Team appliance  : ${APPLIANCE_NAME}   (see identity block above)

The migration TARGET is the team's own landing zone — this pipeline does not
grant anything there. Teams already hold the rights to create migrated VMs in
their landing zone (Owner/Contributor or Azure Migrate Execute Expert, via the
landing-zone process).

Next (custodian, on-prem): install the appliance .pfx from Key Vault
'${CENTRAL_KEY_VAULT}', run the registry script with the printed values, and
register the appliance to '${CENTRAL_PROJECT}'. Discovery, assessment, and
migration then run from the appliance + portal.
============================================================================
EOF
