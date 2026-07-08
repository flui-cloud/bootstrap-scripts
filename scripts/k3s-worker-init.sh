#!/bin/bash
# K3s Worker Node Initialization Script
# This script installs and configures K3s as an agent (worker node)
set -euo pipefail

# Variables (replaced by K3sScriptService)
INSTANCE_ID="${INSTANCE_ID}"
SERVER_ID="${SERVER_ID:-}"
INSTANCE_NAME="${INSTANCE_NAME}"
CLOUD_PROVIDER="${CLOUD_PROVIDER}"
CLUSTER_ID="${CLUSTER_ID}"
CLUSTER_NAME="${CLUSTER_NAME}"
K3S_TOKEN="${K3S_TOKEN}"
K3S_URL="${K3S_URL}"
K3S_VERSION="${K3S_VERSION:-v1.35.4+k3s1}"
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

# Test connectivity to control cluster (for workload clusters)
test_control_cluster_connectivity() {
    local OBS_CLUSTER_IP="$1"

    if [ -z "$OBS_CLUSTER_IP" ]; then
        return 0  # No control cluster configured, skip test
    fi

    log "Testing connectivity to control cluster at $OBS_CLUSTER_IP..."

    # Test 1: Ping (may fail if ICMP blocked)
    if ping -c 2 -W 3 "$OBS_CLUSTER_IP" &>/dev/null; then
        log "  ✓ Control cluster host is reachable (ping)"
    else
        warn "  ⚠ Control cluster not responding to ping (may be blocked)"
    fi

    # Test 2: TCP connection to Loki NodePort via VNet (30100 not in public firewall)
    log "  Testing Loki port 30100 (VNet private)..."
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$OBS_CLUSTER_IP/30100" 2>/dev/null; then
        log "  ✓ Loki port 30100 reachable via VNet"
    else
        warn "  ✗ Loki port 30100 NOT reachable - check VNet connectivity"
    fi

    # Measure network latency
    local START_TIME=$(date +%s%N 2>/dev/null || echo "0")
    if timeout 3 bash -c "cat < /dev/null > /dev/tcp/$OBS_CLUSTER_IP/30100" 2>/dev/null; then
        local END_TIME=$(date +%s%N 2>/dev/null || echo "$START_TIME")
        if [ "$START_TIME" != "0" ] && [ "$END_TIME" != "$START_TIME" ]; then
            local LATENCY_MS=$(( (END_TIME - START_TIME) / 1000000 ))
            log "  ℹ Network latency to control cluster: ${LATENCY_MS}ms"
        fi
    fi

    log "Connectivity test to control cluster completed"
}

log "=== K3s Worker Node Initialization ==="
log "Cluster: $CLUSTER_NAME (ID: $CLUSTER_ID)"
log "Instance: $INSTANCE_NAME (ID: $INSTANCE_ID)"
log "Provider: $CLOUD_PROVIDER"
log "Master: $MASTER_IP"
log "K3s Version: $K3S_VERSION"
if [ -n "$OBSERVABILITY_CLUSTER_IP" ]; then
    log "Control Cluster IP: $OBSERVABILITY_CLUSTER_IP (logs will be forwarded)"
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

if curl -fsSL "$SCRIPTS_BASE_URL/check-control-cluster.sh" -o /usr/local/bin/check-control-cluster.sh; then
    chmod +x /usr/local/bin/check-control-cluster.sh
    log "✓ Installed check-control-cluster.sh to /usr/local/bin/"
else
    warn "Failed to download check-control-cluster.sh - diagnostic tools may be limited"
fi

# Test connectivity to control cluster BEFORE configuring monitoring
if [ -n "$OBSERVABILITY_CLUSTER_IP" ]; then
    test_control_cluster_connectivity "$OBSERVABILITY_CLUSTER_IP"
fi

# Export monitoring endpoints for log forwarding
# For workload clusters, send logs to remote control cluster
if [ -n "$OBSERVABILITY_CLUSTER_IP" ]; then
    export LOKI_ENDPOINT="${OBSERVABILITY_CLUSTER_IP}:30100"
    log "Loki endpoint (VNet): ${LOKI_ENDPOINT}"
else
    export LOKI_ENDPOINT="localhost:3100"
    warn "No control cluster configured - logs will be sent to localhost (no Loki available)"
fi

export PROMETHEUS_ENDPOINT="localhost:9090"
# Validate SERVER_ID
if [[ -z "$SERVER_ID" ]]; then
    error "SERVER_ID not provided - this should be the database node ID from infrastructure_cluster_nodes table"
