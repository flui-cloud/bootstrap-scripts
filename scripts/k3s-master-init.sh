#!/bin/bash
# K3s Master Node Initialization Script
# This script installs and configures K3s as a server (master node)
set -euo pipefail

# Variables (replaced by K3sScriptService)
INSTANCE_ID="${INSTANCE_ID}"
INSTANCE_NAME="${INSTANCE_NAME}"
CLOUD_PROVIDER="${CLOUD_PROVIDER}"
CLUSTER_ID="${CLUSTER_ID}"
CLUSTER_NAME="${CLUSTER_NAME}"
K3S_TOKEN="${K3S_TOKEN}"
K3S_VERSION="${K3S_VERSION:-v1.28.4+k3s1}"

# Observability stack configuration
DEPLOY_OBSERVABILITY_STACK="${DEPLOY_OBSERVABILITY_STACK:-false}"
MANIFESTS_BASE_URL="${MANIFESTS_BASE_URL:-https://raw.githubusercontent.com/flui-cloud/bootstrap-scripts/master/manifests}"

# Multi-cluster observability configuration
OBSERVABILITY_CLUSTER_IP="${OBSERVABILITY_CLUSTER_IP:-}"
DEPLOY_MONITORING_AGENT="${DEPLOY_MONITORING_AGENT:-false}"

# Observability stack passwords
POSTGRES_PASSWORD="${POSTGRES_PASSWORD}"
REDIS_PASSWORD="${REDIS_PASSWORD}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD}"

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
export SERVER_TYPE="k3s-master"

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
fi

# Verify kubectl installation
if command -v kubectl &> /dev/null; then
    KUBECTL_VERSION=$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>&1 | head -1)
    log "✅ kubectl installed: $KUBECTL_VERSION"
else
    error "kubectl installation failed"
fi

# ============================================================
# STEP 3: Install K3s Master
# ============================================================

# Get primary IP address
PRIMARY_IP=$(hostname -I | awk '{print $1}')
log "Primary IP address: $PRIMARY_IP"

# Install K3s as server (master)
log "Installing K3s server..."
log "K3s version: $K3S_VERSION"
log "Node name: $INSTANCE_NAME"
log "Flannel backend: vxlan"
log "TLS SAN: $PRIMARY_IP"

# Capture K3s installation output
K3S_INSTALL_LOG="/var/log/k3s-install.log"
log "Downloading K3s installation script..."

curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="$K3S_VERSION" \
  sh -s - server \
  --token "$K3S_TOKEN" \
  --cluster-init \
  --disable traefik \
  --disable servicelb \
  --node-name="$INSTANCE_NAME" \
  --flannel-backend=vxlan \
  --tls-san="$PRIMARY_IP" \
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

