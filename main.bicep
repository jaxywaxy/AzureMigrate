// ============================================================================
// Azure Migrate — PLATFORM BOOTSTRAP (central shared project)
//
// Deploys the ONE central Azure Migrate project the platform team owns:
//   - migrate project + assessment project (public network access off by default)
//   - supporting storage
//   - optional Private Endpoint + Private DNS zones onto the hub VNet
//   - Key Vault for appliance certificates
//
// Custodian teams SHARE this project — each registers their own appliance to it
// and migrates into their own target RG. They are onboarded separately (see
// scripts/onboard-team.sh); this template is run ONCE by the platform team.
//
// Private Link note: configuring the private endpoint needs subscription
// Contributor/UAA/Owner and is a platform action — never a custodian one.
//
// Scope: resourceGroup. Create the RG first (see deploy.sh / pipeline).
// ============================================================================

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Name of the Azure Migrate project. Must be unique within the subscription/region.')
@minLength(2)
@maxLength(60)
param projectName string

@description('Azure region for the Migrate project and storage. Migrate metadata region — keep consistent per subscription.')
param location string = resourceGroup().location

@description('The custodian team / workload this project belongs to. Used for tagging and audit.')
param custodianTeam string

@description('Free-form tags applied to every resource.')
param tags object = {}

@description('Storage account SKU for discovery/dependency data.')
@allowed([
  'Standard_LRS'
  'Standard_GRS'
  'Standard_ZRS'
])
param storageSku string = 'Standard_LRS'

@description('Deploy a Key Vault to hold appliance certificates (preconfigured-app flow). Set false to skip.')
param deployApplianceKeyVault bool = true

@description('Object ID of the pipeline service principal, granted Key Vault Certificates Officer so it can generate appliance certs. Required when deployApplianceKeyVault is true.')
param pipelineSpObjectId string = ''

@description('Network access to the central Migrate project. Disabled = Private Link only. The client platform team creates the private endpoint against this project (networking + DNS are pre-provisioned on the client site).')
@allowed([
  'Disabled'
  'Enabled'
])
param projectPublicNetworkAccess string = 'Disabled'

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

// Storage account names: 3-24 chars, lowercase alphanumeric, globally unique.
// Derive a deterministic-but-unique name from the project + RG id.
var storageAccountName = take('mig${uniqueString(resourceGroup().id, projectName)}', 24)

// Key Vault names: 3-24 chars, alphanumeric + hyphens, globally unique.
var keyVaultName = take('migkv${uniqueString(resourceGroup().id, projectName)}', 24)

// Built-in role: Key Vault Certificates Officer (manage certificates).
var kvCertsOfficerRoleId = 'a4417e6f-fecd-4de8-b567-7b0420556985'

var commonTags = union(tags, {
  managedBy: 'azure-migrate-automation'
  custodianTeam: custodianTeam
  provisionedVia: 'bicep-pipeline'
})

// ---------------------------------------------------------------------------
// Migrate project
// ---------------------------------------------------------------------------

resource migrateProject 'Microsoft.Migrate/migrateProjects@2020-05-01' = {
  name: projectName
  location: location
  // Tags are accepted by the REST API but absent from Bicep's bundled type
  // index for this (older) API version — suppress the false BCP187 warning.
  #disable-next-line BCP187
  tags: commonTags
  properties: {
    // registeredTools left empty; discovery/assessment tools register at runtime.
  }
}

// Assessment project — the resource that actually holds server assessments
// (this is what an AWS EC2 -> Azure VM sizing exercise writes into).
resource assessmentProject 'Microsoft.Migrate/assessmentProjects@2023-03-15' = {
  name: '${projectName}-assessment'
  location: location
  tags: commonTags
  properties: {
    assessmentSolutionId: migrateProject.id
    projectStatus: 'Active'
    publicNetworkAccess: projectPublicNetworkAccess
  }
}

// ---------------------------------------------------------------------------
// Supporting storage
// ---------------------------------------------------------------------------

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: commonTags
  sku: {
    name: storageSku
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    encryption: {
      services: {
        blob: {
          enabled: true
        }
        file: {
          enabled: true
        }
      }
      keySource: 'Microsoft.Storage'
    }
  }
}

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
// Private Link is NOT created here.
//
// The client's platform team owns networking + DNS + private-endpoint creation.
// This template only sets the project to private (publicNetworkAccess:
// Disabled) and exposes the values that team needs to wire the endpoint:
//   - privateLinkTargetId  → the resource the PE connects to (assessment project)
//   - privateLinkGroupId   → 'Default'
//   - privateDnsZoneName   → privatelink.prod.migration.windowsazure.com
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output migrateProjectId string = migrateProject.id
output migrateProjectName string = migrateProject.name
output assessmentProjectId string = assessmentProject.id
output storageAccountName string = storage.name
output resourceGroupName string = resourceGroup().name
output keyVaultName string = deployApplianceKeyVault ? keyVault.name : ''
output projectPublicNetworkAccess string = projectPublicNetworkAccess

// Values the client platform team needs to create the Migrate project's PE.
output privateLinkTargetId string = assessmentProject.id
output privateLinkGroupId string = 'Default'
output privateDnsZoneName string = 'privatelink.prod.migration.windowsazure.com'
