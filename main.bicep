// ============================================================================
// Azure Migrate project provisioning
//
// Deploys an Azure Migrate project (+ the assessment project used for
// AWS -> Azure server assessments) and a supporting storage account, into a
// resource group. Intended to be run by a scoped service principal from a
// pipeline so custodian teams never touch Azure directly.
//
// Scope: resourceGroup. Create the RG first (see deploy.sh / pipeline) or let
// the pipeline create it with `az group create`.
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

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

// Storage account names: 3-24 chars, lowercase alphanumeric, globally unique.
// Derive a deterministic-but-unique name from the project + RG id.
var storageAccountName = take('mig${uniqueString(resourceGroup().id, projectName)}', 24)

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
    publicNetworkAccess: 'Enabled'
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
// Outputs
// ---------------------------------------------------------------------------

output migrateProjectId string = migrateProject.id
output migrateProjectName string = migrateProject.name
output assessmentProjectId string = assessmentProject.id
output storageAccountName string = storage.name
output resourceGroupName string = resourceGroup().name
