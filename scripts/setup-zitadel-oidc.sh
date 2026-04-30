#!/bin/bash
# =============================================================================
# setup-zitadel-oidc.sh
#
# Configures Zitadel OIDC for Flui platform on an existing cluster.
# Reads the machine user PAT from the bootstrap PVC, then uses Zitadel
# Management API to create project, roles, OIDC application, and grant
# admin role. Finally patches Kubernetes resources and restarts deployments.
#
# Usage:
#   ./setup-zitadel-oidc.sh
#
# Prerequisites:
#   - kubectl configured and pointing to the cluster
#   - Zitadel running in flui-system namespace
#   - jq installed (script will install if missing)
# =============================================================================
set -euo pipefail

# --- Helpers -----------------------------------------------------------------
log()   { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; exit 1; }
ok()    { echo -e "\033[0;32m[OK]\033[0m    $*"; }

# Zitadel requires Host header matching its ExternalDomain
zitadel_curl() {
  curl -s -H "Host: ${ZITADEL_DOMAIN}" "$@"
}

zitadel_api() {
  curl -s -H "Host: ${ZITADEL_DOMAIN}" \
    -H "Authorization: Bearer ${PAT}" \
    -H "Content-Type: application/json" \
    "$@"
}

# --- Dependencies ------------------------------------------------------------
if ! command -v jq &>/dev/null; then
  log "Installing jq..."
  apt-get update -qq && apt-get install -y -qq jq >/dev/null 2>&1
fi

# --- Discover cluster info ---------------------------------------------------
MASTER_IP=$(hostname -I | awk '{print $1}')
ZITADEL_DOMAIN="auth.${MASTER_IP}.nip.io"
ZITADEL_SVC="http://$(kubectl get svc zitadel -n flui-system -o jsonpath='{.spec.clusterIP}'):8080"

log "Master IP:      ${MASTER_IP}"
log "Zitadel domain: ${ZITADEL_DOMAIN}"
log "Zitadel SVC:    ${ZITADEL_SVC}"

# --- Verify Zitadel is healthy -----------------------------------------------
log "Checking Zitadel health..."
if ! zitadel_curl -f "${ZITADEL_SVC}/debug/ready" >/dev/null 2>&1; then
  error "Zitadel is not ready. Check: kubectl logs deployment/zitadel -n flui-system"
fi
ok "Zitadel is healthy"

# --- Step 1: Read PAT from bootstrap PVC -------------------------------------
log "Reading machine user PAT from bootstrap PVC..."
PAT_RAW=$(kubectl run pat-reader --rm -i --restart=Never \
  --image=busybox \
  --namespace=flui-system \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "pat-reader",
        "image": "busybox",
        "command": ["cat", "/bootstrap/flui-api-system.pat"],
        "volumeMounts": [{
          "name": "bootstrap",
          "mountPath": "/bootstrap"
        }]
      }],
      "volumes": [{
        "name": "bootstrap",
        "persistentVolumeClaim": {
          "claimName": "zitadel-bootstrap-pvc"
        }
      }]
    }
  }' 2>&1 || true)
# Extract only the PAT token (first line, alphanumeric + underscore + dash)
PAT=$(echo "$PAT_RAW" | grep -oE '^[A-Za-z0-9_-]{20,}' | head -1)

if [ -z "$PAT" ]; then
  error "Could not read PAT from bootstrap PVC. Is Zitadel fully initialized?"
fi
ok "PAT obtained (${#PAT} chars)"

# --- Step 2: Verify PAT works ------------------------------------------------
log "Verifying PAT..."
ME_RESPONSE=$(zitadel_api "${ZITADEL_SVC}/auth/v1/users/me")
MY_USERNAME=$(echo "$ME_RESPONSE" | jq -r '.user.userName // empty')

if [ -z "$MY_USERNAME" ]; then
  error "PAT verification failed. Response: ${ME_RESPONSE}"