fi
log "Using database node ID as SERVER_ID: $SERVER_ID"
export SERVER_TYPE="k3s-worker"
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

# Verify Vector is configured correctly for remote Loki (if control cluster is configured)
if [ -n "$OBSERVABILITY_CLUSTER_IP" ]; then
    log "Verifying Vector configuration for remote Loki..."
    if [ -f /etc/vector/vector.toml ]; then
        if grep -q "$OBSERVABILITY_CLUSTER_IP" /etc/vector/vector.toml; then
            log "✅ Vector configured to send logs to control cluster at $OBSERVABILITY_CLUSTER_IP"
        else
            warn "Vector configuration may not have been updated with control cluster IP"
        fi
    else
        warn "Vector configuration file not found at /etc/vector/vector.toml"
    fi
fi

# ============================================================
# STEP 2: Install kubectl (non-fatal — workers don't need it to run the K3s agent)
# ============================================================
install_kubectl_via_curl() {
    local v arch
    case "$(uname -m)" in aarch64 | arm64) arch=arm64 ;; *) arch=amd64 ;; esac
    v=$(curl -fsSL https://dl.k8s.io/release/stable.txt 2>/dev/null) || return 1
    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${v}/bin/linux/${arch}/kubectl" || return 1
    chmod +x /usr/local/bin/kubectl
}

log "Installing kubectl for cluster interaction..."
export PATH="$PATH:/snap/bin"
hash -r 2>/dev/null || true

if install_kubectl_via_curl; then
    log "✅ kubectl installed at /usr/local/bin/kubectl"
elif command -v snap &>/dev/null && snap install kubectl --classic >>"$LOG_FILE" 2>&1; then
    log "✅ kubectl installed via snap"
else
    warn "kubectl installation failed — worker will run without kubectl. K3s agent install will continue."
fi

# Node-local path for the flui-local StorageClass (dedicated workloads pin here).
mkdir -p /var/lib/flui/local

# ============================================================
# STEP 2.5: Configure Flui shared storage (NFS client + fscache)
# ============================================================
# When FLUI_SHARED_STORAGE_ENABLED=true, install nfs-common + cachefilesd,
# create the local cache, and mount the master's NFS export at the conventional
# path. local-path-provisioner on the master is already pointing at this path,
# so PVCs created by apps land on the shared NFS share visible from this worker.
# See APPLICATION_SCALING_AND_RESOURCE_MANAGEMENT.md §14.

if [ "${FLUI_SHARED_STORAGE_ENABLED:-false}" = "true" ]; then
    log "=========================================="
    log "Flui shared storage: configuring worker"
    log "=========================================="

    SHARED_STORAGE_PATH="/var/lib/flui/storage"
    FSCACHE_PATH="/var/cache/fscache"
    NFS_MASTER_IP="${FLUI_SHARED_STORAGE_MASTER_IP:-${MASTER_IP}}"
    NFS_OPTS="vers=4.2,bg,fsc,async,hard,_netdev"

    if [ -z "$NFS_MASTER_IP" ]; then
        log "❌ FLUI_SHARED_STORAGE_MASTER_IP and MASTER_IP both empty — cannot mount NFS"
        error "Missing master IP for NFS mount"
    fi

    log "Installing nfs-common + cachefilesd..."
    DEBIAN_FRONTEND=noninteractive apt-get install -yq \
        nfs-common cachefilesd 2>&1 | tail -5 | tee -a "$LOG_FILE" \
        || error "Failed to install nfs-common / cachefilesd"

    # Configure cachefilesd
    mkdir -p "$FSCACHE_PATH"
    sed -i 's|^#\?RUN=.*|RUN=yes|' /etc/default/cachefilesd 2>/dev/null || true
    if ! grep -q "^dir $FSCACHE_PATH" /etc/cachefilesd.conf 2>/dev/null; then
        sed -i 's|^dir .*|dir '"$FSCACHE_PATH"'|' /etc/cachefilesd.conf 2>/dev/null \
            || echo "dir $FSCACHE_PATH" >> /etc/cachefilesd.conf
    fi
    systemctl enable --now cachefilesd 2>&1 | tee -a "$LOG_FILE" \
        || log "⚠️  cachefilesd failed to start (non-fatal — NFS will still work without cache)"

    mkdir -p "$SHARED_STORAGE_PATH"

    # Add fstab entry (idempotent)
    sed -i "\|${SHARED_STORAGE_PATH}|d" /etc/fstab
    echo "${NFS_MASTER_IP}:${SHARED_STORAGE_PATH} ${SHARED_STORAGE_PATH} nfs4 ${NFS_OPTS} 0 0" >> /etc/fstab
    log "Added fstab entry: ${NFS_MASTER_IP}:${SHARED_STORAGE_PATH}"

    # Wait for master NFS to be reachable then mount
    log "Waiting for master NFS at ${NFS_MASTER_IP}:2049 to be reachable..."
    MAX_NFS_WAIT=180
    NFS_ELAPSED=0
    until timeout 3 bash -c ">/dev/tcp/${NFS_MASTER_IP}/2049" 2>/dev/null; do
        if [ $NFS_ELAPSED -ge $MAX_NFS_WAIT ]; then
            log "⚠️  Master NFS not reachable after ${MAX_NFS_WAIT}s — continuing anyway, mount will be retried by fstab on boot"
            break
        fi
        sleep 5
        NFS_ELAPSED=$((NFS_ELAPSED + 5))
    done

    if mount "$SHARED_STORAGE_PATH" 2>&1 | tee -a "$LOG_FILE"; then
        log "✅ NFS mount succeeded at $SHARED_STORAGE_PATH"
        df -h "$SHARED_STORAGE_PATH" | tee -a "$LOG_FILE" || true
    else
        log "⚠️  NFS mount failed — will retry on boot via fstab. K3s agent will start anyway"
        log "   Manual debug: mount -t nfs4 -o $NFS_OPTS ${NFS_MASTER_IP}:${SHARED_STORAGE_PATH} ${SHARED_STORAGE_PATH}"
    fi
