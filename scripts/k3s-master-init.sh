#!/bin/bash
# K3s Master Node Initialization Script
# This script installs and configures K3s as a server (master node)
set -euo pipefail

# Variables (replaced by K3sScriptService)
INSTANCE_ID="${INSTANCE_ID}"
SERVER_ID="${SERVER_ID:-}"
INSTANCE_NAME="${INSTANCE_NAME}"
CLOUD_PROVIDER="${CLOUD_PROVIDER}"
CLUSTER_ID="${CLUSTER_ID}"
CLUSTER_NAME="${CLUSTER_NAME}"
K3S_TOKEN="${K3S_TOKEN}"
K3S_VERSION="${K3S_VERSION:-v1.28.4+k3s1}"

# Observability stack configuration
DEPLOY_OBSERVABILITY_STACK="${DEPLOY_OBSERVABILITY_STACK:-false}"
MANIFESTS_BASE_URL="${MANIFESTS_BASE_URL:-https://raw.githubusercontent.com/flui-cloud/bootstrap-scripts/master/manifests}"

# Auth mode: "local" (built-in JWT, no Zitadel) or "oidc" (Zitadel/external OIDC provider)
AUTH_MODE="${AUTH_MODE:-local}"

# Certificate mode for the dashboard: "staging" (Let's Encrypt staging only),
# "preflight" (staging then auto-promote to production), or "production" (production directly)
CERTIFICATE_MODE="${CERTIFICATE_MODE:-production}"

# Multi-cluster observability configuration
OBSERVABILITY_CLUSTER_IP="${OBSERVABILITY_CLUSTER_IP:-}"
DEPLOY_MONITORING_AGENT="${DEPLOY_MONITORING_AGENT:-false}"

# Observability stack passwords
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-changeme_postgres}"
REDIS_PASSWORD="${REDIS_PASSWORD:-changeme_redis}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-changeme_grafana}"

# Zitadel identity provider configuration (required only when AUTH_MODE=oidc)
ZITADEL_MASTERKEY="${ZITADEL_MASTERKEY:-}"
ZITADEL_DB_ADMIN_PASSWORD="${ZITADEL_DB_ADMIN_PASSWORD:-}"
ZITADEL_DB_USER_PASSWORD="${ZITADEL_DB_USER_PASSWORD:-}"
ZITADEL_DOMAIN="${ZITADEL_DOMAIN:-}"
ZITADEL_ADMIN_EMAIL="${ZITADEL_ADMIN_EMAIL:-admin@flui.cloud}"
ZITADEL_ADMIN_TEMP_PASSWORD="${ZITADEL_ADMIN_TEMP_PASSWORD:-ChangeMe123!}"
ZITADEL_AUDIENCE="${ZITADEL_AUDIENCE:-}"

# Local auth configuration (required only when AUTH_MODE=local)
JWT_SECRET="${JWT_SECRET:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"

LOG_FILE="/var/log/k3s-master-init.log"
HEALTH_FILE="/var/log/observability-health.json"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

warn() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1" | tee -a "$LOG_FILE"
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE"
    exit 1
}