fi
ok "Authenticated as: ${MY_USERNAME}"

# --- Step 3: Create Flui project ---------------------------------------------
log "Creating Flui project..."
PROJECT_RESPONSE=$(zitadel_api "${ZITADEL_SVC}/management/v1/projects" \
  -d '{"name": "Flui", "projectRoleAssertion": true}')

PROJECT_ID=$(echo "$PROJECT_RESPONSE" | jq -r '.id // empty')
if [ -z "$PROJECT_ID" ]; then
  # Check if already exists
  EXISTING=$(zitadel_api "${ZITADEL_SVC}/management/v1/projects/_search" \
    -d '{"queries":[{"nameQuery":{"name":"Flui","method":"TEXT_QUERY_METHOD_EQUALS"}}]}')
  PROJECT_ID=$(echo "$EXISTING" | jq -r '.result[0].id // empty')
  if [ -z "$PROJECT_ID" ]; then
    error "Failed to create project. Response: ${PROJECT_RESPONSE}"
  fi
  ok "Project already exists: ${PROJECT_ID}"
else
  ok "Project created: ${PROJECT_ID}"
fi

# --- Step 4: Create admin role -----------------------------------------------
log "Creating admin role..."
ROLE_RESPONSE=$(zitadel_api "${ZITADEL_SVC}/management/v1/projects/${PROJECT_ID}/roles" \
  -d '{"roleKey": "admin", "displayName": "Administrator"}')
ROLE_ERROR=$(echo "$ROLE_RESPONSE" | jq -r '.code // 0')
if [ "$ROLE_ERROR" = "6" ]; then
  ok "Role 'admin' already exists"
else
  ok "Role 'admin' created"
fi

# --- Step 5: Create OIDC application (SPA with PKCE) -------------------------
log "Creating Flui Web OIDC application..."
FLUI_WEB_REDIRECT="http://app.${MASTER_IP}.nip.io/auth/callback"
FLUI_WEB_LOGOUT="http://app.${MASTER_IP}.nip.io"

APP_RESPONSE=$(zitadel_api "${ZITADEL_SVC}/management/v1/projects/${PROJECT_ID}/apps/oidc" \
  -d "{
    \"name\": \"Flui Web\",
    \"redirectUris\": [\"${FLUI_WEB_REDIRECT}\"],
    \"postLogoutRedirectUris\": [\"${FLUI_WEB_LOGOUT}\"],
    \"responseTypes\": [\"OIDC_RESPONSE_TYPE_CODE\"],
    \"grantTypes\": [\"OIDC_GRANT_TYPE_AUTHORIZATION_CODE\"],
    \"appType\": \"OIDC_APP_TYPE_USER_AGENT\",
    \"authMethodType\": \"OIDC_AUTH_METHOD_TYPE_NONE\",
    \"accessTokenType\": \"OIDC_TOKEN_TYPE_JWT\",
    \"devMode\": true
  }")

FLUI_CLIENT_ID=$(echo "$APP_RESPONSE" | jq -r '.clientId // empty')
if [ -z "$FLUI_CLIENT_ID" ]; then
  error "Failed to create OIDC app. Response: ${APP_RESPONSE}"
fi
ok "OIDC application created — Client ID: ${FLUI_CLIENT_ID}"FF

# --- Step 6: Grant admin role to flui-admin -----------------------------------
log "Granting admin role to flui-admin..."
ADMIN_USER_ID=$(kubectl exec -n flui-system statefulset/postgres -- \
  psql -U zitadel_user -d zitadel -t -A -c \
  "SELECT id FROM projections.users14 WHERE username LIKE 'flui-admin%' AND type=1;" 2>/dev/null | tr -d '[:space:]')

