# Custodian Runbook — Azure Migrate (per team)

Self-service steps for a custodian team **after** the platform pipeline has
onboarded you. The pipeline has already created your appliance's Entra identity,
its certificate (in the central Key Vault), and given it the discovery role on
the central Migrate project. Your job from here is on-prem + portal — **no
elevated Azure rights are needed**.

> **What you were handed by the onboarding pipeline** (from the workflow run log):
> `Application (client) ID`, `Object ID`, `Tenant ID`, `Service principal Object
> ID`, `Certificate Thumbprint`, the **central Key Vault name**, the **central
> project name**, and your **appliance name**. Keep these — you paste them in
> Step 3.

---

## Prerequisites (confirm before you start)

- The onboarding pipeline ran for your team (you have the identity block above).
- A Windows Server **2022 or 2025** host for the appliance: **32 GB RAM, 8 vCPUs,
  ~80 GB disk**, with outbound internet (direct or via proxy).
- Local **administrator** rights on that appliance host.
- Credentials to your **source** environment (vCenter / Hyper-V host / server
  WinRM+SSH) — these stay on-prem; Azure never sees them.
- Ability to read **one secret** from the central Key Vault (the `.pfx`). If you
  can't, ask the platform team to grant *Key Vault Secrets User* on that vault, or
  to hand you the `.pfx` out of band.

---

## Step 1 — Deploy the appliance

Pick the method for your source platform:

- **VMware** — download the **OVA** from the Migrate project (or the fixed MS link)
  and deploy it as a VM on vCenter.
- **Hyper-V** — download the **VHD** (zip) and deploy on a Hyper-V host.
- **Physical / AWS EC2 / other cloud / Azure Gov** — download the **PowerShell
  installer** (`AzureMigrateInstaller.zip`) and run it on a Windows Server host.

Verify the download hash (`CertUtil -HashFile <file> SHA256`) against the value
on the Migrate appliance docs page before deploying.

Give the appliance a static or reserved IP and confirm outbound access to the
Azure Migrate URLs (the appliance runs a connectivity check on first boot).