# Update health status file (for CLI polling during cluster creation)
# Note: The health server also provides dynamic checks via HTTP endpoint
update_health() {
    local status="$1"
    local component="${2:-}"
    local error_msg="${3:-}"

    cat > "$HEALTH_FILE" <<EOF
{
  "status": "$status",
  "component": "$component",
  "error": "$error_msg",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

# Test connectivity to observability cluster (for workload clusters)
test_observability_connectivity() {
    local OBS_CLUSTER_IP="$1"

    if [ -z "$OBS_CLUSTER_IP" ]; then
        return 0  # No observability cluster configured, skip test
    fi

    log "Testing connectivity to observability cluster at $OBS_CLUSTER_IP..."

    # Test 1: Ping (may fail if ICMP blocked)
    if ping -c 2 -W 3 "$OBS_CLUSTER_IP" &>/dev/null; then
        log "  ✓ Observability cluster host is reachable (ping)"
    else
        warn "  ⚠ Observability cluster not responding to ping (may be blocked)"
    fi

    # Test 2: TCP connection to Loki port (30100)
    log "  Testing Loki port (30100)..."
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$OBS_CLUSTER_IP/30100" 2>/dev/null; then
        log "  ✓ Loki port 30100 is reachable"
    else
        warn "  ✗ Loki port 30100 is NOT reachable - logs will not be forwarded"
        warn "    Check firewall rules on observability cluster"
    fi

    # Test 3: TCP connection to Prometheus port (30090) - optional
    log "  Testing Prometheus port (30090)..."
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$OBS_CLUSTER_IP/30090" 2>/dev/null; then
        log "  ✓ Prometheus port 30090 is reachable"
    else
        warn "  ⚠ Prometheus port 30090 is NOT reachable - metrics scraping may fail"
    fi

    # Measure network latency
    local START_TIME=$(date +%s%N 2>/dev/null || echo "0")
    if timeout 3 bash -c "cat < /dev/null > /dev/tcp/$OBS_CLUSTER_IP/30100" 2>/dev/null; then
        local END_TIME=$(date +%s%N 2>/dev/null || echo "$START_TIME")
        if [ "$START_TIME" != "0" ] && [ "$END_TIME" != "$START_TIME" ]; then
            local LATENCY_MS=$(( (END_TIME - START_TIME) / 1000000 ))
            log "  ℹ Network latency to observability cluster: ${LATENCY_MS}ms"
        fi
    fi

    log "Connectivity test to observability cluster completed"
}

log "=== K3s Master Node Initialization ==="
log "Cluster: $CLUSTER_NAME (ID: $CLUSTER_ID)"
log "Instance: $INSTANCE_NAME (ID: $INSTANCE_ID)"
log "Provider: $CLOUD_PROVIDER"
log "K3s Version: $K3S_VERSION"
log "Deploy Observability Stack: $DEPLOY_OBSERVABILITY_STACK"
if [ -n "$OBSERVABILITY_CLUSTER_IP" ]; then
    log "Observability Cluster IP: $OBSERVABILITY_CLUSTER_IP (logs will be forwarded)"
fi

# Initialize health status
update_health "initializing" "k3s" ""

# ============================================================
# STEP 1: Run base Flui.cloud initialization
# This installs Podman, monitoring, logging, and SSH CA
# ============================================================
log "Running Flui.cloud base initialization..."

# Download flui-init.sh from GitHub
SCRIPTS_BASE_URL="${SCRIPTS_BASE_URL:-https://raw.githubusercontent.com/flui-cloud/bootstrap-scripts/master/scripts}"
log "Downloading flui-init.sh from $SCRIPTS_BASE_URL..."

if ! curl -fsSL "$SCRIPTS_BASE_URL/flui-init.sh" -o /tmp/flui-init.sh; then
    error "Failed to download flui-init.sh from $SCRIPTS_BASE_URL"
fi

chmod +x /tmp/flui-init.sh

# Download monitoring modules from GitHub
log "Downloading monitoring modules..."
mkdir -p /tmp/flui-modules

# Construct modules URL by replacing the last 'scripts' with 'modules'
MODULES_BASE_URL="${SCRIPTS_BASE_URL%/scripts}/modules"
log "Downloading from $MODULES_BASE_URL..."

if ! curl -fsSL "$MODULES_BASE_URL/node-exporter.sh" -o /tmp/flui-modules/node-exporter.sh; then
    warn "Failed to download node-exporter.sh - monitoring may be disabled"
fi

if ! curl -fsSL "$MODULES_BASE_URL/vector.sh" -o /tmp/flui-modules/vector.sh; then
    warn "Failed to download vector.sh - monitoring may be disabled"
fi

if ! curl -fsSL "$MODULES_BASE_URL/monitoring.sh" -o /tmp/flui-modules/monitoring.sh; then
    warn "Failed to download monitoring.sh - monitoring may be disabled"
fi

chmod +x /tmp/flui-modules/*.sh 2>/dev/null || true

# Download diagnostic scripts and install to /usr/local/bin/
log "Downloading diagnostic scripts..."
if curl -fsSL "$SCRIPTS_BASE_URL/diagnose-monitoring.sh" -o /usr/local/bin/diagnose-monitoring.sh; then
    chmod +x /usr/local/bin/diagnose-monitoring.sh
    log "✓ Installed diagnose-monitoring.sh to /usr/local/bin/"
else
    warn "Failed to download diagnose-monitoring.sh - diagnostic tools may be limited"
fi

if curl -fsSL "$SCRIPTS_BASE_URL/check-observability-cluster.sh" -o /usr/local/bin/check-observability-cluster.sh; then
    chmod +x /usr/local/bin/check-observability-cluster.sh
    log "✓ Installed check-observability-cluster.sh to /usr/local/bin/"
else
    warn "Failed to download check-observability-cluster.sh - diagnostic tools may be limited"
fi

# Test connectivity to observability cluster BEFORE configuring monitoring
if [ "$DEPLOY_OBSERVABILITY_STACK" = "false" ] && [ -n "$OBSERVABILITY_CLUSTER_IP" ]; then
    test_observability_connectivity "$OBSERVABILITY_CLUSTER_IP"
fi

# Export monitoring endpoints for self-monitoring
# For workload clusters, override Loki endpoint to send logs to remote observability cluster
# For observability clusters, keep localhost configuration
if [ "$DEPLOY_OBSERVABILITY_STACK" = "false" ] && [ -n "$OBSERVABILITY_CLUSTER_IP" ]; then
    # Workload cluster - send logs to remote observability cluster
    export LOKI_ENDPOINT="${OBSERVABILITY_CLUSTER_IP}:30100"
    log "Configuring workload cluster to send logs to observability cluster at ${OBSERVABILITY_CLUSTER_IP}:30100"
else
    # Observability cluster or no observability cluster configured - use localhost
    export LOKI_ENDPOINT="localhost:30100"
fi

export PROMETHEUS_ENDPOINT="localhost:30090"
export FLUI_API_ENDPOINT="${FLUI_API_ENDPOINT:-http://localhost:3000}"
# Validate SERVER_ID
if [[ -z "$SERVER_ID" ]]; then
    error "SERVER_ID not provided - this should be the database node ID from infrastructure_cluster_nodes table"
fi
log "Using database node ID as SERVER_ID: $SERVER_ID"
export SERVER_TYPE="k3s-master"
export SERVER_ID

# Export CA public key for SSH certificate authentication (if provided)
if [[ -n "${FLUI_CA_PUBLIC_KEY:-}" ]]; then
    log "Exporting SSH CA public key for flui-init.sh..."
    export FLUI_CA_PUBLIC_KEY
else
    warn "FLUI_CA_PUBLIC_KEY not set - SSH certificate authentication will be skipped"
fi

if ! /tmp/flui-init.sh; then
    error "Flui.cloud base initialization failed"
fi
rm -f /tmp/flui-init.sh

log "Flui.cloud base initialization completed successfully"

# ============================================================
# STEP 2: Install kubectl
# ============================================================
log "Installing kubectl for cluster interaction..."

# Install kubectl via snap (fast, always up-to-date)
if ! command -v snap &> /dev/null; then
    log "snap not available, installing kubectl via curl..."
    KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    chmod +x kubectl
    mv kubectl /usr/local/bin/kubectl
else
    log "Installing kubectl via snap..."
    snap install kubectl --classic 2>&1 | tee -a "$LOG_FILE" || {
        warn "snap install failed, trying curl method..."
        KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
        curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
        chmod +x kubectl
        mv kubectl /usr/local/bin/kubectl
    }

    # Wait for snap to update PATH and make kubectl available
    log "Waiting for snap to configure kubectl..."
    sleep 3

    # Retry logic: wait up to 10 seconds for kubectl to be available
    RETRY_COUNT=0
    MAX_RETRIES=10
    until command -v kubectl &> /dev/null; do
        if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
            warn "kubectl not found in PATH after ${MAX_RETRIES} retries, trying curl method..."
            KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
            curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
            chmod +x kubectl
            mv kubectl /usr/local/bin/kubectl
            break
        fi
        log "Waiting for kubectl to be available in PATH (attempt $((RETRY_COUNT + 1))/${MAX_RETRIES})..."
        sleep 1
        RETRY_COUNT=$((RETRY_COUNT + 1))
    done
fi

# Verify kubectl installation
log "Verifying kubectl installation..."
if command -v kubectl &> /dev/null; then
    log "kubectl found in PATH: $(which kubectl)"

    # Disable pipefail temporarily for kubectl version check
    # (kubectl version may have non-zero exit code in some cases)
    set +e
    KUBECTL_VERSION=$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>&1 | head -1)
    KUBECTL_EXIT_CODE=$?
    set -e

    if [ $KUBECTL_EXIT_CODE -eq 0 ]; then
        log "✅ kubectl installed: $KUBECTL_VERSION"
    else
        warn "kubectl version check returned exit code $KUBECTL_EXIT_CODE, but kubectl is available"
        log "✅ kubectl installed at $(which kubectl)"
    fi
else
    error "kubectl installation failed - command not found"
fi

# ============================================================
# STEP 3: Install K3s Master
# ============================================================

# Get primary IP address
PRIMARY_IP=$(hostname -I | awk '{print $1}')
log "Primary IP address: $PRIMARY_IP"

if [ -z "${PRIVATE_IP:-}" ]; then
  PRIVATE_IP=$(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
    | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | head -1 || true)
fi

PRIVATE_IFACE=""
if [ -n "${PRIVATE_IP:-}" ]; then
  PRIVATE_IFACE=$(ip -4 -o addr show 2>/dev/null \
    | awk -v ip="$PRIVATE_IP" '$4 ~ "^"ip"/" {print $2; exit}' || true)
fi
log "VNet private IP: ${PRIVATE_IP:-(not detected)} on iface ${PRIVATE_IFACE:-(none)}"

K3S_NODE_IP_FLAGS=""
if [ -n "${PRIVATE_IP:-}" ] && [ -n "${PRIVATE_IFACE:-}" ]; then
  K3S_NODE_IP_FLAGS="--node-ip=$PRIVATE_IP --advertise-address=$PRIVATE_IP --flannel-iface=$PRIVATE_IFACE"
  log "K3s will bind to private IP $PRIVATE_IP via $PRIVATE_IFACE"
fi

# Install K3s as server (master)
log "Installing K3s server..."
log "K3s version: $K3S_VERSION"
log "Node name: $INSTANCE_NAME"
log "Flannel backend: vxlan"
log "TLS SAN: $PRIMARY_IP${PRIVATE_IP:+,$PRIVATE_IP}"

# Capture K3s installation output
K3S_INSTALL_LOG="/var/log/k3s-install.log"
log "Downloading K3s installation script..."

curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="$K3S_VERSION" \
  sh -s - server \
  --token "$K3S_TOKEN" \
  --cluster-init \
  --disable servicelb \
  --node-name="$INSTANCE_NAME" \
  --flannel-backend=vxlan \
  --tls-san="$PRIMARY_IP" \
  ${PRIVATE_IP:+--tls-san="$PRIVATE_IP"} \
  $K3S_NODE_IP_FLAGS \
  --write-kubeconfig-mode=644 2>&1 | tee "$K3S_INSTALL_LOG" || {
    log "K3s installation failed! See $K3S_INSTALL_LOG for details"
    log "Last 50 lines of installation log:"
    tail -50 "$K3S_INSTALL_LOG" | tee -a "$LOG_FILE"
    error "Failed to install K3s"
}

log "✅ K3s installation script completed"

# ============================================================
# CONFIGURE KUBECONFIG FOR KUBECTL
# ============================================================
log "Configuring kubectl to use K3s kubeconfig..."

# Export KUBECONFIG for this shell session (CRITICAL: must be set before kubectl commands)
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Create .kube directory for root user
mkdir -p /root/.kube

# Create symlink to k3s kubeconfig
ln -sf /etc/rancher/k3s/k3s.yaml /root/.kube/config

# Add KUBECONFIG to bashrc for future sessions
if ! grep -q "KUBECONFIG" /root/.bashrc; then
    echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> /root/.bashrc
fi

log "✅ KUBECONFIG configured: /etc/rancher/k3s/k3s.yaml"

# ============================================================
# STEP 4: Wait for K3s service to be active
# ============================================================
log "Waiting for K3s service to be active..."
log "Maximum wait time: 120 seconds"
MAX_WAIT=120
ELAPSED=0
until systemctl is-active --quiet k3s; do
  if [ $ELAPSED -ge $MAX_WAIT ]; then
    log "❌ K3s service did not become active within ${MAX_WAIT} seconds"
    log "Service status:"
    systemctl status k3s --no-pager | tee -a "$LOG_FILE"
    log "Recent K3s logs:"
    journalctl -u k3s -n 50 --no-pager | tee -a "$LOG_FILE"
    error "K3s service failed to start"
  fi
  log "⏳ K3s service not yet active (elapsed: ${ELAPSED}s), waiting..."
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

log "✅ K3s service is active (took ${ELAPSED}s)"
log "Service status:"
(systemctl status k3s --no-pager | head -20 | tee -a "$LOG_FILE") || true

# ============================================================
# STEP 5: Wait for kubectl to be functional
# ============================================================
log "Waiting for kubectl to be functional..."
log "Checking if K3s API server is responding..."
ELAPSED=0
until kubectl get nodes 2>/dev/null | grep -q "$INSTANCE_NAME"; do
  if [ $ELAPSED -ge $MAX_WAIT ]; then
    log "❌ kubectl did not become functional within ${MAX_WAIT} seconds"
    log "Attempting kubectl cluster-info:"
    kubectl cluster-info 2>&1 | tee -a "$LOG_FILE"
    log "K3s API server logs:"
    journalctl -u k3s -n 50 --no-pager | grep -i "apiserver\|error\|fatal" | tee -a "$LOG_FILE"
    error "kubectl failed to become functional"
  fi
  log "⏳ kubectl not yet functional (elapsed: ${ELAPSED}s), waiting..."
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

log "✅ kubectl is functional (took ${ELAPSED}s)"

# ============================================================
# STEP 6: Wait for node to be Ready
# ============================================================
log "Waiting for node to be Ready..."
log "Checking node status..."
ELAPSED=0
until kubectl get nodes | grep "$INSTANCE_NAME" | grep -q Ready; do
  if [ $ELAPSED -ge $MAX_WAIT ]; then
    log "❌ Node did not become Ready within ${MAX_WAIT} seconds"
    log "Current node status:"
    kubectl get nodes -o wide | tee -a "$LOG_FILE"
    log "Node details:"
    kubectl describe node "$INSTANCE_NAME" | tee -a "$LOG_FILE"
    log "System pods status:"
    kubectl get pods -n kube-system -o wide | tee -a "$LOG_FILE"
    error "Node failed to become Ready"
  fi

  # Show current node status every 15 seconds
  if [ $((ELAPSED % 15)) -eq 0 ]; then
    NODE_STATUS=$(kubectl get nodes | grep "$INSTANCE_NAME" | awk '{print $2}')
    log "⏳ Node status: $NODE_STATUS (elapsed: ${ELAPSED}s)"
  fi

  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

log "✅ K3s master node is Ready! (took ${ELAPSED}s)"

# ============================================================
# STEP 7: Display cluster information
# ============================================================
log "=========================================="
log "Cluster Information"
log "=========================================="
kubectl get nodes -o wide | tee -a "$LOG_FILE"
log ""
kubectl cluster-info | tee -a "$LOG_FILE"

log ""
log "Master node IP: $PRIMARY_IP"
log "API Server: https://$PRIMARY_IP:6443"
log "Kubeconfig: /etc/rancher/k3s/k3s.yaml"
log "Token: [REDACTED]"

# ============================================================
# STEP 8: Check system pods deployment status
# ============================================================
log ""
log "=========================================="
log "System Pods Deployment Status"
log "=========================================="

# Wait for system pods to be deployed
log "Waiting for system pods to be scheduled..."
sleep 10

# Show all pods in kube-system namespace
log "Pods in kube-system namespace:"
kubectl get pods -n kube-system -o wide | tee -a "$LOG_FILE"

# Check each system pod status
log ""
log "Detailed pod status:"
SYSTEM_PODS=$(kubectl get pods -n kube-system --no-headers -o custom-columns=":metadata.name")
for POD in $SYSTEM_PODS; do
    STATUS=$(kubectl get pod "$POD" -n kube-system -o jsonpath='{.status.phase}')
    READY=$(kubectl get pod "$POD" -n kube-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')

    if [ "$STATUS" = "Running" ] && [ "$READY" = "True" ]; then
        log "  ✅ $POD: Running and Ready"
    elif [ "$STATUS" = "Running" ]; then
        log "  ⏳ $POD: Running but not Ready yet"
    else
        log "  ⚠️  $POD: Status=$STATUS Ready=$READY"
    fi
done

# Wait for critical system pods to be ready
log ""
log "Waiting for critical system pods to be ready..."
CRITICAL_PODS="coredns"
MAX_POD_WAIT=180
ELAPSED=0

for POD_PREFIX in $CRITICAL_PODS; do
    log "Checking $POD_PREFIX..."
    until kubectl get pods -n kube-system | grep "^$POD_PREFIX" | grep -q "Running"; do
        if [ $ELAPSED -ge $MAX_POD_WAIT ]; then
            log "⚠️  Warning: $POD_PREFIX did not become ready within ${MAX_POD_WAIT}s"
            log "Pod details:"
            kubectl describe pod -n kube-system -l k8s-app=$POD_PREFIX | tee -a "$LOG_FILE"
            break
        fi
        log "⏳ Waiting for $POD_PREFIX (elapsed: ${ELAPSED}s)..."
        sleep 5
        ELAPSED=$((ELAPSED + 5))
    done

    if kubectl get pods -n kube-system | grep "^$POD_PREFIX" | grep -q "Running"; then
        log "✅ $POD_PREFIX is running"
    fi
done

# Show all namespaces
log ""
log "All namespaces:"
kubectl get namespaces | tee -a "$LOG_FILE"

# Show all pods across all namespaces
log ""
log "All pods (all namespaces):"
kubectl get pods --all-namespaces -o wide | tee -a "$LOG_FILE"

# Check for any pods with issues
log ""
log "Checking for pods with issues..."
PROBLEM_PODS=$(kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null)
if [ -n "$PROBLEM_PODS" ]; then
    log "⚠️  Pods with issues found:"
    echo "$PROBLEM_PODS" | tee -a "$LOG_FILE"

    # Get detailed info for problem pods
    while IFS= read -r line; do
        NS=$(echo "$line" | awk '{print $1}')
        POD=$(echo "$line" | awk '{print $2}')
        log "Details for $NS/$POD:"
        kubectl describe pod "$POD" -n "$NS" | tail -30 | tee -a "$LOG_FILE"
    done <<< "$PROBLEM_PODS"
else
    log "✅ No pods with issues detected"
fi

# ============================================================
# STEP 9: Health verification checks
# ============================================================
log ""
log "=========================================="
log "Health Verification Checks"
log "=========================================="

# Check 1: API Server health
log "1. K3s API Server health:"
if kubectl get --raw /healthz &>/dev/null; then
    log "   ✅ API server is healthy"
else
    log "   ❌ API server health check failed"
fi

# Check 2: Component status
log ""
log "2. Component status:"
kubectl get cs 2>/dev/null | tee -a "$LOG_FILE" || log "   ⚠️  Component status not available"

# Check 3: Node conditions
log ""
log "3. Node conditions:"
kubectl describe node "$INSTANCE_NAME" | grep -A 10 "Conditions:" | tee -a "$LOG_FILE"

# Check 4: Resource usage
log ""
log "4. Resource usage:"
kubectl top node "$INSTANCE_NAME" 2>/dev/null | tee -a "$LOG_FILE" || log "   ⚠️  Metrics not yet available (metrics-server may not be installed)"

# Check 5: DNS resolution test
log ""
log "5. DNS resolution test:"
if kubectl run dns-test --image=busybox:1.28 --rm -it --restart=Never --command -- nslookup kubernetes.default &>/dev/null; then
    log "   ✅ DNS resolution working"
else
    log "   ⚠️  DNS test inconclusive (non-critical)"
fi

# Check 6: Service account creation
log ""
log "6. Service accounts:"
(kubectl get serviceaccounts --all-namespaces | head -10 | tee -a "$LOG_FILE") || true

# ============================================================
# STEP 10: Create success marker
# ============================================================
log ""
log "=========================================="
log "Cluster Setup Summary"
log "=========================================="
log "✅ K3s version: $K3S_VERSION"
log "✅ Node: $INSTANCE_NAME"
log "✅ IP: $PRIMARY_IP"
log "✅ API Server: https://$PRIMARY_IP:6443"
log "✅ Kubeconfig: /etc/rancher/k3s/k3s.yaml"
log "✅ kubectl installed and configured"
log ""

# ============================================================
# STEP 11: Install cert-manager
# ============================================================
log ""
log "=========================================="
log "Installing cert-manager"
log "=========================================="

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.17.1}"
log "cert-manager version: $CERT_MANAGER_VERSION"

log "→ Applying cert-manager manifests..."
if ! kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"; then
    warn "Failed to apply cert-manager manifests - TLS certificate management will not be available"
else
    log "→ Waiting for cert-manager deployments to be available..."

    CERT_MANAGER_TIMEOUT=120

    if kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=${CERT_MANAGER_TIMEOUT}s 2>/dev/null; then
        log "✅ cert-manager controller is ready"
    else
        warn "cert-manager controller did not become ready within ${CERT_MANAGER_TIMEOUT}s"
    fi

    if kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=${CERT_MANAGER_TIMEOUT}s 2>/dev/null; then
        log "✅ cert-manager webhook is ready"
    else
        warn "cert-manager webhook did not become ready within ${CERT_MANAGER_TIMEOUT}s"
    fi

    if kubectl wait --for=condition=Available deployment/cert-manager-cainjector -n cert-manager --timeout=${CERT_MANAGER_TIMEOUT}s 2>/dev/null; then
        log "✅ cert-manager CA injector is ready"
    else
        warn "cert-manager CA injector did not become ready within ${CERT_MANAGER_TIMEOUT}s"
    fi

    log "✅ cert-manager installation completed"

    # ============================================================
    # STEP 11b: Install cert-manager-webhook-hetzner (Hetzner only)
    # ============================================================
    if [ "$CLOUD_PROVIDER" = "hetzner" ]; then
        log ""
        log "=========================================="
        log "Installing cert-manager-webhook-hetzner"
        log "=========================================="

        HETZNER_WEBHOOK_VERSION="${HETZNER_WEBHOOK_VERSION:-0.6.7}"
        log "cert-manager-webhook-hetzner version: $HETZNER_WEBHOOK_VERSION"

        if ! command -v helm &>/dev/null; then
            log "→ Installing Helm..."
            curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        fi

        if helm repo list 2>/dev/null | grep -q hcloud; then
            helm repo update hcloud
        else
            helm repo add hcloud https://charts.hetzner.cloud
            helm repo update hcloud
        fi

        if helm upgrade --install cert-manager-webhook-hetzner \
            hcloud/cert-manager-webhook-hetzner \
            --namespace cert-manager \
            --version "${HETZNER_WEBHOOK_VERSION}" \
            --wait \
            --timeout 120s; then

            log "✅ cert-manager-webhook-hetzner installed"
        else
            warn "cert-manager-webhook-hetzner installation failed — DNS-01 wildcard certificates will not work"
        fi
    else
        log "Skipping cert-manager-webhook-hetzner (CLOUD_PROVIDER=$CLOUD_PROVIDER, not hetzner)"
    fi
fi

# ============================================================
# STEP 12: Deploy Observability Stack (Conditional)
# ============================================================
if [ "$DEPLOY_OBSERVABILITY_STACK" = "true" ]; then
    log ""
    log "=========================================="
    log "Deploying Observability Stack"
    log "=========================================="

    update_health "deploying" "observability-stack" ""

    log "Auth mode: $AUTH_MODE"

    # Validate secrets based on auth mode
    if [ "$AUTH_MODE" = "oidc" ]; then
        if [ -z "$ZITADEL_MASTERKEY" ] || [ -z "$ZITADEL_DB_ADMIN_PASSWORD" ] || [ -z "$ZITADEL_DB_USER_PASSWORD" ]; then
            error "AUTH_MODE=oidc requires ZITADEL_MASTERKEY, ZITADEL_DB_ADMIN_PASSWORD, ZITADEL_DB_USER_PASSWORD"
        fi
    else
        if [ -z "$JWT_SECRET" ]; then
            error "AUTH_MODE=local requires JWT_SECRET to be set"
        fi
    fi

    # Get primary IP for NodePort access
    PRIMARY_IP=$(hostname -I | awk '{print $1}')
    export MASTER_IP="$PRIMARY_IP"
    # Default Zitadel domain to nip.io-based domain if not explicitly set (oidc mode only)
    if [ "$AUTH_MODE" = "oidc" ] && [ -z "$ZITADEL_DOMAIN" ]; then
        ZITADEL_DOMAIN="auth.${PRIMARY_IP}.nip.io"
        log "ZITADEL_DOMAIN not set, defaulting to: $ZITADEL_DOMAIN"
    fi
    # Resolve OIDC env vars based on AUTH_MODE.
    # OIDC mode uses the in-cluster Zitadel Service URL for JWKS (stable, no TLS).
    if [ "$AUTH_MODE" = "oidc" ]; then
        OIDC_ISSUER="https://${ZITADEL_DOMAIN}"
        OIDC_JWKS_URI="http://zitadel.flui-system.svc.cluster.local:8080/oauth/v2/keys"
        OIDC_AUDIENCE="${ZITADEL_AUDIENCE}"
    else
        OIDC_ISSUER=""
        OIDC_JWKS_URI=""
        OIDC_AUDIENCE=""
    fi
    export ZITADEL_MASTERKEY ZITADEL_DB_ADMIN_PASSWORD ZITADEL_DB_USER_PASSWORD
    export ZITADEL_DOMAIN ZITADEL_ADMIN_EMAIL ZITADEL_ADMIN_TEMP_PASSWORD ZITADEL_AUDIENCE
    export OIDC_ISSUER OIDC_JWKS_URI OIDC_AUDIENCE
    export AUTH_MODE JWT_SECRET ADMIN_EMAIL ADMIN_PASSWORD CERTIFICATE_MODE

    # Create manifests directory for K3s auto-deploy
    MANIFEST_DIR="/var/lib/rancher/k3s/server/manifests"
    mkdir -p "$MANIFEST_DIR"

    log "Manifest directory: $MANIFEST_DIR"
    log "Downloading manifests from: $MANIFESTS_BASE_URL/observability/"
    log "Deploying components: namespace, postgres, redis, prometheus, loki, grafana"

    # Build manifest list — exclude Zitadel when using local auth mode
    MANIFESTS="00-secrets 01-namespace 02-postgres 03-redis 04-prometheus-config 04a-kube-state-metrics 05-prometheus 06-loki 07-grafana-datasources 08-grafana 09-flui-api 12-flui-web-config 10-flui-web 00a-traefik-config"
    if [ "$AUTH_MODE" = "oidc" ]; then
        MANIFESTS="$MANIFESTS 11-zitadel"
        log "AUTH_MODE=oidc: Zitadel will be deployed"
    else
        log "AUTH_MODE=local: Zitadel will NOT be deployed (using built-in JWT auth)"
    fi

    # Download and apply manifests from GitHub
    for manifest in $MANIFESTS; do
        log "→ Downloading ${manifest}.yaml..."

        # Download manifest
        if ! curl -fsSL "$MANIFESTS_BASE_URL/observability/${manifest}.yaml" -o "/tmp/${manifest}.yaml"; then
            error "Failed to download ${manifest}.yaml from $MANIFESTS_BASE_URL/observability/"
        fi

        # Substitute environment variables (POSTGRES_PASSWORD, REDIS_PASSWORD, GRAFANA_PASSWORD, ENCRYPTION_KEY, MASTER_IP, FLUI_API_ENDPOINT, CLUSTER_ID, SERVER_ID)
        # Note: envsubst is part of gettext-base package
        if command -v envsubst &> /dev/null; then
            export CLUSTER_ID SERVER_ID CLUSTER_NAME CLOUD_PROVIDER
            export ZITADEL_MASTERKEY ZITADEL_DB_ADMIN_PASSWORD ZITADEL_DB_USER_PASSWORD
            export ZITADEL_DOMAIN ZITADEL_ADMIN_EMAIL ZITADEL_ADMIN_TEMP_PASSWORD ZITADEL_AUDIENCE
            export OIDC_ISSUER OIDC_JWKS_URI OIDC_AUDIENCE
            export AUTH_MODE JWT_SECRET ADMIN_EMAIL ADMIN_PASSWORD CERTIFICATE_MODE
            envsubst < "/tmp/${manifest}.yaml" > "$MANIFEST_DIR/${manifest}.yaml"
        else
            log "⚠️  envsubst not found, using sed for variable substitution..."
            sed -e "s/\${POSTGRES_PASSWORD}/$POSTGRES_PASSWORD/g" \
                -e "s/\${REDIS_PASSWORD}/$REDIS_PASSWORD/g" \
                -e "s/\${GRAFANA_PASSWORD}/$GRAFANA_PASSWORD/g" \
                -e "s/\${ENCRYPTION_KEY}/$ENCRYPTION_KEY/g" \
                -e "s/\${MASTER_IP}/$MASTER_IP/g" \
                -e "s|\${FLUI_API_ENDPOINT}|$FLUI_API_ENDPOINT|g" \
                -e "s/\${CLUSTER_ID}/$CLUSTER_ID/g" \
                -e "s/\${SERVER_ID}/$SERVER_ID/g" \
                -e "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" \
                -e "s/\${CLOUD_PROVIDER}/$CLOUD_PROVIDER/g" \
                -e "s|\${ZITADEL_MASTERKEY}|$ZITADEL_MASTERKEY|g" \
                -e "s/\${ZITADEL_DB_ADMIN_PASSWORD}/$ZITADEL_DB_ADMIN_PASSWORD/g" \
                -e "s/\${ZITADEL_DB_USER_PASSWORD}/$ZITADEL_DB_USER_PASSWORD/g" \
                -e "s/\${ZITADEL_DOMAIN}/$ZITADEL_DOMAIN/g" \
                -e "s|\${OIDC_ISSUER}|$OIDC_ISSUER|g" \
                -e "s|\${OIDC_JWKS_URI}|$OIDC_JWKS_URI|g" \
                -e "s/\${OIDC_AUDIENCE}/$OIDC_AUDIENCE/g" \
                -e "s/\${ZITADEL_ADMIN_EMAIL}/$ZITADEL_ADMIN_EMAIL/g" \
                -e "s/\${ZITADEL_ADMIN_TEMP_PASSWORD}/$ZITADEL_ADMIN_TEMP_PASSWORD/g" \
                -e "s/\${ZITADEL_AUDIENCE}/$ZITADEL_AUDIENCE/g" \
                -e "s/\${AUTH_MODE}/$AUTH_MODE/g" \
                -e "s/\${CERTIFICATE_MODE}/$CERTIFICATE_MODE/g" \
                -e "s|\${JWT_SECRET}|$JWT_SECRET|g" \
                -e "s/\${ADMIN_EMAIL}/$ADMIN_EMAIL/g" \
                -e "s|\${ADMIN_PASSWORD}|$ADMIN_PASSWORD|g" \
                "/tmp/${manifest}.yaml" > "$MANIFEST_DIR/${manifest}.yaml"
        fi

        log "✅ ${manifest}.yaml deployed"
        rm -f "/tmp/${manifest}.yaml"
    done

    log "✅ All manifests downloaded and deployed to $MANIFEST_DIR"
    log "K3s will auto-apply these manifests..."

    # Wait for K3s to apply manifests and pods to be created (give it 30s)
    log "Waiting 30s for K3s to create resources..."
    sleep 30

    # Wait for each component to be ready
    log ""
    log "Waiting for observability stack components to be ready..."
    log "Maximum wait time: 10 minutes for databases, 5 minutes for other components"

    COMPONENT_TIMEOUT=300   # 5 minutes for most components
    POSTGRES_TIMEOUT=600    # 10 minutes for PostgreSQL (PVC binding + DB init)
    REDIS_TIMEOUT=600       # 10 minutes for Redis (PVC binding)

    # Wait for Postgres
    log "→ Waiting for PostgreSQL..."
    update_health "deploying" "postgres" ""
    if kubectl wait --for=condition=ready pod -l app=postgres -n flui-system --timeout=${POSTGRES_TIMEOUT}s 2>/dev/null; then
        log "✅ PostgreSQL is ready"
    else
        error_msg="PostgreSQL failed to become ready within ${POSTGRES_TIMEOUT}s"
        log "❌ $error_msg"
        update_health "failed" "postgres" "$error_msg"
        error "$error_msg"
    fi

    # Create Zitadel database and users on the shared PostgreSQL instance (oidc mode only)
    if [ "$AUTH_MODE" = "oidc" ]; then
        log "→ Creating Zitadel database and users on PostgreSQL..."
        kubectl exec -n flui-system statefulset/postgres -- \
            psql -U fluicloud -c "CREATE DATABASE zitadel;" 2>/dev/null || log "  (zitadel database already exists)"
        kubectl exec -n flui-system statefulset/postgres -- \
            psql -U fluicloud -c "CREATE USER zitadel_admin WITH CREATEDB CREATEROLE PASSWORD '${ZITADEL_DB_ADMIN_PASSWORD}';" 2>/dev/null || log "  (zitadel_admin user already exists)"
        kubectl exec -n flui-system statefulset/postgres -- \
            psql -U fluicloud -c "ALTER USER zitadel_admin WITH CREATEDB CREATEROLE;" 2>/dev/null || true
        kubectl exec -n flui-system statefulset/postgres -- \
            psql -U fluicloud -c "GRANT ALL PRIVILEGES ON DATABASE zitadel TO zitadel_admin;" 2>/dev/null || true
        kubectl exec -n flui-system statefulset/postgres -- \
            psql -U fluicloud -d zitadel -c "GRANT ALL ON SCHEMA public TO zitadel_admin;" 2>/dev/null || true
        kubectl exec -n flui-system statefulset/postgres -- \
            psql -U fluicloud -d zitadel -c "ALTER DATABASE zitadel OWNER TO zitadel_admin;" 2>/dev/null || true
        kubectl exec -n flui-system statefulset/postgres -- \
            psql -U fluicloud -c "CREATE USER zitadel_user WITH PASSWORD '${ZITADEL_DB_USER_PASSWORD}';" 2>/dev/null || log "  (zitadel_user user already exists)"
        kubectl exec -n flui-system statefulset/postgres -- \
            psql -U fluicloud -c "GRANT ALL PRIVILEGES ON DATABASE zitadel TO zitadel_user;" 2>/dev/null || true
        kubectl exec -n flui-system statefulset/postgres -- \
            psql -U fluicloud -d zitadel -c "GRANT ALL ON SCHEMA public TO zitadel_user;" 2>/dev/null || true
        log "✅ Zitadel database and users created"
    fi

    # Wait for Redis
    log "→ Waiting for Redis..."
    update_health "deploying" "redis" ""
    if kubectl wait --for=condition=ready pod -l app=redis -n flui-system --timeout=${REDIS_TIMEOUT}s 2>/dev/null; then
        log "✅ Redis is ready"
    else
        error_msg="Redis failed to become ready within ${REDIS_TIMEOUT}s"
        log "❌ $error_msg"
        update_health "failed" "redis" "$error_msg"
        error "$error_msg"
    fi

    # Wait for Prometheus
    log "→ Waiting for Prometheus..."
    update_health "deploying" "prometheus" ""
    if kubectl wait --for=condition=ready pod -l app=prometheus -n flui-observability --timeout=${COMPONENT_TIMEOUT}s 2>/dev/null; then
        log "✅ Prometheus is ready"
    else
        error_msg="Prometheus failed to become ready within ${COMPONENT_TIMEOUT}s"
        log "❌ $error_msg"
        update_health "failed" "prometheus" "$error_msg"
        error "$error_msg"
    fi

    # Wait for kube-state-metrics
    log "→ Waiting for kube-state-metrics..."
    update_health "deploying" "kube-state-metrics" ""
    if kubectl wait --for=condition=ready pod -l app=kube-state-metrics -n flui-observability --timeout=${COMPONENT_TIMEOUT}s 2>/dev/null; then
        log "✅ kube-state-metrics is ready"
    else
        warn "kube-state-metrics did not become ready within ${COMPONENT_TIMEOUT}s (non-critical)"
    fi

    # Wait for Loki
    log "→ Waiting for Loki..."
    update_health "deploying" "loki" ""
    if kubectl wait --for=condition=ready pod -l app=loki -n flui-observability --timeout=${COMPONENT_TIMEOUT}s 2>/dev/null; then
        log "✅ Loki is ready"
    else
        error_msg="Loki failed to become ready within ${COMPONENT_TIMEOUT}s"
        log "❌ $error_msg"
        update_health "failed" "loki" "$error_msg"
        error "$error_msg"
    fi

    # Wait for Grafana
    log "→ Waiting for Grafana..."
    update_health "deploying" "grafana" ""
    if kubectl wait --for=condition=ready pod -l app=grafana -n flui-observability --timeout=${COMPONENT_TIMEOUT}s 2>/dev/null; then
        log "✅ Grafana is ready"
    else
        error_msg="Grafana failed to become ready within ${COMPONENT_TIMEOUT}s"
        log "❌ $error_msg"
        update_health "failed" "grafana" "$error_msg"
        error "$error_msg"
    fi

    # Wait for Flui API
    log "→ Waiting for Flui API..."
    update_health "deploying" "flui-api" ""
    if kubectl wait --for=condition=ready pod -l app=flui-api -n flui-system --timeout=${COMPONENT_TIMEOUT}s 2>/dev/null; then
        log "✅ Flui API is ready"
    else
        warn "Flui API did not become ready within ${COMPONENT_TIMEOUT}s (non-critical, image may not be available yet)"
    fi

    # Inject kubeconfig into flui-secrets so BootstrapSeeder can discover system apps
    log "→ Injecting kubeconfig into flui-secrets..."
    KUBECONFIG_B64=$(base64 -w 0 /etc/rancher/k3s/k3s.yaml)
    if kubectl patch secret flui-secrets -n flui-system \
        --type='json' \
        -p="[{\"op\":\"add\",\"path\":\"/data/KUBECONFIG_CONTENT\",\"value\":\"${KUBECONFIG_B64}\"}]" 2>/dev/null; then
        log "✅ Kubeconfig injected into flui-secrets"
        # Restart flui-api so BootstrapSeeder re-runs with KUBECONFIG available
        kubectl rollout restart deployment/flui-api -n flui-system 2>/dev/null || true
        log "✅ Flui API restarted to pick up kubeconfig"
    else
        warn "Failed to inject kubeconfig into flui-secrets (non-critical)"
    fi

    # Wait for Flui Web
    log "→ Waiting for Flui Web..."
    update_health "deploying" "flui-web" ""
    if kubectl wait --for=condition=ready pod -l app=flui-web -n flui-system --timeout=${COMPONENT_TIMEOUT}s 2>/dev/null; then
        log "✅ Flui Web is ready"
    else
        warn "Flui Web did not become ready within ${COMPONENT_TIMEOUT}s (non-critical, image may not be available yet)"
    fi

    # Wait for Zitadel API deployment (oidc mode only)
    if [ "$AUTH_MODE" = "oidc" ]; then
        log "→ Waiting for Zitadel API deployment (start-from-init runs init+setup+start)..."
        update_health "deploying" "zitadel" ""
        if kubectl rollout status deployment/zitadel -n flui-system --timeout=${COMPONENT_TIMEOUT}s 2>/dev/null; then
            log "✅ Zitadel API is ready"
            # flui-api-system PAT is written to the bootstrap PVC by Zitadel during start-from-init.
            # It will be read and injected into flui-secrets when sync-auth-domain is called.
        else
            warn "Zitadel API did not become ready within ${COMPONENT_TIMEOUT}s (non-critical)"
        fi
    fi

    log ""
    log "✅ All observability stack components are ready!"

    # Display service endpoints
    log ""
    log "=========================================="
    log "Service Endpoints"
    log "=========================================="
    log "Grafana:    http://$PRIMARY_IP:30300 (admin/$GRAFANA_PASSWORD)"
    log "Prometheus: http://$PRIMARY_IP:30090"
    log "PostgreSQL: postgres:5432 (fluicloud/$POSTGRES_PASSWORD)"
    log "Redis:      redis:6379 (password: $REDIS_PASSWORD)"
    log "Loki:       http://$PRIMARY_IP:30100"
    log "Flui API:   http://$PRIMARY_IP:30080"
    log "Flui Web:   http://$PRIMARY_IP:30880"
    if [ "$AUTH_MODE" = "oidc" ]; then
        log "Zitadel:    https://$ZITADEL_DOMAIN (admin: $ZITADEL_ADMIN_EMAIL)"
    else
        log "Auth:       Local JWT (AUTH_MODE=local)"
    fi
    log "Ingress:    http://$PRIMARY_IP:80 (Traefik)"
    log ""

    # Create marker file for observability stack success
    touch /var/log/observability-stack-ready
    log "✅ Marker file created: /var/log/observability-stack-ready"

    # Update health status to ready
    update_health "ready" "all" ""
else
    log ""
    log "=========================================="
    log "Skipping Observability Stack Deployment"
    log "=========================================="
    log "DEPLOY_OBSERVABILITY_STACK is set to '$DEPLOY_OBSERVABILITY_STACK'"
    log "This is a workload cluster - observability stack will not be deployed"
    log "K3s cluster is ready for workload deployment"
    log ""

    # Update health status to ready (K3s only)
    update_health "ready" "k3s-only" ""
fi

# Create marker file for K3s success (always created)
touch /var/log/k3s-master-ready
log "✅ Marker file created: /var/log/k3s-master-ready"

# STEP 13: Start Health Endpoint HTTP Server
# ============================================================
log ""
log "Starting health endpoint HTTP server on port 8080..."

# Create observability directory
mkdir -p /opt/observability

# Create HTTP server script with dynamic health checks
cat > /opt/observability/health-server.py <<'EOF_HEALTH_SERVER'
#!/usr/bin/env python3
import http.server
import socketserver
import urllib.request
import json
from datetime import datetime

PORT = 8080

def check_service(url, timeout=2):
    """Check if a service is responding by making an HTTP request"""
    try:
        urllib.request.urlopen(url, timeout=timeout)
        return True
    except:
        return False

class HealthHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            # Perform real-time health checks on services
            prometheus_healthy = check_service('http://localhost:30090/-/healthy')
            grafana_healthy = check_service('http://localhost:30300/api/health')
            loki_healthy = check_service('http://localhost:30100/ready')
            flui_api_healthy = check_service('http://localhost:30080/api/v1/health/ping')
            flui_web_healthy = check_service('http://localhost:30880/')

            # Determine overall status (core services only, flui-api/web are optional)
            all_ready = prometheus_healthy and grafana_healthy and loki_healthy

            # Build response
            response = {
                'status': 'ready' if all_ready else 'initializing',
                'services': {
                    'prometheus': 'ready' if prometheus_healthy else 'unavailable',
                    'grafana': 'ready' if grafana_healthy else 'unavailable',
                    'loki': 'ready' if loki_healthy else 'unavailable',
                    'flui_api': 'ready' if flui_api_healthy else 'unavailable',
                    'flui_web': 'ready' if flui_web_healthy else 'unavailable'
                },
                'timestamp': datetime.utcnow().isoformat() + 'Z'
            }

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(response).encode())
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        # Suppress HTTP server logs
        pass

with socketserver.TCPServer(("", PORT), HealthHandler) as httpd:
    print(f"Health server running on port {PORT}")
    httpd.serve_forever()
EOF_HEALTH_SERVER

chmod +x /opt/observability/health-server.py

# Create systemd service for health server
cat > /etc/systemd/system/observability-health.service <<EOF_SYSTEMD
[Unit]
Description=Observability Health HTTP Server
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p /opt/observability
ExecStart=/usr/bin/python3 /opt/observability/health-server.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF_SYSTEMD

systemctl daemon-reload
systemctl enable observability-health.service
systemctl start observability-health.service

log "✅ Health server started and configured as systemd service"
log "   Health endpoint: http://$PRIMARY_IP:8080/health"
log "   Script location: /opt/observability/health-server.py"

log ""
log "=========================================="
log "=== Master Node Initialization Complete ==="
log "=========================================="
log ""
log "🎉 K3s master node is fully operational!"
log "You can now SSH to this server and use kubectl to manage the cluster."
log ""
log "Quick commands:"
log "  kubectl get nodes"
log "  kubectl get pods --all-namespaces"
log "  kubectl cluster-info"
log ""