if [ -n "$ADMIN_USER_ID" ]; then
  GRANT_RESPONSE=$(zitadel_api "${ZITADEL_SVC}/management/v1/users/${ADMIN_USER_ID}/grants" \
    -d "{\"projectId\": \"${PROJECT_ID}\", \"roleKeys\": [\"admin\"]}")
  GRANT_ERROR=$(echo "$GRANT_RESPONSE" | jq -r '.code // 0')
  if [ "$GRANT_ERROR" = "0" ]; then
    ok "Admin role granted to flui-admin (${ADMIN_USER_ID})"
  else
    warn "Grant response: ${GRANT_RESPONSE}"
  fi
else
  warn "Could not find flui-admin user ID — grant role manually in console"
fi

# --- Step 7: Inject PAT and Client ID into flui-secrets ----------------------
# OIDC_AUDIENCE is the generic name (was ZITADEL_AUDIENCE).
# ZITADEL_SERVICE_ACCOUNT_PAT stays Zitadel-specific: it's used to talk to
# the Zitadel admin API, which is not a standard OIDC concept.
log "Injecting PAT and Client ID into flui-secrets..."
kubectl patch secret flui-secrets -n flui-system --type merge \
  -p "{\"stringData\":{\"OIDC_AUDIENCE\":\"${FLUI_CLIENT_ID}\",\"ZITADEL_SERVICE_ACCOUNT_PAT\":\"${PAT}\"}}"
ok "flui-secrets patched"

# --- Step 8: Patch flui-web-config -------------------------------------------
log "Patching flui-web-config..."
kubectl get configmap flui-web-config -n flui-system -o json | \
  python3 -c "
import sys, json
cm = json.load(sys.stdin)
config = json.loads(cm['data'].get('config.json', '{}'))
config['oidcClientId'] = '${FLUI_CLIENT_ID}'
config['oidcIssuer'] = 'https://${ZITADEL_DOMAIN}'
config['authMode'] = 'oidc'
cm.get('metadata', {}).pop('managedFields', None)
cm['data']['config.json'] = json.dumps(config, indent=2)
json.dump(cm, sys.stdout)" | kubectl apply -f -
ok "flui-web-config patched"

# --- Step 9: Patch flui-api-config -------------------------------------------
log "Patching flui-api-config..."
# OIDC_JWKS_URI uses the internal HTTP service to avoid self-signed TLS issues.
# OIDC_ISSUER remains the external HTTPS URL to match the 'iss' claim in JWTs.
# Legacy ZITADEL_* keys are removed so the ConfigMap has a single source of truth.
kubectl get configmap flui-api-config -n flui-system -o json | \
  python3 -c "
import sys, json
cm = json.load(sys.stdin)
cm['data']['AUTH_MODE'] = 'oidc'
cm['data']['OIDC_ISSUER'] = 'https://${ZITADEL_DOMAIN}'
cm['data']['OIDC_JWKS_URI'] = 'http://zitadel.flui-system.svc.cluster.local:8080/oauth/v2/keys'
cm['data'].pop('ZITADEL_ISSUER', None)
cm['data'].pop('ZITADEL_JWKS_URI', None)
cm.get('metadata', {}).pop('managedFields', None)
json.dump(cm, sys.stdout)" | kubectl apply -f -
ok "flui-api-config patched"

# --- Step 10: Restart deployments --------------------------------------------
log "Restarting flui-api and flui-web..."
kubectl rollout restart deployment/flui-api deployment/flui-web -n flui-system
ok "Deployments restarted"

# --- Done! -------------------------------------------------------------------
echo ""
echo "=============================================="
echo "  Zitadel OIDC setup complete!"
echo "=============================================="
echo ""
echo "  Flui Web:     http://app.${MASTER_IP}.nip.io"
echo "  Zitadel:      https://${ZITADEL_DOMAIN}/ui/console"
echo "  Client ID:    ${FLUI_CLIENT_ID}"
echo "  Project ID:   ${PROJECT_ID}"
echo "  Redirect URI: ${FLUI_WEB_REDIRECT}"
echo ""
echo "  Login at the Flui dashboard — it will redirect to Zitadel."
echo ""
