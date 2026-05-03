#!/bin/bash
# =============================================================================
# setup-zitadel-oidc.sh
#
# Configures Zitadel OIDC for Flui platform on a fresh observability cluster.
# Mirrors the API-side OidcBootstrapService so it can run BEFORE flui-api boots,
# eliminating the rollout-restart cycle and saving ~60s on first install.
#
# Steps (idempotent):
#   1. Read machine user PAT from zitadel-bootstrap-pvc
#   2. Create / find "Flui" project (with projectRoleAssertion=true)
#   3. Create roles: admin, user, readonly
#   4. Create / update "Flui Web" OIDC SPA app (HTTPS redirects + dev origin)
#   5. Create / update "Flui CLI" OIDC native app (loopback ports 8899-8910)
#   6. Grant admin role to flui-admin user
#   7. Patch flui-secrets, flui-web-config, flui-api-config
#   8. Restart flui-api and flui-web deployments
# =============================================================================
set -euo pipefail

log()   { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; exit 1; }
ok()    { echo -e "\033[0;32m[OK]\033[0m    $*"; }

zitadel_curl() { curl -s -H "Host: ${ZITADEL_DOMAIN}" "$@"; }
zitadel_api()  {
  curl -s -H "Host: ${ZITADEL_DOMAIN}" \
    -H "Authorization: Bearer ${PAT}" \
    -H "Content-Type: application/json" \
    "$@"
}

if ! command -v jq &>/dev/null; then
  log "Installing jq..."
  apt-get update -qq && apt-get install -y -qq jq >/dev/null 2>&1
fi

# --- Discover cluster info ---------------------------------------------------
MASTER_IP="${MASTER_IP:-$(hostname -I | awk '{print $1}')}"
NIP_HOSTNAME_TOKEN="${NIP_HOSTNAME_TOKEN:-}"
DASHED_IP="${MASTER_IP//./-}"
if [ -z "${FLUI_BASE_DOMAIN:-}" ]; then
  if [ -n "$NIP_HOSTNAME_TOKEN" ]; then
    FLUI_BASE_DOMAIN="${NIP_HOSTNAME_TOKEN}.${DASHED_IP}.nip.io"
  else
    FLUI_BASE_DOMAIN="${DASHED_IP}.nip.io"
  fi
fi
ZITADEL_DOMAIN="${ZITADEL_DOMAIN:-auth.${FLUI_BASE_DOMAIN}}"
ZITADEL_SVC="http://$(kubectl get svc zitadel -n flui-system -o jsonpath='{.spec.clusterIP}'):8080"

log "Master IP:        ${MASTER_IP}"
log "Flui base domain: ${FLUI_BASE_DOMAIN}"
log "Zitadel domain:   ${ZITADEL_DOMAIN}"

# --- Wait for Zitadel ready --------------------------------------------------
log "Waiting for Zitadel readiness..."
for _ in $(seq 1 120); do
  if zitadel_curl -fsS "${ZITADEL_SVC}/debug/ready" >/dev/null 2>&1; then
    ok "Zitadel is healthy"
    break
  fi
  sleep 5
done
zitadel_curl -fsS "${ZITADEL_SVC}/debug/ready" >/dev/null 2>&1 || \
  error "Zitadel did not become ready in 10 minutes"

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
        "volumeMounts": [{"name": "bootstrap", "mountPath": "/bootstrap"}]
      }],
      "volumes": [{
        "name": "bootstrap",
        "persistentVolumeClaim": {"claimName": "zitadel-bootstrap-pvc"}
      }]
    }
  }' 2>&1 || true)
# PAT is a JOSE compact token; Zitadel uses JWE with 5 segments.
# Take the first line of the file content and strip whitespace.
PAT=$(echo "$PAT_RAW" | grep -E '^[A-Za-z0-9_.-]+$' | head -1 | tr -d '[:space:]')
[ -z "$PAT" ] && error "Could not read PAT from bootstrap PVC"
ok "PAT obtained (${#PAT} chars)"

