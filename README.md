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
├─ Migrate PROJECT (publicNetworkAccess: Disabled)   ← shared; PE wired by client platform
├─ pipeline SP + Key Vault for appliance certs
└─ per-team appliance identities (app reg + cert)

Team A target RG                     Team B target RG
├─ appliance A → central project     ├─ appliance B → central project
└─ migrated VMs land here            └─ migrated VMs land here
   (Team A: Execute Expert HERE only)   (Team B: Execute Expert HERE only)
```

Two pipeline modes:

- **`platform-bootstrap`** (`main.bicep`, run once): central project (set to
  `publicNetworkAccess: Disabled`) + storage + Key Vault. The client's platform team
  owns the subscription, networking, DNS, and **private-endpoint creation** — this
  template does not create them; it outputs the target ID + groupId + DNS zone name
  the platform team wires the PE against.
- **`onboard-team`** (`onboard-team.sh`, run per team): the team's appliance identity
  against the central project (Decide-and-Plan on the central RG). No new project,
  and nothing in the team's landing zone.

## How a team's VMs are grouped

Within the shared central project, a team's servers are grouped two ways:

- **By their appliance** (automatic) — each team registers their own appliance, so
  its discovered servers are attributable to that appliance. Filter by appliance in
  the portal, or scope PowerShell with `Get-AzMigrateServerMigrationStatus -ApplianceName`.
- **By Groups** (manual) — an Azure Migrate *Group* is a named set of servers assessed
  and migrated together as a wave. Each team builds their own.

> **Visibility caveat:** grouping is organizational, not security isolation. Azure
> Migrate has **no sub-project RBAC** — the built-in roles scope to the whole project.
> Anyone with a role on the central project can *see* all discovered inventory and all
> groups, not just their own. This estate accepts that (shared visibility of discovery
> data). If teams must be prevented from seeing each other's inventory, use
> **project-per-team** instead — at the cost of wiring Private Link per team.

## Why this approach

A scoped **service principal** runs **Bicep** from a **pipeline**. Custodian teams
trigger the pipeline; the SP does the privileged work and logs everything for audit.
The pipeline operates only in the central Migrate subscription; teams migrate into
their own landing zones using rights they already hold.

## Repo layout

```
main.bicep                              PLATFORM BOOTSTRAP: central project (private) + storage + Key Vault
environments/platform.params.json       Central bootstrap params
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
central project details, the team name, and a unique appliance name. It creates the
team's appliance identity against the central project (Decide-and-Plan on the
**central** RG) so the appliance can register and discover. That's all — no new
Migrate project, and **nothing is touched in the team's landing zone**.

```bash
./scripts/onboard-team.sh \
  rg-migrate-platform migrate-platform-central migkv<...> \
  team-payments  team-payments-appliance01
```

**The migration target is the team's own landing zone — out of scope here.**
Custodian teams already own their landing zones and already hold the rights to
create the migrated VMs there (Owner/Contributor, or `Azure Migrate Execute Expert`
granted by the landing-zone process). This pipeline never reaches into a team's
subscription; it stays entirely within the central Migrate subscription.

## Who needs what (RBAC matrix)

| Task | Who | Rights | Automated? |
|---|---|---|---|
| Subscription, networking, DNS, Migrate project's private endpoint | **Client platform** (pre-provided) | Sub-level | out of scope for this repo |
| Central Migrate project (private) + storage + Key Vault | Platform (once) | project-scope deploy | `main.bicep` |
| Grant pipeline SP the Graph app-creation perm | Global Admin (once) | admin consent | `grant-pipeline-graph-permissions.sh` |
| Per-team appliance identity + Decide-and-Plan on **central** RG | **Pipeline** | the Graph grant + `roleAssignments/write` in central sub | `onboard-team.sh` → `prepare-appliance-identity.sh` |
| Stand up + register appliance, run discovery/assess | Custodian, on-prem | **none in Azure** | manual (their network) |
| Replicate + migrate (Execute) into their landing zone | Custodian | rights they **already hold** on their own LZ | portal-driven |

The pipeline operates **only** in the central Migrate subscription. It never touches
a team's landing zone — teams already have the rights to create migrated VMs there.

## Security notes

- Custodian teams get **zero** elevated Azure access from this pipeline — they use
  the landing-zone rights they already hold, plus pipeline trigger rights.
- Central project defaults to `publicNetworkAccess: Disabled` (Private Link only).
- Storage: `allowBlobPublicAccess: false`, `minimumTlsVersion: TLS1_2`, HTTPS-only.
- Prefer OIDC over the long-lived SP secret for anything beyond the prototype.
- The custom role is `AssignableScopes`-bound to one subscription; widen deliberately.
- Private Link config is a platform action (needs sub-level rights) — never a custodian one.
