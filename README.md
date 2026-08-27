# Azure Migrate Automation

Automated, audited provisioning of Azure Migrate projects so custodian teams can
spin up AWS→Azure migration assessments without direct Azure access.

## Why this approach

A scoped **service principal** runs **Bicep** from a **pipeline**. No template
specs, no extra infra layers. Custodian teams trigger the pipeline; the SP does
the deploy and logs everything for audit.

## Repo layout

```
main.bicep                              Migrate project + assessment project + storage + appliance Key Vault
environments/dev.params.json            Per-environment parameters
scripts/create-service-principal.sh     One-time pipeline SP + custom role setup
scripts/grant-pipeline-graph-permissions.sh  One-time: Graph perm so the pipeline can create appliance apps
scripts/prepare-appliance-identity.sh   Per-appliance: app reg + KV cert + role (preconfigured-app flow)
scripts/deploy.sh                       what-if + deploy (used locally and by the pipeline)
scripts/set-github-secrets.sh           Push the 3 OIDC values as repo secrets
.github/workflows/deploy-migrate.yml    GitHub Actions workflow (OIDC or SP-secret auth)
```

## What gets deployed

| Resource | Type | Purpose |
|---|---|---|
| Migrate project | `Microsoft.Migrate/migrateProjects` | Container for discovery/assessment tools |
| Assessment project | `Microsoft.Migrate/assessmentProjects` | Holds server assessments (EC2→Azure VM sizing) |
| Storage account | `Microsoft.Storage/storageAccounts` | Discovery / dependency data; TLS1.2, no public blob |

## 1. Test locally (personal subscription)

```bash
az login
./scripts/deploy.sh rg-migrate-dev environments/dev.params.json
```

`deploy.sh` creates the RG, runs `what-if`, then deploys and prints outputs.

## 2. Create the service principal (one-time, by an Owner)

```bash
# Subscription-scoped:
./scripts/create-service-principal.sh <subscription-id>

# Or narrowed to a single RG (tighter blast radius):
./scripts/create-service-principal.sh <subscription-id> rg-migrate-dev
```

This creates a least-privilege custom role (`Microsoft.Migrate/*`,
`Microsoft.OffAzure/*`, scoped storage + deployment actions) and an SP bound to
it. Capture the JSON output into your secret store.

## 3. Pipeline auth

**Preferred — OIDC (no stored secret):** set repo secrets `AZURE_CLIENT_ID`,
`AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` and add a federated credential on the
SP for this repo/branch. The workflow's `id-token: write` permission is already set.

**Fallback — SP secret:** store the `create-for-rbac --json-auth` output as
`AZURE_CREDENTIALS` and uncomment the SP-secret login block in
`.github/workflows/deploy-migrate.yml`.

## Appliance identity (preconfigured Entra app)

Registering an Azure Migrate appliance normally makes the appliance create its own
Microsoft Entra app registration during its wizard — which requires the installer to
hold the Entra **Application Developer** role. To keep custodian teams off tenant-level
rights, the pipeline uses Microsoft's
[preconfigured Entra app](https://learn.microsoft.com/azure/migrate/how-to-register-appliance-using-entra-app)
flow and **pre-creates that identity for them**.

**One-time, by a Global Admin:** grant the pipeline SP the single elevated permission
it needs to create app registrations, and refresh its custom role:

```bash
./scripts/grant-pipeline-graph-permissions.sh   # Graph Application.ReadWrite.OwnedBy + admin consent
./scripts/create-service-principal.sh <sub-id> jaxywaxy/AzureMigrate   # re-run: expands the custom role
```

**Per appliance (in the pipeline):** the workflow's `prepareApplianceIdentity` input
(default on) runs `scripts/prepare-appliance-identity.sh`, which:

1. creates an app registration + SP named `migrate-appliance-<applianceName>`,
2. generates a self-signed cert **inside Key Vault** (private key never leaves it),
3. attaches the cert's public key to the app,
4. assigns the app the built-in **Azure Migrate Decide and Plan Expert** role on the
   project resource group, and
5. prints the 6 IDs the appliance registry script needs.

> **One app per appliance** (Microsoft limit). Use a distinct `applianceName` per
> appliance — you can't reuse an app registration, even within the same project.

**What stays manual (on the on-prem appliance box — CI can't reach it):**

1. Download the private cert from Key Vault (audited):
   `az keyvault secret download --vault-name <kv> --name appliance-<name> --encoding base64 --file appliance-<name>.pfx`
2. Install the `.pfx` into `LocalMachine\Personal` on the appliance.
3. Run the MS registry script with the 6 printed values, then finish in the appliance
   Config Manager.

The custodian never needs Application Developer — only the ability to run the pipeline
and read one Key Vault secret.

## Adding a new custodian team / project

Copy `environments/dev.params.json` to `environments/<team>.params.json`, set
`projectName` and `custodianTeam`, add the name to the workflow's `environment`
choice list. One params file per project keeps the audit trail clean.

## Security notes

- Custodian teams get **zero** direct Azure access — only pipeline trigger rights.
- Storage: `allowBlobPublicAccess: false`, `minimumTlsVersion: TLS1_2`, HTTPS-only.
- Prefer OIDC over the long-lived SP secret for anything beyond the prototype.
- The custom role is `AssignableScopes`-bound to one subscription; widen deliberately.