# --- Step 2: Verify PAT ------------------------------------------------------
ME_RESPONSE=$(zitadel_api "${ZITADEL_SVC}/auth/v1/users/me")
MY_USERNAME=$(echo "$ME_RESPONSE" | jq -r '.user.userName // empty')
[ -z "$MY_USERNAME" ] && error "PAT verification failed: ${ME_RESPONSE}"
ok "Authenticated as: ${MY_USERNAME}"

# --- Step 3: Create / find Flui project --------------------------------------
log "Ensuring Flui project..."
SEARCH=$(zitadel_api "${ZITADEL_SVC}/management/v1/projects/_search" \
  -d '{"queries":[{"nameQuery":{"name":"Flui","method":"TEXT_QUERY_METHOD_EQUALS"}}]}')
PROJECT_ID=$(echo "$SEARCH" | jq -r '.result[0].id // empty')

if [ -z "$PROJECT_ID" ]; then
  CREATE=$(zitadel_api "${ZITADEL_SVC}/management/v1/projects" \
    -d '{"name":"Flui","projectRoleAssertion":true,"projectRoleCheck":false,"hasProjectCheck":false,"privateLabelingSetting":"PRIVATE_LABELING_SETTING_UNSPECIFIED"}')
  PROJECT_ID=$(echo "$CREATE" | jq -r '.id // empty')
  [ -z "$PROJECT_ID" ] && error "Failed to create project: ${CREATE}"
  ok "Project created: ${PROJECT_ID}"
else
  ok "Project found: ${PROJECT_ID}"
fi

# --- Step 4: Create roles (admin, user, readonly) ----------------------------
for role_pair in "admin:Administrator" "user:User" "readonly:Read-only / Demo"; do
  KEY="${role_pair%%:*}"
  DISPLAY="${role_pair#*:}"
  RESP=$(zitadel_api "${ZITADEL_SVC}/management/v1/projects/${PROJECT_ID}/roles" \
    -d "{\"roleKey\":\"${KEY}\",\"displayName\":\"${DISPLAY}\"}")
  CODE=$(echo "$RESP" | jq -r '.code // 0')
  if [ "$CODE" = "6" ]; then
    ok "Role '${KEY}' already exists"
  else
    ok "Role '${KEY}' created"
  fi
done

# --- Step 5: Create / update Flui Web OIDC SPA app ---------------------------
log "Ensuring Flui Web OIDC app..."
WEB_REDIRECTS=$(jq -nc \
  --arg main "https://app.${FLUI_BASE_DOMAIN}/auth/callback" \
  --arg dev  "http://localhost:4200/auth/callback" \
  '[$main, $dev]')
WEB_POST_LOGOUT=$(jq -nc \
  --arg main  "https://app.${FLUI_BASE_DOMAIN}" \
  --arg mainl "https://app.${FLUI_BASE_DOMAIN}/login?loggedOut=true" \
  --arg dev   "http://localhost:4200" \
  --arg devl  "http://localhost:4200/login?loggedOut=true" \
  '[$main, $mainl, $dev, $devl]')

APP_SEARCH=$(zitadel_api "${ZITADEL_SVC}/management/v1/projects/${PROJECT_ID}/apps/_search" \
  -d '{"queries":[{"nameQuery":{"name":"Flui Web","method":"TEXT_QUERY_METHOD_EQUALS"}}]}')
WEB_APP_ID=$(echo "$APP_SEARCH" | jq -r '.result[0].id // empty')
WEB_CLIENT_ID=$(echo "$APP_SEARCH" | jq -r '.result[0].oidcConfig.clientId // empty')

if [ -z "$WEB_APP_ID" ]; then
  CREATE=$(zitadel_api "${ZITADEL_SVC}/management/v1/projects/${PROJECT_ID}/apps/oidc" \
    -d "$(jq -nc --argjson redirects "$WEB_REDIRECTS" --argjson logout "$WEB_POST_LOGOUT" '{
      name: "Flui Web",
      redirectUris: $redirects,
      postLogoutRedirectUris: $logout,
      responseTypes: ["OIDC_RESPONSE_TYPE_CODE"],
      grantTypes: ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE"],
      appType: "OIDC_APP_TYPE_USER_AGENT",
      authMethodType: "OIDC_AUTH_METHOD_TYPE_NONE",
      accessTokenType: "OIDC_TOKEN_TYPE_JWT",
      accessTokenRoleAssertion: true,
      idTokenRoleAssertion: true,
      idTokenUserinfoAssertion: true,
      devMode: true
    }')")
  WEB_APP_ID=$(echo "$CREATE" | jq -r '.appId // empty')
  WEB_CLIENT_ID=$(echo "$CREATE" | jq -r '.clientId // empty')
  [ -z "$WEB_CLIENT_ID" ] && error "Failed to create Flui Web app: ${CREATE}"
  ok "Flui Web app created: ${WEB_APP_ID} (client ${WEB_CLIENT_ID})"
