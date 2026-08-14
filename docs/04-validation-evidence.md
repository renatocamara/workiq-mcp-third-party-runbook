# Validation evidence: real terminal outputs

These are actual, lightly sanitized outputs captured during the validation (WSL Ubuntu, August 2026, `WorkIQ.MCP.Server` v1.0.165.0). Use them to compare against your own runs: your output should look like the "success" blocks, and if it looks like a "failure" block, the fix is referenced next to it.

Sanitization: tenant/subscription/app IDs and user emails are replaced with placeholders like `<tenant-id>`. Everything else is verbatim.

---

## 1. App registration setup (Runbook Step 2)

`./setup-workiq-app.sh` on a correctly permissioned tenant:

```text
[*] Tenant: <tenant-id>
[*] App name: WorkIQ Shell Client (audience: AzureADMyOrg)
[*] Checking Work IQ service principal...
[*] Provisioning Work IQ SP (one-time per tenant)...
[+] Work IQ SP created.
[*] Looking for existing app registration named 'WorkIQ Shell Client'...
[*] Creating app registration...
[+] App created: <client-id>
[+] App service principal created.
[*] Resolving WorkIQAgent.Ask scope ID on the Work IQ SP...
[+] Scope ID: 0b1715fd-f4bf-4c63-b16d-5be31f9847c2
[*] Adding delegated permission...
[+] Permission added.
[*] Granting admin consent (requires admin role)...
[+] Admin consent granted.

[+] Setup complete. Export these and run workiq-mcp.sh:

  export TENANT_ID="<tenant-id>"
  export CLIENT_ID="<client-id>"
  ./workiq-mcp.sh tools
```

