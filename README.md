# Azure Migrate Automation

Automated, audited Azure Migrate onboarding so custodian teams can run AWS→Azure
migrations **without direct or elevated Azure access**.

## Architecture — central shared project

The platform team runs **one central Migrate project** (with the private
endpoint). Each custodian team registers **their own appliance** to that shared
project and migrates VMs into **their own target resource group**. Isolation comes
from separate appliances + separate target RGs + scoped RBAC — not separate
projects (which would each need their own Private Link setup).

```
Central subscription (platform team)
├─ Migrate PROJECT (private endpoint, private DNS)   ← shared, configured once
├─ pipeline SP + Key Vault for appliance certs
└─ per-team appliance identities (app reg + cert)

Team A target RG                     Team B target RG
├─ appliance A → central project     ├─ appliance B → central project
└─ migrated VMs land here            └─ migrated VMs land here
   (Team A: Execute Expert HERE only)   (Team B: Execute Expert HERE only)
```

Two pipeline modes:

- **`platform-bootstrap`** (`main.bicep`, run once): central project + Private
  Endpoint + DNS + Key Vault. Platform team, subscription-level rights.
- **`onboard-team`** (`onboard-team.sh`, run per team): appliance identity against
  the central project + Execute Expert on the team's target RG. No new project.

## Why this approach

A scoped **service principal** runs **Bicep** from a **pipeline**. Custodian teams
trigger the pipeline; the SP does the privileged work and logs everything for audit.
Custodians end up with **at most one** scoped Azure grant — `Execute Expert` on
their own target RG.

## Repo layout

```
main.bicep                              PLATFORM BOOTSTRAP: central project + PE + DNS + storage + Key Vault
environments/platform.params.json       Central bootstrap params (fill in hub VNet/subnet IDs)
environments/dev.params.json            Single-project params (legacy / non-shared use)
scripts/create-service-principal.sh     One-time pipeline SP + custom role setup
scripts/grant-pipeline-graph-permissions.sh  One-time: Graph perm so the pipeline can create appliance apps
scripts/prepare-appliance-identity.sh   Per-appliance: app reg + KV cert + Decide-and-Plan role
scripts/onboard-team.sh                 Per-team: appliance identity (central) + Execute Expert on team RG
scripts/deploy.sh                       what-if + deploy (platform bootstrap)
scripts/set-github-secrets.sh           Push the 3 OIDC values as repo secrets
.github/workflows/deploy-migrate.yml    Platform bootstrap workflow
.github/workflows/onboard-team.yml      Team onboarding workflow
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

## Onboarding a custodian team

Run the **Onboard Custodian Team** workflow (or `scripts/onboard-team.sh`) with the
team's target RG, a unique appliance name, and the team's Entra **group** object ID.
It creates the team's appliance identity against the central project and grants the
group **Execute Expert** on their target RG only. No new Migrate project.

```bash
./scripts/onboard-team.sh \
  rg-migrate-platform migrate-platform-central migkv<...> \
  team-payments  team-payments-appliance01  rg-team-payments  <team-group-object-id>
```

## Who needs what (RBAC matrix)

| Task | Who | Rights | Automated? |
|---|---|---|---|
| Central project + Private Link + DNS | Platform (once) | Sub Contributor/UAA | `main.bicep` |
| Grant pipeline SP the Graph app-creation perm | Global Admin (once) | admin consent | `grant-pipeline-graph-permissions.sh` |
| Per-team appliance identity (app+cert+role) | **Pipeline** | the Graph grant above | `prepare-appliance-identity.sh` |
| Execute Expert on the team's target RG | **Pipeline** | `roleAssignments/write` | `onboard-team.sh` |
| Stand up + register appliance, run discovery | Custodian, on-prem | **none in Azure** | manual (their network) |
| Replicate + migrate (Execute) | Custodian | Execute Expert on **their RG only** | portal-driven |

Custodians hold **at most one** scoped Azure role (`Execute Expert` on their own RG)
and never anything tenant-level.

## Security notes

- Custodian teams get **zero** elevated Azure access — a single scoped `Execute
  Expert` role on their own target RG, and pipeline trigger rights.
- Central project defaults to `publicNetworkAccess: Disabled` (Private Link only).
- Storage: `allowBlobPublicAccess: false`, `minimumTlsVersion: TLS1_2`, HTTPS-only.
- Prefer OIDC over the long-lived SP secret for anything beyond the prototype.
- The custom role is `AssignableScopes`-bound to one subscription; widen deliberately.
- Private Link config is a platform action (needs sub-level rights) — never a custodian one.