else
  ok "Flui Web app found: ${WEB_APP_ID} (client ${WEB_CLIENT_ID})"
fi

# --- Step 6: Create / update Flui CLI OIDC native app ------------------------
log "Ensuring Flui CLI OIDC app..."
CLI_REDIRECTS=$(jq -nc '[
  "http://localhost:8899/callback",
  "http://localhost:8900/callback",
  "http://localhost:8901/callback",
  "http://localhost:8902/callback",
  "http://localhost:8910/callback"
]')

CLI_SEARCH=$(zitadel_api "${ZITADEL_SVC}/management/v1/projects/${PROJECT_ID}/apps/_search" \
  -d '{"queries":[{"nameQuery":{"name":"Flui CLI","method":"TEXT_QUERY_METHOD_EQUALS"}}]}')
CLI_APP_ID=$(echo "$CLI_SEARCH" | jq -r '.result[0].id // empty')
CLI_CLIENT_ID=$(echo "$CLI_SEARCH" | jq -r '.result[0].oidcConfig.clientId // empty')

if [ -z "$CLI_APP_ID" ]; then
  CREATE=$(zitadel_api "${ZITADEL_SVC}/management/v1/projects/${PROJECT_ID}/apps/oidc" \
    -d "$(jq -nc --argjson redirects "$CLI_REDIRECTS" '{
      name: "Flui CLI",
      redirectUris: $redirects,
      postLogoutRedirectUris: [],
      responseTypes: ["OIDC_RESPONSE_TYPE_CODE"],
      grantTypes: ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE"],
      appType: "OIDC_APP_TYPE_NATIVE",
      authMethodType: "OIDC_AUTH_METHOD_TYPE_NONE",
      accessTokenType: "OIDC_TOKEN_TYPE_JWT",
      accessTokenRoleAssertion: true,
      idTokenRoleAssertion: true,
      idTokenUserinfoAssertion: true,
      devMode: true
    }')")
  CLI_APP_ID=$(echo "$CREATE" | jq -r '.appId // empty')
  CLI_CLIENT_ID=$(echo "$CREATE" | jq -r '.clientId // empty')
  [ -z "$CLI_APP_ID" ] && error "Failed to create Flui CLI app: ${CREATE}"
  ok "Flui CLI app created: ${CLI_APP_ID} (client ${CLI_CLIENT_ID})"
else
  ok "Flui CLI app found: ${CLI_APP_ID} (client ${CLI_CLIENT_ID})"
fi

# --- Step 7: Grant admin role to flui-admin ----------------------------------
log "Granting admin role to flui-admin..."
ADMIN_USER_ID=$(kubectl exec -n flui-system statefulset/postgres -- \
  psql -U zitadel_user -d zitadel -t -A -c \
  "SELECT id FROM projections.users14 WHERE username LIKE 'flui-admin%' AND type=1;" 2>/dev/null | tr -d '[:space:]')

if [ -n "$ADMIN_USER_ID" ]; then
  GRANT=$(zitadel_api "${ZITADEL_SVC}/management/v1/users/${ADMIN_USER_ID}/grants" \
    -d "{\"projectId\":\"${PROJECT_ID}\",\"roleKeys\":[\"admin\"]}")
  GRANT_CODE=$(echo "$GRANT" | jq -r '.code // 0')
  if [ "$GRANT_CODE" = "0" ]; then
    ok "Admin role granted to flui-admin (${ADMIN_USER_ID})"
  else
    warn "Grant response: ${GRANT}"
  fi
else
  warn "Could not find flui-admin user — grant role manually"
fi

