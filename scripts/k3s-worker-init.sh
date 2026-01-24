#!/bin/bash
# K3s Worker Node Initialization Script
# This script installs and configures K3s as an agent (worker node)
set -euo pipefail

# Variables (replaced by K3sScriptService)
INSTANCE_ID="${INSTANCE_ID}"
INSTANCE_NAME="${INSTANCE_NAME}"
CLOUD_PROVIDER="${CLOUD_PROVIDER}"
CLUSTER_ID="${CLUSTER_ID}"
CLUSTER_NAME="${CLUSTER_NAME}"
K3S_TOKEN="${K3S_TOKEN}"
K3S_URL="${K3S_URL}"
K3S_VERSION="${K3S_VERSION:-v1.28.4+k3s1}"
MASTER_IP="${MASTER_IP}"

# Multi-cluster observability configuration
OBSERVABILITY_CLUSTER_IP="${OBSERVABILITY_CLUSTER_IP:-}"

LOG_FILE="/var/log/k3s-worker-init.log"

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

log "=== K3s Worker Node Initialization ==="
log "Cluster: $CLUSTER_NAME (ID: $CLUSTER_ID)"
log "Instance: $INSTANCE_NAME (ID: $INSTANCE_ID)"
log "Provider: $CLOUD_PROVIDER"
log "Master: $MASTER_IP"
log "K3s Version: $K3S_VERSION"
if [ -n "$OBSERVABILITY_CLUSTER_IP" ]; then
    log "Observability Cluster IP: $OBSERVABILITY_CLUSTER_IP (logs will be forwarded)"
fi

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
if [ -n "$OBSERVABILITY_CLUSTER_IP" ]; then
    test_observability_connectivity "$OBSERVABILITY_CLUSTER_IP"
fi

# Export monitoring endpoints for log forwarding
# For workload clusters, send logs to remote observability cluster
if [ -n "$OBSERVABILITY_CLUSTER_IP" ]; then
    # Workload cluster - send logs to remote observability cluster
    export LOKI_ENDPOINT="${OBSERVABILITY_CLUSTER_IP}:30100"
    log "Configuring workload cluster to send logs to observability cluster at ${OBSERVABILITY_CLUSTER_IP}:30100"
else
    # No observability cluster configured - use localhost (logs will be lost if no local Loki)
    export LOKI_ENDPOINT="localhost:30100"
    warn "No observability cluster configured - logs will be sent to localhost:30100"
fi

export PROMETHEUS_ENDPOINT="localhost:30090"
export SERVER_TYPE="k3s-worker"

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

# Verify Vector is configured correctly for remote Loki (if observability cluster is configured)
if [ -n "$OBSERVABILITY_CLUSTER_IP" ]; then
    log "Verifying Vector configuration for remote Loki..."
    if [ -f /etc/vector/vector.toml ]; then
        if grep -q "$OBSERVABILITY_CLUSTER_IP" /etc/vector/vector.toml; then
            log "✅ Vector configured to send logs to observability cluster at $OBSERVABILITY_CLUSTER_IP"
        else
            warn "Vector configuration may not have been updated with observability cluster IP"
        fi
    else
        warn "Vector configuration file not found at /etc/vector/vector.toml"
    fi
fi

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
# STEP 3: Install K3s Worker
# ============================================================

# Get primary IP address
PRIMARY_IP=$(hostname -I | awk '{print $1}')
log "Primary IP address: $PRIMARY_IP"

# Wait for master to be reachable
log "Waiting for master at $MASTER_IP:6443 to be reachable..."
MAX_WAIT=300
ELAPSED=0
until curl -k -s "https://$MASTER_IP:6443" > /dev/null 2>&1; do
  if [ $ELAPSED -ge $MAX_WAIT ]; then
    error "Master at $MASTER_IP:6443 did not become reachable within ${MAX_WAIT} seconds"
  fi
  log "Master not yet reachable, waiting... (${ELAPSED}s elapsed)"
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

log "Master is reachable at $MASTER_IP:6443"

# Install K3s as agent (worker)
log "Installing K3s agent..."
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="$K3S_VERSION" \
  sh -s - agent \
  --server "$K3S_URL" \
  --token "$K3S_TOKEN" \
  --node-name="$INSTANCE_NAME" || error "Failed to install K3s agent"

# Wait for K3s agent service to be active
log "Waiting for K3s agent service to be active..."
MAX_WAIT=120
ELAPSED=0
until systemctl is-active --quiet k3s-agent; do
  if [ $ELAPSED -ge $MAX_WAIT ]; then
    error "K3s agent service did not become active within ${MAX_WAIT} seconds"
  fi
  log "K3s agent service not yet active, waiting..."
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

log "✅ K3s worker node is ready!"
log "Worker node IP: $PRIMARY_IP"
log "Joined to cluster at: $K3S_URL"

# ============================================================
# STEP 4: Configure kubectl for cluster access
# ============================================================
log "Configuring kubectl to access the cluster..."

# Create kubeconfig directory
mkdir -p /root/.kube

# Create kubeconfig that points to the master node
cat > /root/.kube/config <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://${MASTER_IP}:6443
    insecure-skip-tls-verify: true
  name: k3s
contexts:
- context:
    cluster: k3s
    user: k3s
  name: k3s
current-context: k3s
users:
- name: k3s
  user:
    token: ${K3S_TOKEN}
EOF

chmod 600 /root/.kube/config

# Export KUBECONFIG for this shell session (CRITICAL: must be set before kubectl commands)
export KUBECONFIG=/root/.kube/config

# Set KUBECONFIG environment variable in bash profile for future sessions
if ! grep -q "KUBECONFIG" /root/.bashrc; then
    echo 'export KUBECONFIG=/root/.kube/config' >> /root/.bashrc
    log "✅ Added KUBECONFIG to /root/.bashrc"
fi

log "✅ kubectl configured to access cluster at ${MASTER_IP}:6443"

# Test kubectl connection
log "Testing kubectl connection..."
if kubectl get nodes &>/dev/null; then
    log "✅ kubectl successfully connected to cluster"
    kubectl get nodes | tee -a "$LOG_FILE"
else
    warn "kubectl connection test failed - you may need to manually configure kubeconfig"
fi

# Create marker file for success
touch /var/log/k3s-worker-ready

log "=== Worker Node Initialization Complete ==="
