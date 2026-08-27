// ============================================================================
// Azure Migrate — appliance support resources (for the PRE-DEPLOYED project)
//
// The central Azure Migrate project, its assessment project, supporting storage,
// networking, DNS, and the private endpoint are ALREADY provisioned by the
// client platform / landing-zone build. This template does NOT create them.
//
// It adds only the resources this automation needs, into the EXISTING project's
// resource group:
//   - Key Vault for the appliance certificates the pipeline generates
//     (+ Certificates Officer for the pipeline SP)
//   - optional Recovery Services vault for AGENT-BASED migration (AWS/physical)
//
// Run by the platform team, into the central project's resource group. Custodian
// teams are onboarded separately (scripts/onboard-team.sh).
//
// Scope: resourceGroup (the central project's RG).
// ============================================================================

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Name of the EXISTING central Azure Migrate project. Used only for deterministic naming/tagging — the project itself is not created here.')
@minLength(2)
@maxLength(60)
param projectName string

@description('Azure region for the support resources. Keep consistent with the central project.')
param location string = resourceGroup().location

@description('Owning team label for tagging/audit.')
param custodianTeam string = 'platform'

@description('Free-form tags applied to every resource.')
param tags object = {}

@description('Deploy a Key Vault to hold appliance certificates (preconfigured-app flow). Set false to skip.')
param deployApplianceKeyVault bool = true

@description('Object ID of the pipeline service principal, granted Key Vault Certificates Officer so it can generate appliance certs. Required when deployApplianceKeyVault is true.')
param pipelineSpObjectId string = ''

@description('Deploy an exclusive Recovery Services vault for AGENT-BASED migration (AWS/GCP/physical replication appliance). Not needed for agentless VMware/Hyper-V. See README "AWS / agent-based" section.')
param deployReplicationVault bool = false

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

// Key Vault names: 3-24 chars, alphanumeric + hyphens, globally unique.
var keyVaultName = take('migkv${uniqueString(resourceGroup().id, projectName)}', 24)

// Built-in role: Key Vault Certificates Officer (manage certificates).
var kvCertsOfficerRoleId = 'a4417e6f-fecd-4de8-b567-7b0420556985'

// Recovery Services vault name (agent-based / replication appliance).
var replicationVaultName = take('rsv-mig-${uniqueString(resourceGroup().id, projectName)}', 50)

var commonTags = union(tags, {
  managedBy: 'azure-migrate-automation'
  custodianTeam: custodianTeam
  provisionedVia: 'bicep-pipeline'
})

// ---------------------------------------------------------------------------
// Appliance certificate Key Vault (preconfigured-app registration flow)
//
// Holds the self-signed cert the Azure Migrate appliance authenticates with.
// RBAC-authorization mode; the pipeline SP gets Certificates Officer so it can
// generate certs from the pipeline. Soft-delete is on (Azure default) — a
// redeployed vault of the same name must be RECOVERED, not recreated.
// ---------------------------------------------------------------------------

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = if (deployApplianceKeyVault) {
  name: keyVaultName
  location: location
  tags: commonTags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

// Grant the pipeline SP the ability to create/manage certificates in the vault.
resource kvCertsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployApplianceKeyVault && !empty(pipelineSpObjectId)) {
  name: guid(keyVault.id, pipelineSpObjectId, kvCertsOfficerRoleId)
  scope: keyVault
  properties: {
    principalId: pipelineSpObjectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvCertsOfficerRoleId)
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Recovery Services vault for AGENT-BASED migration (AWS / GCP / physical).
//
// AWS EC2 migrates as a *physical server* — agent-based — which needs a separate
// Replication Appliance and a NEW, EXCLUSIVE Recovery Services vault. Pre-creating
// the empty vault here removes the "create a vault during registration" step from
// the platform team's one-time replication-appliance setup.
//
// The replication appliance is registered ONCE by the platform team (device-code;
// needs Contributor+UAA on this subscription) and shared. Agentless (VMware/
// Hyper-V) does not need this vault at all. See README "AWS / agent-based migration".
// ---------------------------------------------------------------------------

resource replicationVault 'Microsoft.RecoveryServices/vaults@2024-04-01' = if (deployReplicationVault) {
  name: replicationVaultName
  location: location
  tags: commonTags
  sku: {
    name: 'RS0'
    tier: 'Standard'
  }
  properties: {}
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output resourceGroupName string = resourceGroup().name
output keyVaultName string = deployApplianceKeyVault ? keyVault.name : ''
output replicationVaultName string = deployReplicationVault ? replicationVault.name : ''