else
    log "Flui shared storage: disabled (FLUI_SHARED_STORAGE_ENABLED=false)"
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
  K3S_NODE_IP_FLAGS="--node-ip=$PRIVATE_IP --flannel-iface=$PRIVATE_IFACE"
  log "K3s agent will bind to private IP $PRIVATE_IP via $PRIVATE_IFACE"
fi

# Pin DNS resolvers (host + kubelet) — same rationale as the master's
# STEP 2.7: hosting-provider recursors cache stale/negative answers for the
# full TTL, breaking ACME self-checks and fresh-record lookups on pods
# scheduled here. Opt out with PIN_HOST_DNS=false.
PIN_HOST_DNS="${PIN_HOST_DNS:-true}"
HOST_DNS_SERVERS="${HOST_DNS_SERVERS:-1.1.1.1 8.8.8.8}"
K3S_RESOLV_CONF_FLAG=""
if [ "$PIN_HOST_DNS" = "true" ]; then
    FIRST_DNS=$(echo "$HOST_DNS_SERVERS" | awk '{print $1}')
    if timeout 3 bash -c "</dev/tcp/$FIRST_DNS/53" 2>/dev/null; then
        mkdir -p /etc/rancher
        : > /etc/rancher/flui-resolv.conf
        for ns in $HOST_DNS_SERVERS; do
            echo "nameserver $ns" >> /etc/rancher/flui-resolv.conf
        done
        K3S_RESOLV_CONF_FLAG="--resolv-conf=/etc/rancher/flui-resolv.conf"

        if command -v resolvectl &>/dev/null && systemctl is-active -q systemd-resolved; then
            mkdir -p /etc/systemd/resolved.conf.d
            {
                echo "[Resolve]"
                echo "DNS=$HOST_DNS_SERVERS"
                echo "FallbackDNS=9.9.9.9"
                echo "Domains=~."
            } > /etc/systemd/resolved.conf.d/99-flui-dns.conf
            systemctl restart systemd-resolved
        fi
        log "✅ DNS resolvers pinned to $HOST_DNS_SERVERS (host drop-in + kubelet resolv-conf)"
    else
        warn "Public DNS $FIRST_DNS unreachable on port 53 — keeping the host's existing resolvers"
    fi
else
    log "DNS resolver pinning skipped (PIN_HOST_DNS=false)"
fi

# Install K3s as agent (worker)
log "Installing K3s agent..."
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="$K3S_VERSION" \
  sh -s - agent \
  --server "$K3S_URL" \
  --token "$K3S_TOKEN" \
  --node-name="$INSTANCE_NAME" \
  $K3S_NODE_IP_FLAGS \
  $K3S_RESOLV_CONF_FLAG || error "Failed to install K3s agent"

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