# --- Step 7.5: Ensure bootstrap admin user (ADMIN_EMAIL) ---------------------
# Mirrors API OidcBootstrapService.ensureBootstrapAdmin: creates the operational
# human user from ADMIN_EMAIL/ADMIN_PASSWORD and grants admin role on the Flui
# project. The default flui-admin@... user remains as a recovery account.
if [ -n "${ADMIN_EMAIL:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
  log "Ensuring bootstrap admin user '${ADMIN_EMAIL}'..."
  USER_SEARCH=$(zitadel_api "${ZITADEL_SVC}/management/v1/users/_search" \
    -d "$(jq -nc --arg e "$ADMIN_EMAIL" '{queries:[{emailQuery:{emailAddress:$e,method:"TEXT_QUERY_METHOD_EQUALS"}}]}')")
  ADMIN_HUMAN_ID=$(echo "$USER_SEARCH" | jq -r '.result[0].id // empty')

  if [ -z "$ADMIN_HUMAN_ID" ]; then
    CREATE=$(zitadel_api "${ZITADEL_SVC}/management/v1/users/human/_import" \
      -d "$(jq -nc --arg u "$ADMIN_EMAIL" --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASSWORD" '{
        userName: $u,
        profile: {firstName: "Flui", lastName: "Admin", displayName: "Flui Admin"},
        email: {email: $e, isEmailVerified: true},
        password: $p,
        passwordChangeRequired: true
      }')")
    ADMIN_HUMAN_ID=$(echo "$CREATE" | jq -r '.userId // empty')
    if [ -z "$ADMIN_HUMAN_ID" ]; then
      warn "Failed to create bootstrap admin user: ${CREATE}"
    else
      ok "Bootstrap admin user created: ${ADMIN_EMAIL} (${ADMIN_HUMAN_ID})"
    fi
  else
    ok "Bootstrap admin user already exists: ${ADMIN_EMAIL} (${ADMIN_HUMAN_ID})"
  fi

  if [ -n "$ADMIN_HUMAN_ID" ]; then
    GRANT=$(zitadel_api "${ZITADEL_SVC}/management/v1/users/${ADMIN_HUMAN_ID}/grants" \
      -d "{\"projectId\":\"${PROJECT_ID}\",\"roleKeys\":[\"admin\"]}")
    GRANT_CODE=$(echo "$GRANT" | jq -r '.code // 0')
    if [ "$GRANT_CODE" = "0" ] || [ "$GRANT_CODE" = "6" ]; then
      ok "Admin role ensured for ${ADMIN_EMAIL}"
    else
      warn "Grant response for ${ADMIN_EMAIL}: ${GRANT}"
    fi
  fi
else
  warn "ADMIN_EMAIL or ADMIN_PASSWORD not set — skipping custom admin user creation"
fi

# --- Step 7.6: Ensure email/name claim action --------------------------------
log "Ensuring email claim action in Zitadel..."
EMAIL_ACTION_NAME="fluiAddEmailClaim"
EMAIL_ACTION_SCRIPT='function fluiAddEmailClaim(ctx, api) {
  var human = ctx.v1 && ctx.v1.user && ctx.v1.user.human;
  if (!human) { return; }
  if (human.email && human.email.address) {
    api.v1.claims.setClaim("email", human.email.address);
    api.v1.claims.setClaim("email_verified", human.email.isVerified === true);
  }
  var profile = human.profile;
  if (profile) {
    var parts = [profile.firstName, profile.lastName].filter(function(p) { return !!p; });
    if (parts.length > 0) { api.v1.claims.setClaim("name", parts.join(" ")); }
    if (profile.firstName) { api.v1.claims.setClaim("given_name", profile.firstName); }
    if (profile.lastName) { api.v1.claims.setClaim("family_name", profile.lastName); }
  }
}'

ACTION_SEARCH=$(zitadel_api "${ZITADEL_SVC}/management/v1/actions/_search" \
  -d '{"query":{"limit":100}}')
EMAIL_ACTION_ID=$(echo "$ACTION_SEARCH" | \
  jq -r --arg n "$EMAIL_ACTION_NAME" '.result[]? | select(.name==$n) | .id // empty' | head -1)

