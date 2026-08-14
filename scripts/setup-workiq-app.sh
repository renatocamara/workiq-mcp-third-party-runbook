#!/usr/bin/env bash
# setup-workiq-app.sh
# Provisions an Entra ID app registration usable as CLIENT_ID for workiq-mcp.sh
# (public client + delegated WorkIQAgent.Ask permission + admin consent).
#
# Requires: az (Azure CLI, logged in), jq
# Run as: user who can create app registrations; admin-consent step needs
#         Global Administrator or Privileged Role Administrator.
#
# Usage:
#   ./setup-workiq-app.sh                       # default app name
#   ./setup-workiq-app.sh "My WorkIQ Client"    # custom app name
#   MULTITENANT=1 ./setup-workiq-app.sh         # multitenant registration
#
# Idempotent: safe to re-run. Reuses an existing app with the same name.

set -euo pipefail

WORKIQ_APPID="fdcc1f02-fc51-4226-8753-f668596af7f7"  # Work IQ resource app
APP_NAME="${1:-WorkIQ Shell Client}"
AUDIENCE="AzureADMyOrg"
[[ "${MULTITENANT:-0}" == "1" ]] && AUDIENCE="AzureADMultipleOrgs"

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v az >/dev/null || die "Azure CLI (az) not found. Install: https://aka.ms/azcli"
command -v jq >/dev/null || die "jq not found."
az account show >/dev/null 2>&1 || die "Not logged in. Run: az login"

TENANT_ID=$(az account show --query tenantId -o tsv)
log "Tenant: ${TENANT_ID}"
log "App name: ${APP_NAME} (audience: ${AUDIENCE})"

# ---------------------------------------------------------------
# Step 0: Ensure the Work IQ service principal exists in the tenant
# ---------------------------------------------------------------
log "Checking Work IQ service principal..."
if az ad sp show --id "$WORKIQ_APPID" >/dev/null 2>&1; then
  ok "Work IQ SP already provisioned."
else
  log "Provisioning Work IQ SP (one-time per tenant)..."
  az ad sp create --id "$WORKIQ_APPID" >/dev/null \
    || die "Could not create Work IQ SP. You may lack permissions."
  ok "Work IQ SP created."
fi

# ---------------------------------------------------------------
# Step 1: Create (or reuse) the app registration as a public client
# ---------------------------------------------------------------
log "Looking for existing app registration named '${APP_NAME}'..."
CLIENT_ID=$(az ad app list --display-name "$APP_NAME" \
  --query "[0].appId" -o tsv 2>/dev/null || true)

if [[ -n "$CLIENT_ID" && "$CLIENT_ID" != "null" ]]; then
  ok "Reusing existing app: ${CLIENT_ID}"
  # Make sure it is a public client (device code flow requirement)
  az ad app update --id "$CLIENT_ID" --is-fallback-public-client true
else
  log "Creating app registration..."
  CLIENT_ID=$(az ad app create \
    --display-name "$APP_NAME" \
    --sign-in-audience "$AUDIENCE" \
    --is-fallback-public-client true \
    --query appId -o tsv)
  ok "App created: ${CLIENT_ID}"
fi

# ---------------------------------------------------------------
# Step 2: Ensure the app's own service principal exists
# ---------------------------------------------------------------
if az ad sp show --id "$CLIENT_ID" >/dev/null 2>&1; then
  ok "App service principal already exists."
else
  az ad sp create --id "$CLIENT_ID" >/dev/null
  ok "App service principal created."
fi

# ---------------------------------------------------------------
# Step 3: Resolve the WorkIQAgent.Ask delegated scope ID dynamically
# ---------------------------------------------------------------
log "Resolving WorkIQAgent.Ask scope ID on the Work IQ SP..."
SCOPE_ID=""
for i in 1 2 3 4 5 6; do
  SCOPE_ID=$(az ad sp show --id "$WORKIQ_APPID" \
    --query "oauth2PermissionScopes[?value=='WorkIQAgent.Ask'].id" -o tsv || true)
  [[ -n "$SCOPE_ID" ]] && break
  warn "Scope not visible yet (directory replication). Retry ${i}/6 in 10s..."
  sleep 10
done
[[ -n "$SCOPE_ID" ]] || die "WorkIQAgent.Ask scope not found on the Work IQ SP."
ok "Scope ID: ${SCOPE_ID}"

# ---------------------------------------------------------------
# Step 4: Add the delegated permission (skip if already present)
# ---------------------------------------------------------------
EXISTING=$(az ad app show --id "$CLIENT_ID" \
  --query "requiredResourceAccess[?resourceAppId=='${WORKIQ_APPID}'].resourceAccess[].id" \
  -o tsv || true)
if grep -q "$SCOPE_ID" <<<"$EXISTING"; then
  ok "Delegated permission already configured."
else
  log "Adding delegated permission..."
  az ad app permission add --id "$CLIENT_ID" \
    --api "$WORKIQ_APPID" \
    --api-permissions "${SCOPE_ID}=Scope" >/dev/null
  ok "Permission added."
fi

# ---------------------------------------------------------------
# Step 5: Grant tenant-wide admin consent (retry for propagation)
# ---------------------------------------------------------------
log "Granting admin consent (requires admin role)..."
CONSENTED=0
for i in 1 2 3 4 5 6; do
  if az ad app permission admin-consent --id "$CLIENT_ID" >/dev/null 2>&1; then
    CONSENTED=1; break
  fi
  warn "Consent failed (propagation or missing role). Retry ${i}/6 in 15s..."
  sleep 15
done
if [[ "$CONSENTED" == "1" ]]; then
  ok "Admin consent granted."
else
  warn "Admin consent NOT granted. Either you lack the admin role, or replication"
  warn "is slow. An admin can finish it later with:"
  warn "  az ad app permission admin-consent --id ${CLIENT_ID}"
  warn "Without it, each user gets an interactive consent prompt at first sign-in."
fi

# ---------------------------------------------------------------
# Done
# ---------------------------------------------------------------
echo
ok "Setup complete. Export these and run workiq-mcp.sh:"
echo
echo "  export TENANT_ID=\"${TENANT_ID}\""
echo "  export CLIENT_ID=\"${CLIENT_ID}\""
echo "  ./workiq-mcp.sh tools"
echo
