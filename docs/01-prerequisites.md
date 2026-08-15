# Prerequisites

Complete the following checks before the validation session. Each prerequisite maps to a configuration dependency that can prevent successful Work IQ tool execution.

## 1. Validate the target tenant

Select a tenant that contains the Microsoft 365 workloads and user data required for the validation. Verify that:

- [ ] The tenant contains the Microsoft 365 workloads required for the test, such as Exchange Online, Microsoft Teams, SharePoint, or OneDrive. Work IQ grounds on content; a Microsoft Entra-only tenant does not provide the Microsoft 365 workload data required for this validation.
- [ ] The test user is licensed and provisioned for the Microsoft 365 workloads that will be queried.
- [ ] An Azure subscription and resource group are available for the Work IQ usage-based billing configuration.
- [ ] The test user will be included in the applicable Work IQ billing/access policy (configured in Runbook Step 4).

> **A Microsoft 365 Copilot license is not required for direct Work IQ API access.** Work IQ API access is independent of Microsoft 365 Copilot licensing; usage by custom and third-party agents is billed through the usage-based Copilot Credits model. See the [licensing and billing model](../README.md#licensing-and-billing-model) in the README. Note that some Microsoft-hosted integration experiences (such as the Microsoft Foundry quickstart) list Microsoft 365 Copilot as a prerequisite for those specific scenarios; that requirement does not automatically apply to a direct third-party Work IQ MCP integration.

Quick verification from any machine with Azure CLI (read-only, safe to run):

```bash
az login --use-device-code
# Which Microsoft 365 workload SKUs exist in the tenant?
az rest --method get --url "https://graph.microsoft.com/v1.0/subscribedSkus?\$select=skuPartNumber,prepaidUnits,consumedUnits" \
  | jq -r '.value[] | "\(.skuPartNumber)\tavailable:\(.prepaidUnits.enabled - .consumedUnits)"'
# Which workloads is YOUR test user licensed for?
az rest --method get --url "https://graph.microsoft.com/v1.0/me/licenseDetails" | jq -r '.value[].skuPartNumber'
```

Confirm that Microsoft 365 workload SKUs relevant to the validation (for example, E3/E5) are present in the first list and assigned to the test user in the second. A tenant whose only SKU is Microsoft Entra (for example, `AAD_PREMIUM_P2`) is unsuitable for this validation scenario: not because a license named Copilot is missing, but because the Microsoft 365 data plane you want to query does not exist there.

## 2. Identity roles (this is TWO separate systems)

Azure RBAC and Microsoft Entra directory roles serve different purposes in this configuration and should be validated independently. You need both, for different steps:

| Step | System | Role needed |
|---|---|---|
| Tenant enablement script + app registration + admin consent | **Microsoft Entra directory role** | Global Administrator (or Application Administrator for app steps; consent needs Global Administrator / Privileged Role Administrator) |
| Usage-based billing activation (creates Azure resources) | **Azure RBAC on the subscription** | Contributor (or Owner) on the billing subscription |

Important gotchas, all observed during validation:

- **"Owner" of Azure subscriptions does NOT grant Microsoft Entra directory permissions**, and Global Administrator does NOT grant Azure RBAC. They are independent. Check both.
- **If your admin role is PIM-eligible, activate it first** (Microsoft Entra portal > Privileged Identity Management > My roles > Activate), then sign in again in the CLI. Tokens issued before activation do not carry the role.
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

1. **Which Azure subscription** funds the usage-based billing, and what **monthly spending limit** (in Copilot Credits) to set. Recommendation: start low; you can raise it later.
2. **Which users** participate in the pilot (each must be provisioned for the Microsoft 365 workloads under test and included in the billing/access policy).
3. Whether **write actions** are needed. This validation is read-focused; enabling write/action capabilities is a separate governance decision.

## 5. Optional but recommended: run the tenant enablement in advance

If a Global Administrator can spare 10 minutes before the session, run the current Microsoft-provided tenant enablement procedure (from any machine with PowerShell 7):

```powershell
git clone https://github.com/microsoft/work-iq
cd work-iq
Install-Module Microsoft.Graph -Scope CurrentUser
./scripts/Enable-WorkIQToolsForTenant.ps1
```

During the validation documented in this repository, this script provisioned the Work IQ and MCP-related service principals and granted the required administrative consent in one pass. It is idempotent and safe to re-run. Doing it in advance removes the longest sequential dependency from the session.

## Pre-session checklist summary

- [ ] Tenant has the Microsoft 365 workload SKUs required for the test, with free units
- [ ] Test user provisioned for those workloads (mailbox, Teams, files)
- [ ] Microsoft Entra admin role identified, and PIM-activated if applicable
- [ ] Azure RBAC (Contributor+) confirmed on the billing subscription
- [ ] Linux box with curl, jq, Azure CLI
- [ ] Billing subscription + spending limit decided
- [ ] (Optional) Tenant enablement already executed
