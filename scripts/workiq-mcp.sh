#!/usr/bin/env bash
# workiq-mcp.sh
# Minimal shell-script MCP client for the Microsoft Work IQ universal endpoint.
# Requires: curl, jq
#
# Usage:
#   export TENANT_ID="<your-tenant-guid>"
#   export CLIENT_ID="<your-entra-app-client-id>"   # public client, delegated perms
#   ./workiq-mcp.sh ask "Do I have any meetings today?"
#   ./workiq-mcp.sh tools                            # list available tools
#   ./workiq-mcp.sh fetch "/me/messages"             # raw entity fetch
#
# Notes:
# - Delegated auth only. App-only (client credentials) is NOT supported by Work IQ.
# - The signed-in user needs a Microsoft 365 Copilot license.
# - Token is cached in ~/.workiq_token for reuse until it expires.

set -euo pipefail

TENANT_ID="${TENANT_ID:?Set TENANT_ID env var}"
CLIENT_ID="${CLIENT_ID:?Set CLIENT_ID env var}"
SCOPE="api://workiq.svc.cloud.microsoft/WorkIQAgent.Ask offline_access"
MCP_URL="https://workiq.svc.cloud.microsoft/mcp"
LOGIN="https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0"
TOKEN_CACHE="${HOME}/.workiq_token"

# ---------------------------------------------------------------
# 1. Auth: Device Code flow (pure curl, no MSAL needed)
# ---------------------------------------------------------------
get_token() {
  # Reuse cached token if still valid (with 60s buffer)
  if [[ -f "$TOKEN_CACHE" ]]; then
    local exp now
    exp=$(jq -r '.expires_at // 0' "$TOKEN_CACHE")
    now=$(date +%s)
    if (( now < exp - 60 )); then
      jq -r '.access_token' "$TOKEN_CACHE"
      return
    fi
  fi

  local dc device_code interval msg tok err now
  dc=$(curl -s -X POST "${LOGIN}/devicecode" \
        -d "client_id=${CLIENT_ID}" \
        --data-urlencode "scope=${SCOPE}")
  device_code=$(jq -r '.device_code' <<<"$dc")
  interval=$(jq -r '.interval // 5' <<<"$dc")
  msg=$(jq -r '.message' <<<"$dc")
  echo ">> ${msg}" >&2

  while true; do
    sleep "$interval"
    tok=$(curl -s -X POST "${LOGIN}/token" \
          -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
          -d "client_id=${CLIENT_ID}" \
          -d "device_code=${device_code}")
    err=$(jq -r '.error // empty' <<<"$tok")
    [[ -z "$err" ]] && break
    if [[ "$err" != "authorization_pending" ]]; then
      echo "Auth failed:" >&2; jq . <<<"$tok" >&2; exit 1
    fi
  done

  now=$(date +%s)
  jq --argjson now "$now" '. + {expires_at: ($now + .expires_in)}' <<<"$tok" \
    > "$TOKEN_CACHE"
  chmod 600 "$TOKEN_CACHE"
  jq -r '.access_token' "$TOKEN_CACHE"
}

ACCESS_TOKEN=$(get_token)

# ---------------------------------------------------------------
# 2. MCP plumbing: JSON-RPC over Streamable HTTP
#    Responses may come back as SSE ("data: {...}") - strip framing.
# ---------------------------------------------------------------
HDRS=$(mktemp)
trap 'rm -f "$HDRS"' EXIT
SESSION_ID=""

mcp_post() {
  local body="$1" raw
  raw=$(curl -s -D "$HDRS" -X POST "$MCP_URL" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    ${SESSION_ID:+-H "Mcp-Session-Id: ${SESSION_ID}"} \
    -d "$body")
  # If the server replied with SSE framing, extract the data lines
  if grep -qi '^content-type: *text/event-stream' "$HDRS"; then
    sed -n 's/^data: //p' <<<"$raw"
  else
    printf '%s' "$raw"
  fi
}

mcp_init() {
  local resp
  resp=$(mcp_post '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{
    "protocolVersion":"2025-06-18",
    "capabilities":{},
    "clientInfo":{"name":"workiq-shell","version":"0.1"}}}')
  SESSION_ID=$(grep -i '^mcp-session-id:' "$HDRS" | awk '{print $2}' | tr -d '\r' || true)
  # Complete the handshake
  mcp_post '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
  jq -r '.result.serverInfo // empty' <<<"$resp" >&2 || true
}

mcp_call() {  # $1 = tool name, $2 = arguments JSON
  mcp_post "$(jq -nc --arg name "$1" --argjson args "$2" \
    '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:$name,arguments:$args}}')"
}

# ---------------------------------------------------------------
# 3. Commands
# ---------------------------------------------------------------
CMD="${1:-tools}"
mcp_init

case "$CMD" in
  tools)
    mcp_post '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
      | jq -r '.result.tools[] | "\(.name)\t\(.description // "" | .[0:90])"'
    ;;
  ask)
    Q="${2:?Usage: $0 ask \"your question\"}"
    mcp_call "ask" "$(jq -nc --arg q "$Q" '{question:$q}')" \
      | jq -r '.result.content[]? | select(.type=="text") | .text'
    ;;
  fetch)
    P="${2:?Usage: $0 fetch \"/me/messages\"}"
    mcp_call "fetch" "$(jq -nc --arg p "$P" '{entityUrls:[$p]}')" | jq .
    ;;
  schema)
    P="${2:?Usage: $0 schema \"/me/messages\"}"
    mcp_call "get_schema" "$(jq -nc --arg p "$P" '{path:$p,operationType:"fetch"}')" | jq .
    ;;
  raw)
    # Escape hatch: pass a full JSON-RPC body yourself
    mcp_post "${2:?Usage: $0 raw '<json-rpc body>'}" | jq .
    ;;
  *)
    echo "Commands: tools | ask \"question\" | fetch <path> | schema <path> | raw '<json>'" >&2
    exit 1
    ;;
esac