# Count running K3s system pods
# ============================================================
# STEP 11: Deploy Observability Stack (Conditional)
# ============================================================
if [ "$DEPLOY_OBSERVABILITY_STACK" = "true" ]; then
    log ""
    log "=========================================="
    log "Deploying Observability Stack"
    log "=========================================="

    update_health "deploying" "observability-stack" ""

    # Get primary IP for NodePort access
    PRIMARY_IP=$(hostname -I | awk '{print $1}')
    MASTER_IP="$PRIMARY_IP"

    # Create manifests directory for K3s auto-deploy
    MANIFEST_DIR="/var/lib/rancher/k3s/server/manifests"
    mkdir -p "$MANIFEST_DIR"

    log "Manifest directory: $MANIFEST_DIR"
    log "Downloading manifests from: $MANIFESTS_BASE_URL/observability/"
    log "Deploying components: namespace, postgres, redis, prometheus, loki, grafana"

    # Download and apply manifests from GitHub
    for manifest in 01-namespace 02-postgres 03-redis 04-prometheus-config 05-prometheus 06-loki 07-grafana-datasources 08-grafana; do
        log "→ Downloading ${manifest}.yaml..."

        # Download manifest
        if ! curl -fsSL "$MANIFESTS_BASE_URL/observability/${manifest}.yaml" -o "/tmp/${manifest}.yaml"; then
            error "Failed to download ${manifest}.yaml from $MANIFESTS_BASE_URL/observability/"
        fi

        # Substitute environment variables (POSTGRES_PASSWORD, REDIS_PASSWORD, GRAFANA_PASSWORD, MASTER_IP, FLUI_API_ENDPOINT)
        # Note: envsubst is part of gettext-base package
        if command -v envsubst &> /dev/null; then
            envsubst < "/tmp/${manifest}.yaml" > "$MANIFEST_DIR/${manifest}.yaml"
        else
            log "⚠️  envsubst not found, using sed for variable substitution..."
            sed -e "s/\${POSTGRES_PASSWORD}/$POSTGRES_PASSWORD/g" \
                -e "s/\${REDIS_PASSWORD}/$REDIS_PASSWORD/g" \
                -e "s/\${GRAFANA_PASSWORD}/$GRAFANA_PASSWORD/g" \
                -e "s/\${MASTER_IP}/$MASTER_IP/g" \
                -e "s|\${FLUI_API_ENDPOINT}|$FLUI_API_ENDPOINT|g" \
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
    if kubectl wait --for=condition=ready pod -l app=postgres --timeout=${POSTGRES_TIMEOUT}s 2>/dev/null; then
        log "✅ PostgreSQL is ready"
    else
        error_msg="PostgreSQL failed to become ready within ${POSTGRES_TIMEOUT}s"
        log "❌ $error_msg"
        update_health "failed" "postgres" "$error_msg"
        error "$error_msg"
    fi

    # Wait for Redis
    log "→ Waiting for Redis..."
    update_health "deploying" "redis" ""
    if kubectl wait --for=condition=ready pod -l app=redis --timeout=${REDIS_TIMEOUT}s 2>/dev/null; then
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
    if kubectl wait --for=condition=ready pod -l app=prometheus --timeout=${COMPONENT_TIMEOUT}s 2>/dev/null; then
        log "✅ Prometheus is ready"
    else
        error_msg="Prometheus failed to become ready within ${COMPONENT_TIMEOUT}s"
        log "❌ $error_msg"
        update_health "failed" "prometheus" "$error_msg"
        error "$error_msg"
    fi

    # Wait for Loki
    log "→ Waiting for Loki..."
    update_health "deploying" "loki" ""
    if kubectl wait --for=condition=ready pod -l app=loki --timeout=${COMPONENT_TIMEOUT}s 2>/dev/null; then
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
    if kubectl wait --for=condition=ready pod -l app=grafana --timeout=${COMPONENT_TIMEOUT}s 2>/dev/null; then
        log "✅ Grafana is ready"
    else
        error_msg="Grafana failed to become ready within ${COMPONENT_TIMEOUT}s"
        log "❌ $error_msg"
        update_health "failed" "grafana" "$error_msg"
        error "$error_msg"
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

# STEP 12: Start Health Endpoint HTTP Server
# ============================================================
log ""
log "Starting health endpoint HTTP server on port 8080..."

# Open port 8080 in UFW firewall (if UFW is active)
if command -v ufw &> /dev/null; then
    log "Opening port 8080 in UFW firewall..."
    ufw allow 8080/tcp 2>&1 | tee -a "$LOG_FILE" || log "⚠️  Failed to add UFW rule (may not be enabled)"
    log "✅ Port 8080 opened in firewall"
else
    log "⚠️  UFW not found, skipping firewall configuration"
fi

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

            # Determine overall status
            all_ready = prometheus_healthy and grafana_healthy and loki_healthy

            # Build response
            response = {
                'status': 'ready' if all_ready else 'initializing',
                'services': {
                    'prometheus': 'ready' if prometheus_healthy else 'unavailable',
                    'grafana': 'ready' if grafana_healthy else 'unavailable',
                    'loki': 'ready' if loki_healthy else 'unavailable'
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
