# Runbook: connect a third-party Linux agent to Work IQ MCP

Follow the steps in order. Each step lists its **validation check**; do not advance until the check passes. If a check fails, jump to [03-troubleshooting.md](03-troubleshooting.md), which is indexed by error message.

Prerequisite: everything in [01-prerequisites.md](01-prerequisites.md) is done.

---

## Step 0: Clone the repositories

```bash
git clone https://github.com/<your-org>/workiq-mcp-third-party-runbook
git clone https://github.com/microsoft/work-iq
```

## Step 1: Tenant enablement (one time, Global Admin, PowerShell)

The Work IQ MCP servers require ten service principals plus tenant-wide consent. The official script does all of it. Run from PowerShell 7 (Windows, or `pwsh` on Linux):

```powershell
cd work-iq
Install-Module Microsoft.Graph -Scope CurrentUser
./scripts/Enable-WorkIQToolsForTenant.ps1
```

Sign in as a Global Administrator of the target tenant when prompted.

**Expected output:** creation (or "already exists") of `Work IQ Tools`, `mcp_MailTools`, `mcp_MeServer`, `mcp_CalendarTools`, `mcp_TeamsServer`, `mcp_OneDriveRemoteServer`, `mcp_SharePointRemoteServer`, `mcp_AdminTools`, `mcp_WordServer`, `mcp_M365Copilot`, followed by "Granted:" consent lines for each, ending with `Work IQ tenant enablement complete!`

**Validation check:** in the M365 admin center, **Agents > Tools** now lists the Work IQ MCP servers as Available:

![Work IQ MCP servers in the tools registry](images/agents-tools-registry-workiq-servers.png)

> Do not skip this step even if the universal Work IQ service principal already exists. A partially enabled tenant (SP present, consents missing) produces the same entitlement error as a billing problem. We learned this the slow way.

## Step 2: Register the client app (one time, bash from Linux)

Your agent needs its own Entra identity to request Work IQ tokens. The provided script is idempotent and safe to re-run:

```bash
cd workiq-mcp-third-party-runbook/scripts
az login --use-device-code       # sign in as an admin of the target tenant
./setup-workiq-app.sh
```

What it does: ensures the Work IQ resource SP exists, creates a **public client** app registration (required for device code flow), adds the delegated `WorkIQAgent.Ask` permission (resolving the scope ID dynamically), and grants tenant-wide admin consent, with retries for Entra replication delays.

**Expected output:** ends with two `export` lines for `TENANT_ID` and `CLIENT_ID`.

**Validation check:** the script prints `Setup complete`. Keep the two export values.

## Step 3: First MCP contact (no billing needed yet)

```bash
export TENANT_ID="<from step 2>"
export CLIENT_ID="<from step 2>"
./workiq-mcp.sh tools
```

Complete the device-code sign-in as the Copilot-licensed test user.

**Expected output:** the server identifies itself (`WorkIQ.MCP.Server`) and lists the tools (11 at time of writing: `ask`, `fetch`, `fetch_blob`, `list_agents`, `get_schema`, `search_paths`, `call_function`, `create_entity`, `update_entity`, `delete_entity`, `do_action`).

**Validation check:** tool list renders. Auth, handshake, and discovery are proven. Note: data calls (`fetch`, `ask`) will still fail until Step 4; that is expected.

## Step 4: Activate pay-as-you-go billing (one time, portal)

This is the gate that blocks most third-party integrations. **An M365 Copilot license alone does not entitle third-party agents**; they are billed by consumption and require an active spending policy.

1. Open the **M365 admin center** (admin.cloud.microsoft) as an admin.
2. Go to **Copilot > Cost management**. The page states it applies to Copilot Cowork and **Work IQ API**.
3. Click **Get started**. The default spending policy panel opens:

   ![Spending policy panel](images/spending-policy-panel-validation.png)

4. Fill the panel top to bottom:
   - **Billing method:** keep "Use a pay-as-you-go subscription" checked.
   - **Subscription:** click the dropdown and **select the subscription from the list**. Typing alone does not commit the selection, and the Activate button stays disabled (see [Troubleshooting #7](03-troubleshooting.md#7-activate-button-stays-disabled-in-the-spending-policy-panel)).
   - **Monthly spending limit:** choose "Limit monthly spending" and set a conservative credit budget for the pilot.
   - **Per-user limit:** set a value or switch the toggle off; leaving it on with an empty field blocks activation.
5. When the panel looks like this, click **Activate**:

   ![Ready to activate](images/spending-policy-ready-to-activate.png)

**Expected outcome:** a success screen: "AI experiences enabled by usage-based billing are now available to all users".

![Billing activation success](images/billing-activation-success.png)

**If activation fails with a resource-group authorization error**, the admin lacks Azure RBAC on the chosen subscription. That exact error and its fix (including the Global Admin elevation path) are documented in [Troubleshooting #6](03-troubleshooting.md#6-couldnt-activate-copilot-credits-azure-rbac-error).

**Validation check:** success screen shown. Allow a few minutes for the policy to propagate.

## Step 5: End-to-end data validation

Fresh token first (the cache is not tenant-aware), then the three probes:

```bash
rm -f ~/.workiq_token
./workiq-mcp.sh fetch "/me/messages"
./workiq-mcp.sh fetch "/me/events"
./workiq-mcp.sh ask "Do I have any meetings today?"
```

**Expected outputs:**

- `fetch` returns `"statusCode": 200` with `"isError": false`. An empty `value: []` with 200 still counts as success for a user with an empty mailbox; the entitlement and data path are proven. Populate the mailbox (send the user an email from another account) and re-run to see real data flow.
- `ask` returns a natural-language answer. For newly created users/content, `ask` may report 0 results while `fetch` shows the data: the Copilot semantic index lags behind raw entity access by hours. This is expected preview behavior, not a failure. Re-test `ask` the next day for grounded answers.

**Validation check:** all three commands return without the entitlement error. The integration is fully validated. Compare your outputs against the captured known-good runs in [04-validation-evidence.md](04-validation-evidence.md).

## Step 6: What "done" looks like

| Layer | Evidence |
|---|---|
| Delegated auth from a custom app | Device code flow completes, token cached |
| MCP transport | Server banner + 11 tools |
| Tenant enablement | Servers listed in admin center tools registry |
| Billing entitlement | `fetch` returns 200 instead of the entitlement error |
| Data flow | Real message/event objects in `fetch` output |
| Copilot reasoning | `ask` answers over indexed content |

## Step 7: Cleanup (borrowed or test tenants)

Undo everything this runbook created, in reverse order:

```bash
# Remove the client app registration
az ad app delete --id "$CLIENT_ID"

# Remove the Azure RBAC assignment if you added one for billing setup
az role assignment delete --assignee "<upn>" --role "Contributor" \
  --scope "/subscriptions/<sub-id>"
```

- Deactivate or adjust the spending policy in Copilot > Cost management if the tenant should stop accruing charges.
- If you used the Global Admin **"Access management for Azure resources"** elevation, switch it back to **No** in Entra ID > Properties.
- The Work IQ service principals from Step 1 can stay; they are inert without licensed, billed callers and save re-enablement later.
