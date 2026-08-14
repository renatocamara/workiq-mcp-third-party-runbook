# Prerequisites: complete BEFORE the working session

Work through this checklist ahead of time. Every item here maps to a blocker we hit during validation; completing them in advance means the working session is spent testing, not unblocking.

## 1. Pick the right tenant

The single biggest time sink in our validation was starting in tenants that could never work. Verify your target tenant has:

- [ ] **Microsoft 365 workloads in use** (Exchange mailboxes, Teams, SharePoint/OneDrive). Work IQ grounds on content; an Azure-only or Entra-only tenant has nothing to query.
- [ ] **M365 Copilot licenses available** for the users who will authenticate through the agent.
- [ ] **An Azure subscription in the same tenant** that can be used for pay-as-you-go billing (the setup creates a resource group named `copilot-credits-rg`).

Quick verification from any machine with Azure CLI (read-only, safe to run):

```bash
az login --use-device-code
# Does the tenant have M365/Copilot SKUs at all?
az rest --method get --url "https://graph.microsoft.com/v1.0/subscribedSkus?\$select=skuPartNumber,prepaidUnits,consumedUnits" \
  | jq -r '.value[] | "\(.skuPartNumber)\tavailable:\(.prepaidUnits.enabled - .consumedUnits)"'
# Does YOUR test user hold a Copilot license?
az rest --method get --url "https://graph.microsoft.com/v1.0/me/licenseDetails" | jq -r '.value[].skuPartNumber'
```

You want to see an M365 SKU (E3/E5) and a Copilot SKU (for example `Microsoft_365_Copilot`) in the first list, and the Copilot SKU in the second. If not, fix licensing before anything else.

## 2. Identity roles (this is TWO separate systems)

We lost significant time to the distinction between Azure RBAC and Entra directory roles. You need both, for different steps:

| Step | System | Role needed |
|---|---|---|
| Tenant enablement script + app registration + admin consent | **Entra directory role** | Global Administrator (or Application Administrator for app steps; consent needs GA/PRA) |
| Pay-as-you-go billing activation (creates an Azure resource group) | **Azure RBAC on the subscription** | Contributor (or Owner) on the billing subscription |

Important gotchas, all field-tested:

- **"Owner" of Azure subscriptions does NOT grant Entra directory permissions**, and Global Administrator does NOT grant Azure RBAC. They are independent. Check both.
- **If your admin role is PIM-eligible, activate it first** (Entra portal > Privileged Identity Management > My roles > Activate), then sign in again in the CLI. Tokens issued before activation do not carry the role.
- Verify your ACTIVE directory roles (not just assigned/eligible):

```bash
az rest --method get \
  --url "https://graph.microsoft.com/v1.0/me/memberOf/microsoft.graph.directoryRole?\$select=displayName" \
  | jq -r '.value[].displayName'
```

- Verify your Azure RBAC on the billing subscription:

```bash
az role assignment list --assignee "<your-upn>" --scope "/subscriptions/<sub-id>" -o table
```

## 3. Linux workstation requirements

Everything client-side runs on Linux (native or WSL). Install:

```bash
sudo apt update && sudo apt install -y curl jq
# Azure CLI: https://aka.ms/azcli
```

WSL-specific notes (skip on native Linux):

- `az login` cannot open a browser inside WSL. Always use `az login --use-device-code`.
- If you want to run the official `workiq` CLI (Node-based) for comparison testing, install browser bridging first: `sudo apt install -y wslu && export BROWSER=wslview`.
- On corporate Windows machines, npm may be policy-blocked (`EALLOWREMOTE`). Run npm/npx inside WSL instead.

## 4. Decisions to make before the session

Bring answers to these; they are required inputs during setup:

1. **Which Azure subscription** funds the pay-as-you-go billing, and what **monthly spending limit** (in Copilot Credits) to set. Recommendation: start low; you can raise it later.
2. **Which users** participate in the pilot (each needs a Copilot license).
3. Whether **write actions** should remain disabled (default, recommended for grounding scenarios) or be enabled for specific flows.

## 5. Optional but recommended: run the tenant enablement in advance

If a Global Admin can spare 10 minutes before the session, run the official enablement (from any machine with PowerShell 7):

```powershell
git clone https://github.com/microsoft/work-iq
cd work-iq
Install-Module Microsoft.Graph -Scope CurrentUser
./scripts/Enable-WorkIQToolsForTenant.ps1
```

This provisions the ten Work IQ MCP service principals and grants consent in one pass. It is idempotent and read-safe to re-run. Doing it in advance removes the longest sequential dependency from the session.

## Pre-session checklist summary

- [ ] Tenant has M365 + Copilot SKUs with free units
- [ ] Test user has a Copilot license assigned
- [ ] Entra admin role identified, and PIM-activated if applicable
- [ ] Azure RBAC (Contributor+) confirmed on the billing subscription
- [ ] Linux box with curl, jq, Azure CLI
- [ ] Billing subscription + spending limit decided
- [ ] (Optional) Tenant enablement script already executed
