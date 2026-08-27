# Azure Migrate Automation

Automated, audited provisioning of Azure Migrate projects so custodian teams can
spin up AWS→Azure migration assessments without direct Azure access.

## Why this approach

A scoped **service principal** runs **Bicep** from a **pipeline**. No template
specs, no extra infra layers. Custodian teams trigger the pipeline; the SP does
the deploy and logs everything for audit.

## Repo layout

```
main.bicep                          Migrate project + assessment project + storage
environments/dev.params.json        Per-environment parameters
scripts/create-service-principal.sh One-time SP + custom role setup
scripts/deploy.sh                   what-if + deploy (used locally and by the pipeline)
pipelines/deploy-migrate.yml        GitHub Actions workflow (OIDC or SP-secret auth)
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
`pipelines/deploy-migrate.yml`.

## Adding a new custodian team / project

Copy `environments/dev.params.json` to `environments/<team>.params.json`, set
`projectName` and `custodianTeam`, add the name to the workflow's `environment`
choice list. One params file per project keeps the audit trail clean.

## Security notes

- Custodian teams get **zero** direct Azure access — only pipeline trigger rights.
- Storage: `allowBlobPublicAccess: false`, `minimumTlsVersion: TLS1_2`, HTTPS-only.
- Prefer OIDC over the long-lived SP secret for anything beyond the prototype.
- The custom role is `AssignableScopes`-bound to one subscription; widen deliberately.