Failure mode for comparison (missing Entra role; fix in [Troubleshooting #2](03-troubleshooting.md#2-insufficient-privileges-to-complete-the-operation-when-creating-service-principals-or-app-registrations)):

```text
[*] Provisioning Work IQ SP (one-time per tenant)...
ERROR: Insufficient privileges to complete the operation.
[x] Could not create Work IQ SP. You may lack permissions.
```

---

## 2. MCP handshake and tool discovery (Runbook Step 3)

`./workiq-mcp.sh tools`, first run (device code prompt included):

```text
>> To sign in, use a web browser to open the page https://login.microsoft.com/device and enter the code XXXXXXXXX to authenticate.
{
  "name": "WorkIQ.MCP.Server",
  "version": "1.0.165.0"
}
fetch_blob      Fetch a binary file (document, image, photo) from a WorkIQ path — PDFs, Office files, prof
ask     Ask a question to Microsoft 365 Copilot for information about emails, meetings, files, and
list_agents     List available Microsoft 365 Copilot agents. Returns agent IDs that can be passed to ask's
delete_entity   Delete a WorkIQ entity by path. Sends HTTP DELETE to the entity path. Returns confirmation
do_action       Execute a WorkIQ action via HTTP POST. Actions perform complex operations like sending mai
create_entity   Create a new WorkIQ entity by POSTing JSON to a parent collection path. Use get_schema fir
get_schema      Get the OpenAPI schema for a WorkIQ operation. Returns a self-contained YAML schema with r
search_paths    Search for available API paths in WorkIQ. Returns paths matching a regex filter. Use this
call_function   Call a WorkIQ function via HTTP GET. Functions compute or synthesize data rather than simp
fetch   Fetch one or more WorkIQ entities by path. Use entity paths discovered from ask responses
update_entity   Update an existing WorkIQ entity by writing JSON to its path. Use get_schema first to disc
```

This proves: delegated OAuth from a Linux shell, MCP Streamable HTTP handshake, session establishment, and tool discovery. Note the server reports 11 tools; official docs at the time listed 10 (`fetch_blob` is newer than the docs).

---

## 3. The entitlement gate (what failure looks like)

`./workiq-mcp.sh fetch "/me/messages"` before billing is configured. **This exact output appeared identically in three different misconfigured tenants:**

```json
{
  "result": {
    "content": [
      {
        "type": "text",
        "text": "The caller is not entitled to use this tool. Please check your billing policy and AI credit entitlement."
      }
    ],
    "isError": true,
    "_meta": { "requestId": "<request-id>" }
  },
  "id": 1,
  "jsonrpc": "2.0"
}
```

Root causes we confirmed for this one error text, in different tenants: no M365 licensing at all, incomplete tenant enablement, and missing pay-as-you-go billing policy. Work the [decision tree](03-troubleshooting.md#quick-decision-tree-for-the-entitlement-error).

Diagnostic commands and their outputs from the failing tenants:

```text
$ az rest --method get --url "https://graph.microsoft.com/v1.0/me/licenseDetails" | jq -r '.value[].skuPartNumber'
AAD_PREMIUM_P2
```
(Only Entra P2, no M365: wrong tenant. Compare with a healthy tenant:)

```text
$ az rest --method get --url "https://graph.microsoft.com/v1.0/me/licenseDetails" | jq -r '.value[].skuPartNumber'
Microsoft_Teams_Enterprise_New
AGENT_365
Microsoft_365_Copilot
Microsoft_365_E5_(no_Teams)
```
(License present. If the error persists here, the gap is enablement or billing, not licensing.)

---

## 4. Tenant enablement output (Runbook Step 1)

`Enable-WorkIQToolsForTenant.ps1` (abridged; the full run creates ten SPs and grants consent on each):

```text
Provisioning MCP Server service principals...
  Work IQ Tools already exists (Id: <sp-id>)
  Creating mcp_MailTools...
  Created mcp_MailTools (Id: <sp-id>)
  Creating mcp_MeServer...
  ...
  Creating mcp_M365Copilot...
  Created mcp_M365Copilot (Id: <sp-id>)

Granting admin consent for Work IQ Tools permissions...
  Granted: McpServers.CopilotMCP.All McpServers.Me.All McpServers.Mail.All
  McpServers.Calendar.All McpServers.Teams.All McpServers.Word.All
  McpServers.OneDriveSharepoint.All ...

Granting admin consent for mcp_MailTools permissions...
  Granted: Tools.ListInvoke.All
  ... (repeated for each server)

Work IQ tenant enablement complete!
Users can now authenticate with the Work IQ CLI.
```

Note the first line: "Work IQ Tools already exists". Our custom setup script had created the universal SP earlier, yet the entitlement error persisted until this full enablement ran. The universal SP alone is not enough.

---

## 5. Success: entity fetch with entitlement approved (Runbook Step 5)

Same command, same tenant, after billing activation. First with an empty mailbox (still a success: HTTP 200, `isError: false`):

```json
{
  "result": {
    "content": [],
    "structuredContent": {
      "results": [
        {
          "data": {
            "@odata.context": "https://graph.microsoft.com/v1.0/$metadata#users('<user-oid>')/messages(id,subject,from,receivedDateTime,isRead,importance)",
            "value": []
          },
          "statusCode": 200
        }
      ]
    },
    "isError": false
  },
  "id": 1,
  "jsonrpc": "2.0"
}
```

Then with real content in the mailbox:

```json
{
  "result": {
    "structuredContent": {
      "results": [
        {
          "data": {
            "value": [
              {
                "receivedDateTime": "2026-08-14T15:14:45Z",
                "subject": "testing",
                "importance": "normal",
                "isRead": false,
                "from": {
                  "emailAddress": { "name": "<sender-name>", "address": "<sender-email>" }
                }
              }
            ]
          },
          "statusCode": 200
        }
      ]
    },
    "isError": false
  }
}
```

Real mailbox data flowing through a custom third-party client. This is the core proof for the architecture question.

---

## 6. Success: Copilot reasoning via `ask` (Runbook Step 5)

`./workiq-mcp.sh ask "What was decided about the tape-out?"` on a freshly populated tenant:

```text
I couldn't find any enterprise results matching "tape-out", "tape out", or "tapeout"
in meetings, transcripts, emails, chats, or files.
Could you give me a bit more context, such as:
- The project or chip name
- The meeting name
- Who discussed it
- An approximate date or timeframe
With any of those details, I can search the relevant meetings, messages, and documents
and summarize exactly what was decided.
```

Even a "no results" answer is evidence: the Copilot pipeline authenticated, ran the multi-source search (meetings, transcripts, emails, chats, files), and reasoned about the response. The 0-result on brand-new content is the semantic index lag described in [Troubleshooting #10](03-troubleshooting.md#10-empty-results-that-look-like-failures-but-are-not); `fetch` on the same content returns it immediately.

---

## Reproducing this evidence

Every block above comes from the exact commands in [02-runbook.md](02-runbook.md), Step 5. To capture your own evidence run for a customer report:

```bash
{
  ./workiq-mcp.sh tools
  ./workiq-mcp.sh fetch "/me/messages"
  ./workiq-mcp.sh ask "Do I have any meetings today?"
} 2>&1 | tee validation-evidence-$(date +%Y%m%d).log
```
