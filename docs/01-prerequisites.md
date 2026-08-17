# Prerequisites

Complete the following checks before the validation session. Each prerequisite maps to a configuration dependency that can prevent successful Work IQ tool execution.

## 1. Validate the target tenant

Select a tenant that contains the Microsoft 365 workloads and user data required for the validation. Verify that:

- [ ] The tenant contains the Microsoft 365 workloads required for the test, such as Exchange Online, Microsoft Teams, SharePoint, or OneDrive. Work IQ grounds on content; a Microsoft Entra-only tenant does not provide the Microsoft 365 workload data required for this validation.
- [ ] The test user is licensed and provisioned for the Microsoft 365 workloads that will be queried.
- [ ] An Azure subscription and resource group are available for the Work IQ usage-based billing configuration.
- [ ] The test user will be included in the applicable Work IQ billing/access policy (configured in Runbook Step 4).

> **A Microsoft 365 Copilot license is not required for direct Work IQ API access.** Work IQ API access is independent of Microsoft 365 Copilot licensing; usage by custom and third-party agents is billed through the usage-based Copilot Credits model. Source: [Work IQ overview](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/work-iq/) and [Work IQ API overview](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/work-iq/api-overview); see also the [licensing and billing model](../README.md#licensing-and-billing-model) in the README. Note that some Microsoft-hosted integration experiences (such as the Microsoft Foundry quickstart) list Microsoft 365 Copilot as a prerequisite for those specific scenarios; that requirement does not automatically apply to a direct third-party Work IQ MCP integration.

Quick verification from any machine with Azure CLI (read-only, safe to run):

```bash
az login --use-device-code
# Which Microsoft 365 workload SKUs exist in the tenant?
az rest --method get --url "https://graph.microsoft.com/v1.0/subscribedSkus?\$select=skuPartNumber,prepaidUnits,consumedUnits" \
  | jq -r '.value[] | "\(.skuPartNumber)\tavailable:\(.prepaidUnits.enabled - .consumedUnits)"'
# Which workloads is the test user licensed for?
az rest --method get --url "https://graph.microsoft.com/v1.0/me/licenseDetails" | jq -r '.value[].skuPartNumber'
```

Confirm that licenses providing the Microsoft 365 workloads relevant to the validation are present in the first list and assigned to the test user in the second. Examples include licenses that provision Exchange Online, Teams, SharePoint, and OneDrive. A tenant whose only SKU is Microsoft Entra (for example, `AAD_PREMIUM_P2`) is unsuitable for this validation scenario: not because a license named Copilot is missing, but because the Microsoft 365 data plane you want to query does not exist there.

## 2. Identity roles (validate each dimension independently)

Microsoft Entra directory roles, Microsoft 365 admin center billing roles, and Azure RBAC serve different purposes in this configuration and should be validated independently:

| Step | System | Role needed |
|---|---|---|
| Tenant enablement script + app registration + admin consent | **Microsoft Entra directory role** | Global Administrator (validated and documented path) |
| Usage-based billing method configuration (Microsoft 365 admin center) | **Microsoft 365 admin center role** | Global Administrator or Billing Administrator. AI Administrator and License Administrator can manage spending policies, limits, and alerts, but cannot set or change the billing method. |
| Azure resource creation for pay-as-you-go billing | **Azure RBAC on the subscription** | Contributor (or Owner) on the selected subscription |

> Note: the Microsoft-provided enablement script may support additional application-administration roles; follow the current script requirements if using a least-privilege alternative.

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

1. **Which billing model and which Azure subscription.** Decide between **pay-as-you-go** (requires an Azure subscription and Contributor RBAC; pay only for what you consume) and **prepaid Copilot Credit capacity packs** (USD 200/month per 25,000 credits, tenant-wide, purchased in the admin center; predictable cost, but monthly credits do not roll over). Prepaid is consumed first when both exist. Also decide the **monthly spending limit** (in Copilot Credits) for the policy. Recommendation: start with pay-as-you-go and a low cap while usage is unknown; consider packs once consumption stabilizes.
2. **Which users** participate in the pilot (each must be provisioned for the Microsoft 365 workloads under test and included in the billing/access policy).
3. Whether **write actions** are needed. This validation is read-focused; enabling write/action capabilities is a separate governance decision.

## 5. Run the tenant enablement in advance (the enablement itself is MANDATORY)

To be clear about what is optional here: **tenant enablement is a required configuration step, not an optional one.** Without it, Work IQ calls fail with the entitlement error even when licensing and billing are correctly configured (see [Runbook Step 1](02-runbook.md#step-1-tenant-enablement-one-time-global-administrator-powershell) and [Troubleshooting #5](03-troubleshooting.md#5-entitlement-error-persists-with-workload-access-billingenablement-gate)). The only optional part is the **timing**: it can be executed during the working session, but running it in advance is strongly recommended because it is the longest sequential dependency and requires a Global Administrator.

If a Global Administrator can spare 10 minutes before the session, run the current Microsoft-provided tenant enablement procedure (from any machine with PowerShell 7):

```powershell
git clone https://github.com/microsoft/work-iq
cd work-iq
Install-Module Microsoft.Graph -Scope CurrentUser
./scripts/Enable-WorkIQToolsForTenant.ps1
```

During the validation documented in this repository, this script provisioned the Work IQ and MCP-related service principals and granted the required administrative consent in one pass. It is idempotent and safe to re-run. Doing it in advance removes the longest sequential dependency from the session.

## Pre-session checklist summary

- [ ] Tenant has the Microsoft 365 workload licenses required for the test
- [ ] Test user provisioned for those workloads (mailbox, Teams, files)
- [ ] Microsoft Entra admin role identified, and PIM-activated if applicable
- [ ] Azure RBAC (Contributor+) confirmed on the billing subscription
- [ ] Microsoft 365 admin center billing role confirmed (Global Administrator or Billing Administrator)
- [ ] Linux box with curl, jq, Azure CLI
- [ ] Billing subscription + spending limit decided
- [ ] Tenant enablement executed (mandatory; ideally completed before the session)