if [ -z "$EMAIL_ACTION_ID" ]; then
  CREATE=$(zitadel_api "${ZITADEL_SVC}/management/v1/actions" \
    -d "$(jq -nc --arg name "$EMAIL_ACTION_NAME" --arg script "$EMAIL_ACTION_SCRIPT" '{
      name: $name, script: $script, timeout: "10s", allowedToFail: true
    }')")
  EMAIL_ACTION_ID=$(echo "$CREATE" | jq -r '.id // empty')
  [ -z "$EMAIL_ACTION_ID" ] && warn "Could not create email claim action: ${CREATE}" || ok "Email claim action created: ${EMAIL_ACTION_ID}"
else
  ok "Email claim action already exists: ${EMAIL_ACTION_ID}"
fi

if [ -n "$EMAIL_ACTION_ID" ]; then
  TRIGGER_RESP=$(zitadel_api \
    "${ZITADEL_SVC}/management/v1/org/flows/FLOW_TYPE_COMPLEMENT_TOKEN/trigger/TRIGGER_TYPE_PRE_ACCESS_TOKEN_CREATION" \
    -X PUT \
    -d "$(jq -nc --arg id "$EMAIL_ACTION_ID" '{"actionIds":[$id]}')")
  ok "Email claim trigger linked"
fi

# --- Step 8: Patch flui-secrets ----------------------------------------------
log "Patching flui-secrets..."
kubectl patch secret flui-secrets -n flui-system --type merge \
  -p "{\"stringData\":{\"OIDC_AUDIENCE\":\"${WEB_CLIENT_ID}\",\"ZITADEL_SERVICE_ACCOUNT_PAT\":\"${PAT}\"}}"
ok "flui-secrets patched"

# --- Step 9: Patch flui-web-config -------------------------------------------
log "Patching flui-web-config..."
kubectl get configmap flui-web-config -n flui-system -o json | \
  python3 -c "
import sys, json
cm = json.load(sys.stdin)
config = json.loads(cm['data'].get('config.json', '{}'))
config['authMode'] = 'oidc'
config['oidcIssuer'] = 'https://${ZITADEL_DOMAIN}'
config['oidcClientId'] = '${WEB_CLIENT_ID}'
cm.get('metadata', {}).pop('managedFields', None)
cm['data']['config.json'] = json.dumps(config, indent=2)
json.dump(cm, sys.stdout)" | kubectl apply -f -
ok "flui-web-config patched"

# --- Step 10: Patch flui-api-config ------------------------------------------
log "Patching flui-api-config..."
kubectl get configmap flui-api-config -n flui-system -o json | \
  python3 -c "
import sys, json
cm = json.load(sys.stdin)
cm['data']['AUTH_MODE'] = 'oidc'
cm['data']['OIDC_ISSUER'] = 'https://${ZITADEL_DOMAIN}'
cm['data']['OIDC_JWKS_URI'] = 'http://zitadel.flui-system.svc.cluster.local:8080/oauth/v2/keys'
cm['data']['OIDC_CLI_CLIENT_ID'] = '${CLI_CLIENT_ID}'
cm['data'].pop('ZITADEL_ISSUER', None)
cm['data'].pop('ZITADEL_JWKS_URI', None)
cm.get('metadata', {}).pop('managedFields', None)
json.dump(cm, sys.stdout)" | kubectl apply -f -
ok "flui-api-config patched"

# --- Step 11: Restart deployments (only if already running) ------------------
# When this script runs in parallel with the initial flui-api boot, the
# deployment may not yet exist. The kubectl rollout restart is a no-op in
# that case — the first pod will read the patched secret and config on boot.
if kubectl get deployment flui-api -n flui-system >/dev/null 2>&1; then
  log "Restarting flui-api and flui-web..."
  kubectl rollout restart deployment/flui-api deployment/flui-web -n flui-system
  ok "Deployments restarted"
else
  ok "flui-api deployment not yet created — patched config will be picked up on first boot"
fi

echo ""
echo "=============================================="
echo "  Zitadel OIDC setup complete!"
echo "=============================================="
echo "  Web Client ID:  ${WEB_CLIENT_ID}"
echo "  CLI Client ID:  ${CLI_CLIENT_ID}"
echo "  Project ID:     ${PROJECT_ID}"