> This runbook covers the **discovery/assessment appliance** — the one whose identity
> the pipeline pre-created for you. **AWS/physical migration also needs a separate
> *replication* appliance**, which the **platform team registers once and shares** (it
> requires subscription-level rights you don't have). You don't set that up — see Step 7b.

---

## Step 2 — Install the appliance certificate

On the appliance host:

```powershell
# From a machine with Key Vault access, download the private cert (.pfx):
az keyvault secret download `
  --vault-name <CENTRAL-KEY-VAULT> `
  --name appliance-<YOUR-APPLIANCE-NAME> `
  --encoding base64 `
  --file appliance-<YOUR-APPLIANCE-NAME>.pfx
```

Copy the `.pfx` to the appliance, double-click it, and install into:
- Store location: **Local Machine**
- Certificate store: **Personal**

(You'll be prompted for the password only if one was set; the KV-generated cert
is imported without a separate password.)

---

## Step 3 — Point the appliance at your pre-created identity

On the appliance host, run the Microsoft registry script (from
[Register appliance using a preconfigured Entra app](https://learn.microsoft.com/azure/migrate/how-to-register-appliance-using-entra-app),
step 7). It writes the identity values under
`HKLM:\SOFTWARE\Microsoft\AzureAppliance`. When prompted, paste the values the
onboarding pipeline printed:

| Prompt | Value |
|---|---|
| Entra app tenant id | `Tenant ID` |
| Entra app client id | `Application (client) ID` |
| Entra app object id | `Object ID` |
| Entra app display name | `migrate-appliance-<your-appliance-name>` |
| Entra app SPN object id | `Service principal Object ID` |
| Entra app cert thumbprint | `Certificate Thumbprint` |

Open Registry Editor → `AzureAppliance` and confirm the values took.

---

## Step 4 — Register the appliance to the central project

1. Open the appliance **Configuration Manager** (browser on the appliance host).
2. Clear the browser cache / reload so it starts the Entra-app auth flow.
3. It authenticates as your **pre-created app** (no sign-in prompt, no Application
   Developer role needed) and registers to the **central Migrate project**.
4. The config manager shows your Entra app name once registration completes.

> If registration errors on permissions, it's almost always the cert (wrong store
> or thumbprint mismatch) or a registry value typo — recheck Steps 2–3. You should
> **not** need any Azure role to get past this; the pipeline pre-granted it.

---

## Step 5 — Discover

1. In the Config Manager, add your **source credentials** and source details:
   - VMware: vCenter server + credentials (appliance talks to vCenter on **443**).
   - Hyper-V: host list + credentials (**WinRM 5986/HTTPS**).
   - Physical/other: server list (**WinRM 5986** for Windows, **SSH 22** for Linux).
2. **Start discovery.** The appliance streams inventory + performance data to the
   central project. Rough cadence: configuration every ~15–30 min, performance
   continuously, software inventory / SQL / web apps once every 24 h.
3. Your servers appear in the central project, attributable to **your appliance**
   (filter by appliance name).

---

## Step 6 — Group & assess (in the Azure portal)

1. In the central Migrate project, create a **Group** of your servers (a migration
   wave). Build your own groups — this is how you scope your team's work.
2. Create an **assessment** (Azure VM / cost) or a **business case** on that group.
   For AWS→Azure this is your EC2 → Azure VM right-sizing.
3. Review and export. Iterate on the group / assessment settings as needed.

> Note: everyone with access to the central project can *see* all teams' discovered
> inventory and groups (Azure Migrate has no sub-project RBAC). Your **Groups** keep
> your work organized; they don't hide it from other teams.

---

## Step 7 — Migrate (Execute) into your landing zone

You migrate into **your own landing zone**, using rights you already hold there. On the
**central project** you need only **RG-scoped `Azure Migrate Execute Expert`** — no
subscription-scope grant.

**First, know which path applies — it depends on your source:**

| Source | Method | Extra setup |
|---|---|---|
| VMware / Hyper-V | **Agentless** | none — nothing installed on source VMs |
| **AWS EC2** / GCP / physical / other cloud | **Agent-based** | a **shared Replication Appliance** (registered once by the platform team) + **Mobility Agent** pushed to each source VM |

> **AWS is agent-based — there is no agentless option.** You do **not** register the
> replication appliance yourself (it needs subscription-level rights); the **platform team
> registers one shared replication appliance** and you select it from a drop-down. If you
> don't see a replication appliance available, ask the platform team to set it up.

### 7a. Agentless (VMware / Hyper-V)

1. Project → **Execute → Migration → Start execution** → **Servers/VMs → Azure VM**;
   select your appliance, **Migration mode: Agentless**.
2. **Target settings:** your subscription, target region, **your landing-zone RG**,
   VNet/subnet, availability + disk options.
3. **Start replication** → Preparation → Testing → Completion.

### 7b. Agent-based (AWS EC2 / physical)

1. Project → **Execute → Migration → Start execution** → **Servers/VMs → Azure VM**.
2. Under **How will you select workloads → Other sources**, choose **From a replication
   appliance (Physical or others)** and **select the shared replication appliance**.
3. Provide **guest credentials** — used to **push-install the Mobility Agent** onto each
   source EC2 VM during Enable Replication.
4. **Target settings:** your subscription, target region, **your landing-zone RG**,
   VNet/subnet, disk options.
5. **Start replication** → Preparation → Testing → Completion.

### Both paths — finish the same way

Once replication reaches the Testing stage:

- **Test migration** into a non-prod VNet (recommended — doesn't touch source).
- **Migrate (cutover):** optionally shut down the source for a no-data-loss final
  sync; the Azure VMs are created in your RG.
- **Complete migration** to stop replication and clean up. Then post-migration:
  re-point DNS, validate the app, decommission the source, update docs.

Monitor with PowerShell if you like:
```powershell
Get-AzMigrateServerMigrationStatus `
  -ProjectName "<central-project>" -ResourceGroupName "<central-rg>" `
  -ApplianceName "<your-appliance-name>"
```

---

## Quick reference

| Thing | Where |
|---|---|
| Appliance identity values | onboarding pipeline run log |
| Private cert (`.pfx`) | central Key Vault, secret `appliance-<appliance-name>` |
| Registers to | the **central** Migrate project (shared) |
| Migrates into | **your** landing-zone RG (your existing rights) |
| Azure roles you need | **RG-scoped `Azure Migrate Execute Expert`** on the central project (execute phase) + your existing LZ rights on the target. **No subscription-scope grant.** |
| Replication appliance (AWS/physical only) | **platform-managed, shared** — you select it, you don't register it |
| Source credentials | on-prem only (vCenter / Hyper-V / WinRM / SSH) |
