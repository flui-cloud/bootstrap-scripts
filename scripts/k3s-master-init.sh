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
K3S_VERSION="${K3S_VERSION:-v1.35.4+k3s1}"

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

log "=== K3s Master Node Initialization ==="
log "Cluster: $CLUSTER_NAME (ID: $CLUSTER_ID)"
log "Instance: $INSTANCE_NAME (ID: $INSTANCE_ID)"
log "Provider: $CLOUD_PROVIDER"
log "K3s Version: $K3S_VERSION"
log "Deploy Observability Stack: $DEPLOY_OBSERVABILITY_STACK"
if [ -n "$OBSERVABILITY_CLUSTER_IP" ]; then
    log "Control Cluster IP: $OBSERVABILITY_CLUSTER_IP (logs will be forwarded)"
fi

update_health "initializing" "k3s" ""

# ============================================================
# STEP 1: Run base Flui.cloud initialization
# This installs Podman, monitoring, logging, and SSH CA
# ============================================================
log "Running Flui.cloud base initialization..."

SCRIPTS_BASE_URL="${SCRIPTS_BASE_URL:-https://raw.githubusercontent.com/flui-cloud/bootstrap-scripts/master/scripts}"
log "Downloading flui-init.sh from $SCRIPTS_BASE_URL..."

if ! curl -fsSL "$SCRIPTS_BASE_URL/flui-init.sh" -o /tmp/flui-init.sh; then
    error "Failed to download flui-init.sh from $SCRIPTS_BASE_URL"
fi

chmod +x /tmp/flui-init.sh

log "Downloading monitoring modules..."
mkdir -p /tmp/flui-modules
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

if [ "$DEPLOY_OBSERVABILITY_STACK" = "false" ] && [ -n "$OBSERVABILITY_CLUSTER_IP" ]; then
    test_control_cluster_connectivity "$OBSERVABILITY_CLUSTER_IP"
fi

if [ "$DEPLOY_OBSERVABILITY_STACK" = "false" ] && [ -n "$OBSERVABILITY_CLUSTER_IP" ]; then
    export LOKI_ENDPOINT="${OBSERVABILITY_CLUSTER_IP}:30100"
    log "Loki endpoint (VNet): ${LOKI_ENDPOINT}"
else
    # OBS cluster: Vector runs as host systemd service (not in K8s), so it cannot
    # resolve the cluster-internal DNS. Use the local NodePort instead — it is
    # exposed on every node and always reachable from localhost.
    export LOKI_ENDPOINT="localhost:30100"
fi

export PROMETHEUS_ENDPOINT="vmsingle.flui-control.svc.cluster.local:8428"
export FLUI_API_ENDPOINT="${FLUI_API_ENDPOINT:-http://localhost:3000}"
if [[ -z "$SERVER_ID" ]]; then
    error "SERVER_ID not provided - this should be the database node ID from infrastructure_cluster_nodes table"
fi
log "Using database node ID as SERVER_ID: $SERVER_ID"
export SERVER_TYPE="k3s-master"
export SERVER_ID

# Export CA keys for SSH certificate authentication (if provided)
if [[ -n "${FLUI_CA_PUBLIC_KEY:-}" ]]; then
    log "Exporting SSH CA public key for flui-init.sh..."
    export FLUI_CA_PUBLIC_KEY
    export SSH_CA_PUBLIC_KEY="${FLUI_CA_PUBLIC_KEY}"
else
    warn "FLUI_CA_PUBLIC_KEY not set - SSH certificate authentication will be skipped"
fi

# Pre-compute base64 of CA private key so it can be safely embedded in YAML
# (raw PEM is multiline and would break YAML if substituted directly)
if [[ -n "${SSH_CA_PRIVATE_KEY:-}" ]]; then
    export SSH_CA_PRIVATE_KEY_B64
    SSH_CA_PRIVATE_KEY_B64=$(printf '%s' "${SSH_CA_PRIVATE_KEY}" | base64 -w 0)
else
    export SSH_CA_PRIVATE_KEY_B64=""
    warn "SSH_CA_PRIVATE_KEY not set — terminal SSH access will not work"
fi

if ! /tmp/flui-init.sh; then
    error "Flui.cloud base initialization failed"
fi
rm -f /tmp/flui-init.sh

log "Flui.cloud base initialization completed successfully"

# ============================================================
# STEP 2: Install kubectl
# ============================================================
case "$(uname -m)" in aarch64 | arm64) KUBE_ARCH=arm64 ;; *) KUBE_ARCH=amd64 ;; esac
log "Installing kubectl for cluster interaction (arch ${KUBE_ARCH})..."

if ! command -v snap &> /dev/null; then
    log "snap not available, installing kubectl via curl..."
    KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${KUBE_ARCH}/kubectl"
    chmod +x kubectl
    mv kubectl /usr/local/bin/kubectl
else
    log "Installing kubectl via snap..."
    snap install kubectl --classic 2>&1 | tee -a "$LOG_FILE" || {
        warn "snap install failed, trying curl method..."
        KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
        curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${KUBE_ARCH}/kubectl"
        chmod +x kubectl
        mv kubectl /usr/local/bin/kubectl
    }

    log "Waiting for snap to configure kubectl..."
    sleep 3

    RETRY_COUNT=0
    MAX_RETRIES=10
    until command -v kubectl &> /dev/null; do
        if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
            warn "kubectl not found in PATH after ${MAX_RETRIES} retries, trying curl method..."
            KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
            curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${KUBE_ARCH}/kubectl"
            chmod +x kubectl
            mv kubectl /usr/local/bin/kubectl
            break
        fi
        log "Waiting for kubectl to be available in PATH (attempt $((RETRY_COUNT + 1))/${MAX_RETRIES})..."
        sleep 1
        RETRY_COUNT=$((RETRY_COUNT + 1))
    done
fi

log "Verifying kubectl installation..."
if command -v kubectl &> /dev/null; then
    log "kubectl found in PATH: $(which kubectl)"

    set +e  # kubectl version may exit non-zero in some builds
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

# Node-local path for the flui-local StorageClass (dedicated workloads).
mkdir -p /var/lib/flui/local

# ============================================================
# STEP 2.5: Prepare Flui shared storage Volume (pre-k3s)
# ============================================================
# When FLUI_SHARED_STORAGE_ENABLED=true, the master has an attached block
# storage Volume that will host the NFS export. Format + mount happens here
# (before k3s starts) so the path /var/lib/flui/storage exists when
# local-path-provisioner is later reconfigured to point at it.
# See APPLICATION_SCALING_AND_RESOURCE_MANAGEMENT.md §14.

if [ "${FLUI_SHARED_STORAGE_ENABLED:-false}" = "true" ]; then
    log "=========================================="
    log "Flui shared storage: preparing master Volume"
    log "=========================================="

    SHARED_STORAGE_PATH="/var/lib/flui/storage"
    SHARED_STORAGE_FS_LABEL="flui-data"
    SHARED_STORAGE_DEVICE="${FLUI_SHARED_STORAGE_DEVICE:-}"

    wait_for_device() {
        local timeout=120
        local elapsed=0
        while [ $elapsed -lt $timeout ]; do
            for stable in /dev/disk/by-id/scsi-0HC_Volume_* /dev/disk/by-id/scsi-0SCW_*; do
                if [ -b "$stable" ]; then
                    SHARED_STORAGE_DEVICE="$(readlink -f "$stable")"
                    log "Found by-id device: $stable → $SHARED_STORAGE_DEVICE"
                    return 0
                fi
            done
            for candidate in /dev/sdb /dev/vdb /dev/sdc /dev/vdc; do
                if [ -b "$candidate" ] && ! lsblk -no MOUNTPOINT "$candidate" 2>/dev/null | grep -q "^/$"; then
                    SHARED_STORAGE_DEVICE="$candidate"
                    log "Found candidate device: $SHARED_STORAGE_DEVICE"
                    return 0
                fi
            done
            sleep 3
            elapsed=$((elapsed + 3))
            log "Waiting for shared-storage device... (${elapsed}s/${timeout}s)"
        done
        return 1
    }

    if [ -z "$SHARED_STORAGE_DEVICE" ] || [ ! -b "$SHARED_STORAGE_DEVICE" ]; then
        log "Polling for shared-storage device (up to 120s)..."
        if ! wait_for_device; then
            log "❌ No suitable block device found after 120s"
            lsblk | tee -a "$LOG_FILE" || true
            error "Flui shared storage requested but no Volume attached"
        fi
    fi

    log "Using device: $SHARED_STORAGE_DEVICE"

    # Format only if not already formatted (idempotent on reboot/recreate)
    if ! blkid "$SHARED_STORAGE_DEVICE" >/dev/null 2>&1; then
        log "Formatting $SHARED_STORAGE_DEVICE as ext4 (label=$SHARED_STORAGE_FS_LABEL)"
        mkfs.ext4 -F -L "$SHARED_STORAGE_FS_LABEL" "$SHARED_STORAGE_DEVICE" \
            2>&1 | tee -a "$LOG_FILE" || error "mkfs.ext4 failed"
    else
        EXISTING_FS=$(blkid -o value -s TYPE "$SHARED_STORAGE_DEVICE")
        log "Device already formatted as $EXISTING_FS — skipping mkfs"
    fi

    mkdir -p "$SHARED_STORAGE_PATH"

    # Mount permanently via fstab (use UUID for stability across device renames)
    UUID=$(blkid -o value -s UUID "$SHARED_STORAGE_DEVICE")
    if ! grep -q "$UUID" /etc/fstab; then
        echo "UUID=$UUID $SHARED_STORAGE_PATH ext4 defaults,nofail 0 2" >> /etc/fstab
        log "Added fstab entry: UUID=$UUID -> $SHARED_STORAGE_PATH"
    fi

    if ! mountpoint -q "$SHARED_STORAGE_PATH"; then
        mount "$SHARED_STORAGE_PATH" 2>&1 | tee -a "$LOG_FILE" \
            || error "Failed to mount $SHARED_STORAGE_DEVICE on $SHARED_STORAGE_PATH"
    fi

    log "✅ Flui shared storage mounted at $SHARED_STORAGE_PATH"
    df -h "$SHARED_STORAGE_PATH" | tee -a "$LOG_FILE"
else
    log "Flui shared storage: disabled (FLUI_SHARED_STORAGE_ENABLED=false)"
fi

# ============================================================
# STEP 2.7: Pin DNS resolvers (host + kubelet/CoreDNS)
# ============================================================
# Hosting-provider recursors (the typical default on BYOS hosts) cache
# answers for the full TTL — including NXDOMAIN for the zone's SOA minimum
# (1h on Hetzner DNS) — which stalls ACME self-checks and serves stale IPs
# right after a DNS record is created or changed. Pin public resolvers for
# the host (systemd-resolved drop-in; Domains=~. wins over per-link
# DHCP/netplan DNS without touching network config) and for the cluster
# (dedicated resolv.conf handed to the kubelet, so CoreDNS forwards to the
# same servers). Opt out with PIN_HOST_DNS=false (e.g. corporate networks
# where public DNS egress is blocked — the port-53 probe below also skips
# pinning automatically in that case).
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

# ============================================================
# STEP 3: Install K3s Master
# ============================================================

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

log "Installing K3s server..."
log "K3s version: $K3S_VERSION"
log "Node name: $INSTANCE_NAME"
log "Flannel backend: vxlan"
log "TLS SAN: $PRIMARY_IP${PRIVATE_IP:+,$PRIVATE_IP}"

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
  $K3S_RESOLV_CONF_FLAG \
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

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml  # must be set before any kubectl call
mkdir -p /root/.kube
ln -sf /etc/rancher/k3s/k3s.yaml /root/.kube/config

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

  if [ $((ELAPSED % 15)) -eq 0 ]; then
    NODE_STATUS=$(kubectl get nodes | grep "$INSTANCE_NAME" | awk '{print $2}')
    log "⏳ Node status: $NODE_STATUS (elapsed: ${ELAPSED}s)"
  fi

  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

log "✅ K3s master node is Ready! (took ${ELAPSED}s)"

# ============================================================
# STEP 6.5: Configure NFS server + local-path-provisioner repoint
# ============================================================
# When Flui shared storage is enabled, install nfs-kernel-server, export the
# Volume mountpoint over NFSv4, and patch the local-path-provisioner ConfigMap
# so all PVCs land on the shared NFS share (visible from any worker that mounts
# it). See APPLICATION_SCALING_AND_RESOURCE_MANAGEMENT.md §14.

if [ "${FLUI_SHARED_STORAGE_ENABLED:-false}" = "true" ]; then
    log "=========================================="
    log "Configuring NFS server + local-path-provisioner"
    log "=========================================="

    SHARED_STORAGE_PATH="/var/lib/flui/storage"
    NFS_EXPORT_OPTS="rw,async,no_subtree_check,no_root_squash"

    log "Installing nfs-kernel-server..."
    DEBIAN_FRONTEND=noninteractive apt-get install -yq nfs-kernel-server \
        2>&1 | tail -5 | tee -a "$LOG_FILE" \
        || error "Failed to install nfs-kernel-server"

    # Export only to private network (or local subnets) for security.
    # Default: trust all, can be tightened by Flui via env var.
    NFS_ALLOWED_NETWORKS="${FLUI_NFS_ALLOWED_NETWORKS:-*}"

    # Idempotent: replace existing flui export line if present
    sed -i '\|^/var/lib/flui/storage |d' /etc/exports
    echo "/var/lib/flui/storage ${NFS_ALLOWED_NETWORKS}(${NFS_EXPORT_OPTS})" >> /etc/exports
    log "NFS export: /var/lib/flui/storage ${NFS_ALLOWED_NETWORKS}(${NFS_EXPORT_OPTS})"

    systemctl enable --now nfs-server 2>&1 | tee -a "$LOG_FILE" || true
    exportfs -rav 2>&1 | tee -a "$LOG_FILE" \
        || error "exportfs failed"

    # Verify NFS server is listening
    if ! systemctl is-active --quiet nfs-server; then
        log "❌ nfs-server is not active"
        systemctl status nfs-server --no-pager | tee -a "$LOG_FILE"
        error "NFS server failed to start"
    fi
    log "✅ NFS server active and exporting $SHARED_STORAGE_PATH"

    # Patch local-path-provisioner ConfigMap to point at the shared mount.
    # The default config uses /var/lib/rancher/k3s/storage on each node; we
    # repoint to /var/lib/flui/storage so all PVCs land on the NFS share.
    log "Patching local-path-provisioner ConfigMap..."
    LOCAL_PATH_NS="kube-system"
    cat <<'PATCH_YAML' > /tmp/local-path-config-patch.json
{
  "data": {
    "config.json": "{\n  \"nodePathMap\": [\n    {\n      \"node\": \"DEFAULT_PATH_FOR_NON_LISTED_NODES\",\n      \"paths\": [\"/var/lib/flui/storage\"]\n    }\n  ]\n}"
  }
}
PATCH_YAML

    # Wait for local-path-provisioner to exist (k3s deploys it asynchronously)
    PATCH_ELAPSED=0
    until kubectl -n "$LOCAL_PATH_NS" get configmap local-path-config >/dev/null 2>&1; do
        if [ $PATCH_ELAPSED -ge 60 ]; then
            log "⚠️  local-path-config ConfigMap not found within 60s — skipping patch"
            log "   (k3s may install it later, manual patch required)"
            break
        fi
        sleep 3
        PATCH_ELAPSED=$((PATCH_ELAPSED + 3))
    done

    if kubectl -n "$LOCAL_PATH_NS" get configmap local-path-config >/dev/null 2>&1; then
        kubectl -n "$LOCAL_PATH_NS" patch configmap local-path-config \
            --type merge \
            --patch-file /tmp/local-path-config-patch.json \
            2>&1 | tee -a "$LOG_FILE" \
            || log "⚠️  ConfigMap patch failed (non-fatal, manual patch may be needed)"

        # Restart provisioner pod to pick up new path
        kubectl -n "$LOCAL_PATH_NS" rollout restart deployment local-path-provisioner \
            >/dev/null 2>&1 || true
        log "✅ local-path-provisioner repointed to $SHARED_STORAGE_PATH"
    fi
fi

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

log "Waiting for system pods to be scheduled..."
sleep 10

log "Pods in kube-system namespace:"
kubectl get pods -n kube-system -o wide | tee -a "$LOG_FILE"

log ""
log "Detailed pod status:"
SYSTEM_PODS=$(kubectl get pods -n kube-system --no-headers -o custom-columns=":metadata.name")
for POD in $SYSTEM_PODS; do
    # Diagnostic only — a pod may vanish between listing and querying, so never abort here.
    STATUS=$(kubectl get pod "$POD" -n kube-system -o jsonpath='{.status.phase}' 2>/dev/null) || continue
    READY=$(kubectl get pod "$POD" -n kube-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)

    if [ "$STATUS" = "Running" ] && [ "$READY" = "True" ]; then
        log "  ✅ $POD: Running and Ready"
    elif [ "$STATUS" = "Running" ]; then
        log "  ⏳ $POD: Running but not Ready yet"
    else
        log "  ⚠️  $POD: Status=$STATUS Ready=$READY"
    fi
done

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

log ""
log "All namespaces:"
kubectl get namespaces | tee -a "$LOG_FILE"

log ""
log "All pods (all namespaces):"
kubectl get pods --all-namespaces -o wide | tee -a "$LOG_FILE"

log ""
log "Checking for pods with issues..."
PROBLEM_PODS=$(kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null)
if [ -n "$PROBLEM_PODS" ]; then
    log "⚠️  Pods with issues found:"
    echo "$PROBLEM_PODS" | tee -a "$LOG_FILE"

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

log "1. K3s API Server health:"
if kubectl get --raw /healthz &>/dev/null; then
    log "   ✅ API server is healthy"
else
    log "   ❌ API server health check failed"
fi

log ""
log "2. Component status:"
kubectl get cs 2>/dev/null | tee -a "$LOG_FILE" || log "   ⚠️  Component status not available"

log ""
log "3. Node conditions:"
kubectl describe node "$INSTANCE_NAME" | grep -A 10 "Conditions:" | tee -a "$LOG_FILE"

log ""
log "4. Resource usage:"
kubectl top node "$INSTANCE_NAME" 2>/dev/null | tee -a "$LOG_FILE" || log "   ⚠️  Metrics not yet available (metrics-server may not be installed)"

log ""
log "5. Service accounts:"
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
# STEP 10b: Configure Traefik ingress (all cluster types)
# ============================================================
# K3s runs with --disable servicelb, so without this HelmChartConfig Traefik stays
# ClusterIP and nothing binds :80/:443 (apps get "connection refused"). Needed on
# every cluster, not just control.
log ""
log "=========================================="
log "Configuring Traefik ingress (hostPort 80/443)"
log "=========================================="

TRAEFIK_MANIFEST_DIR="/var/lib/rancher/k3s/server/manifests"
mkdir -p "$TRAEFIK_MANIFEST_DIR"
if curl -fsSL "$MANIFESTS_BASE_URL/common/00a-traefik-config.yaml" -o "$TRAEFIK_MANIFEST_DIR/00a-traefik-config.yaml"; then
    log "✅ Traefik HelmChartConfig deployed — k3s helm-controller will reconcile Traefik as a hostNetwork DaemonSet"
else
    warn "Failed to download common/00a-traefik-config.yaml — Traefik will NOT bind :80/:443 (apps unreachable). Check MANIFESTS_BASE_URL."
fi

# ============================================================
# STEP 10c: Install flui-local StorageClass (all cluster types)
# ============================================================
# dedicated-persistence apps (managed Postgres) request flui-local and stay
# Pending without it. Needed on every cluster, not just control. Applied raw.
log ""
log "=========================================="
log "Installing flui-local StorageClass"
log "=========================================="

if curl -fsSL "$MANIFESTS_BASE_URL/common/01a-flui-local-storage.yaml" -o "$TRAEFIK_MANIFEST_DIR/01a-flui-local-storage.yaml"; then
    log "✅ flui-local StorageClass + provisioner deployed"
else
    warn "Failed to download common/01a-flui-local-storage.yaml — dedicated-persistence apps (managed Postgres) will stay Pending. Check MANIFESTS_BASE_URL."
fi

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
    # Pin ACME self-check resolvers to public DNS. The node's resolvers (often
    # the hosting provider's, especially on BYOS) can negative-cache a
    # just-created record for the zone's SOA minimum (1h on Hetzner DNS) and
    # stall every HTTP-01/DNS-01 challenge on freshly created endpoints.
    ACME_SELFCHECK_NAMESERVERS="${ACME_SELFCHECK_NAMESERVERS:-1.1.1.1:53,8.8.8.8:53}"
    if kubectl -n cert-manager get deployment cert-manager -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q 'dns01-recursive-nameservers'; then
        log "ACME self-check resolvers already pinned — skipping"
    elif kubectl -n cert-manager patch deployment cert-manager --type=json -p="[
        {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--dns01-recursive-nameservers=${ACME_SELFCHECK_NAMESERVERS}\"},
        {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--dns01-recursive-nameservers-only\"},
        {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--acme-http01-solver-nameservers=${ACME_SELFCHECK_NAMESERVERS}\"}
    ]"; then
        log "✅ ACME self-check resolvers pinned to ${ACME_SELFCHECK_NAMESERVERS}"
    else
        warn "Failed to pin ACME self-check resolvers — challenges will use the node's resolvers"
    fi

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
    # STEP 11b: Install cert-manager-webhook-hetzner
    # ============================================================
    # Installed with cert-manager regardless of CLOUD_PROVIDER: the webhook
    # solves DNS-01 for zones hosted on Hetzner DNS, and the zone's DNS
    # provider is independent of the compute provider (e.g. a BYOS or
    # Scaleway cluster using a Hetzner-managed zone for wildcard certs).
    if [ "${INSTALL_HETZNER_DNS_WEBHOOK:-true}" = "true" ]; then
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
        log "Skipping cert-manager-webhook-hetzner (INSTALL_HETZNER_DNS_WEBHOOK=false)"
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

    if [ "$AUTH_MODE" = "oidc" ]; then
        if [ -z "$ZITADEL_MASTERKEY" ] || [ -z "$ZITADEL_DB_ADMIN_PASSWORD" ] || [ -z "$ZITADEL_DB_USER_PASSWORD" ]; then
            error "AUTH_MODE=oidc requires ZITADEL_MASTERKEY, ZITADEL_DB_ADMIN_PASSWORD, ZITADEL_DB_USER_PASSWORD"
        fi
    else
        if [ -z "$JWT_SECRET" ]; then
            error "AUTH_MODE=local requires JWT_SECRET to be set"
        fi
    fi

    PRIMARY_IP=$(hostname -I | awk '{print $1}')
    export MASTER_IP="$PRIMARY_IP"
    # Domain IP: an operator-provided public IP wins (BYOS behind NAT or with a
    # fixed public IP), otherwise the node's detected IP.
    DOMAIN_IP="${FLUI_MASTER_PUBLIC_IP:-$PRIMARY_IP}"
    # Encode IP with dashes so a numeric-suffixed token (e.g. "royal-gecko-72")
    # cannot collide with nip.io's greedy IPv4 extraction (which would otherwise
    # resolve royal-gecko-72.162.55.56.10.nip.io to 72.162.55.56).
    DASHED_IP="${DOMAIN_IP//./-}"
    if [ -z "${FLUI_BASE_DOMAIN:-}" ]; then
        if [ -n "${NIP_HOSTNAME_TOKEN:-}" ]; then
            FLUI_BASE_DOMAIN="${NIP_HOSTNAME_TOKEN}.${DASHED_IP}.nip.io"
        else
            FLUI_BASE_DOMAIN="${DASHED_IP}.nip.io"
        fi
    fi
    export FLUI_BASE_DOMAIN NIP_HOSTNAME_TOKEN
    log "FLUI_BASE_DOMAIN: $FLUI_BASE_DOMAIN (api.$FLUI_BASE_DOMAIN, app.$FLUI_BASE_DOMAIN)"
    if [ "$AUTH_MODE" = "oidc" ] && [ -z "$ZITADEL_DOMAIN" ]; then
        ZITADEL_DOMAIN="auth.${FLUI_BASE_DOMAIN}"
        log "ZITADEL_DOMAIN not set, defaulting to: $ZITADEL_DOMAIN"
    fi
    # In-cluster Zitadel URL for JWKS avoids TLS validation on the sidecar path.
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

    MANIFEST_DIR="/var/lib/rancher/k3s/server/manifests"
    mkdir -p "$MANIFEST_DIR"

    log "Manifest directory: $MANIFEST_DIR"
    log "Downloading manifests from: $MANIFESTS_BASE_URL/control/"
    log "Deploying components: namespace, postgres, redis, vmsingle, vmagent, loki, grafana"

    # Metrics stack: vmsingle (TSDB + receiver) + vmagent (scraper, push to vmsingle).
    # Replaces Prometheus on new clusters per ADR-001-metrics-transport.
    export CLUSTER_TYPE="control"
    export REMOTE_WRITE_URL="http://vmsingle.flui-control.svc.cluster.local:8428/api/v1/write"

    # Flui component image tags: injected by the CLI for a pinned release;
    # default to `latest` for older CLIs and mobile (--latest) installs.
    : "${FLUI_API_IMAGE_TAG:=latest}"
    : "${FLUI_WEB_IMAGE_TAG:=latest}"
    : "${FLUI_AUTHZ_IMAGE_TAG:=latest}"
    export FLUI_API_IMAGE_TAG FLUI_WEB_IMAGE_TAG FLUI_AUTHZ_IMAGE_TAG

    # Shared secret between Alertmanager and the API's /webhooks/alerts receiver.
    # Generated here, not by the CLI: both ends live in this cluster, so the token
    # never has to leave it. Reused when it already exists — the two manifests are
    # rendered from the same value, and a re-run that minted a fresh one would
    # desync them until both pods happened to restart.
    if [ -z "${ALERTS_WEBHOOK_TOKEN:-}" ]; then
        ALERTS_WEBHOOK_TOKEN=$(kubectl get secret flui-secrets -n flui-system \
            -o jsonpath='{.data.ALERTS_WEBHOOK_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null || true)
    fi
    if [ -z "${ALERTS_WEBHOOK_TOKEN:-}" ]; then
        ALERTS_WEBHOOK_TOKEN=$(openssl rand -hex 32)
        log "Generated a new alerts webhook token"
    else
        log "Reusing the existing alerts webhook token"
    fi
    export ALERTS_WEBHOOK_TOKEN

    # 00a-traefik-config and 01a-flui-local-storage now applied in STEP 10b/10c.
    MANIFESTS="00-secrets 01-namespace 02-postgres 03-redis 04-vmagent-config 04a-kube-state-metrics 04b-vmagent 04c-vmalert 04d-alertmanager 05-vmsingle 06-loki 07-grafana-datasources 08-grafana 09-flui-api 12-flui-web-config 10-flui-web"
    if [ "$AUTH_MODE" = "oidc" ]; then
        MANIFESTS="$MANIFESTS 11-zitadel"
        log "AUTH_MODE=oidc: Zitadel will be deployed"
    else
        log "AUTH_MODE=local: Zitadel will NOT be deployed (using built-in JWT auth)"
    fi

    for manifest in $MANIFESTS; do
        log "→ Downloading ${manifest}.yaml..."
        if ! curl -fsSL "$MANIFESTS_BASE_URL/control/${manifest}.yaml" -o "/tmp/${manifest}.yaml"; then
            error "Failed to download ${manifest}.yaml from $MANIFESTS_BASE_URL/control/"
        fi

        # flui-local is fully static; its provisioner setup/teardown scripts use
        # runtime vars ($VOL_DIR) that envsubst would blank out — apply raw.
        if [ "$manifest" = "01a-flui-local-storage" ]; then
            cp "/tmp/${manifest}.yaml" "$MANIFEST_DIR/${manifest}.yaml"
            log "✅ ${manifest}.yaml deployed (raw, no envsubst)"
            rm -f "/tmp/${manifest}.yaml"
            continue
        fi

        if command -v envsubst &> /dev/null; then
            export CLUSTER_ID SERVER_ID CLUSTER_NAME CLOUD_PROVIDER CLUSTER_TYPE
            export REMOTE_WRITE_URL
            export ZITADEL_MASTERKEY ZITADEL_DB_ADMIN_PASSWORD ZITADEL_DB_USER_PASSWORD
            export ZITADEL_DOMAIN ZITADEL_ADMIN_EMAIL ZITADEL_ADMIN_TEMP_PASSWORD ZITADEL_AUDIENCE
            export OIDC_ISSUER OIDC_JWKS_URI OIDC_AUDIENCE
            export AUTH_MODE JWT_SECRET ADMIN_EMAIL ADMIN_PASSWORD CERTIFICATE_MODE
            export FLUI_BASE_DOMAIN NIP_HOSTNAME_TOKEN
            export FLUI_BOOTSTRAP_NODE_PRIVATE_IP="${PRIVATE_IP:-}"
            # Public/reachable IP for the API's cluster seed (BYOS: differs from
            # the internal node IP; empty for provisioned, where MASTER_IP is public).
            export FLUI_MASTER_PUBLIC_IP="${FLUI_MASTER_PUBLIC_IP:-}"
            envsubst < "/tmp/${manifest}.yaml" > "$MANIFEST_DIR/${manifest}.yaml"
        else
            log "⚠️  envsubst not found, using sed for variable substitution..."
            sed -e "s/\${POSTGRES_PASSWORD}/$POSTGRES_PASSWORD/g" \
                -e "s/\${REDIS_PASSWORD}/$REDIS_PASSWORD/g" \
                -e "s/\${GRAFANA_PASSWORD}/$GRAFANA_PASSWORD/g" \
                -e "s/\${ENCRYPTION_KEY}/$ENCRYPTION_KEY/g" \
                -e "s/\${MASTER_IP}/$MASTER_IP/g" \
                -e "s/\${FLUI_MASTER_PUBLIC_IP}/${FLUI_MASTER_PUBLIC_IP:-}/g" \
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
                -e "s|\${ALERTS_WEBHOOK_TOKEN}|$ALERTS_WEBHOOK_TOKEN|g" \
                -e "s/\${ADMIN_EMAIL}/$ADMIN_EMAIL/g" \
                -e "s|\${ADMIN_PASSWORD}|$ADMIN_PASSWORD|g" \
                -e "s/\${FLUI_BASE_DOMAIN}/$FLUI_BASE_DOMAIN/g" \
                -e "s/\${NIP_HOSTNAME_TOKEN}/$NIP_HOSTNAME_TOKEN/g" \
                -e "s|\${FLUI_API_IMAGE_TAG}|$FLUI_API_IMAGE_TAG|g" \
                -e "s|\${FLUI_WEB_IMAGE_TAG}|$FLUI_WEB_IMAGE_TAG|g" \
                "/tmp/${manifest}.yaml" > "$MANIFEST_DIR/${manifest}.yaml"
        fi

        if [ "${FLUI_NIP_IO_CERT_ENABLED:-}" = "true" ] && \
           [[ "$manifest" == "09-flui-api" || "$manifest" == "10-flui-web" || "$manifest" == "11-zitadel" ]]; then
            sed -i 's|^  tls: {}$|  tls:\n    secretName: flui-system-tls|' "$MANIFEST_DIR/${manifest}.yaml"
            log "✓ Wired ${manifest} IngressRoute to flui-system-tls"
        fi

        log "✅ ${manifest}.yaml deployed"
        rm -f "/tmp/${manifest}.yaml"
    done

    log "✅ All manifests downloaded and deployed to $MANIFEST_DIR"
    log "K3s will auto-apply these manifests..."

    # Async TLS certificate bootstrap (nip.io clusters only)
    # Waits for cert-manager + Traefik + namespace, then applies the Certificate.
    # Runs in background so it doesn't block k3s init flow.
    if [ "${FLUI_NIP_IO_CERT_ENABLED:-}" = "true" ]; then
        log "→ Scheduling async system TLS certificate bootstrap..."
        if ! curl -fsSL "$MANIFESTS_BASE_URL/control/13-system-tls-cert.yaml" -o /tmp/13-system-tls-cert.yaml; then
            warn "Failed to download 13-system-tls-cert.yaml — TLS bootstrap skipped"
        else
            if [ "${FLUI_ACME_STAGING:-}" = "true" ]; then
                export ACME_SERVER_URL="https://acme-staging-v02.api.letsencrypt.org/directory"
                log "✓ Using Let's Encrypt STAGING (untrusted cert, no rate limits)"
            else
                export ACME_SERVER_URL="https://acme-v02.api.letsencrypt.org/directory"
            fi
            export ADMIN_EMAIL FLUI_BASE_DOMAIN
            envsubst < /tmp/13-system-tls-cert.yaml > /tmp/13-system-tls-cert.rendered.yaml
            (
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for cert-manager CRDs..."
                kubectl wait --for=condition=Established crd/certificates.cert-manager.io --timeout=600s
                kubectl wait --for=condition=Established crd/clusterissuers.cert-manager.io --timeout=600s
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for cert-manager deployment..."
                kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=600s
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for Traefik pod..."
                kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=traefik -n kube-system --timeout=600s
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for flui-system namespace..."
                until kubectl get namespace flui-system >/dev/null 2>&1; do sleep 2; done
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Applying ClusterIssuer + Certificate..."
                kubectl apply -f /tmp/13-system-tls-cert.rendered.yaml
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ System TLS certificate requested"
            ) > /var/log/flui-cert-bootstrap.log 2>&1 &
            disown
            log "✓ TLS bootstrap subshell started (PID $!) — log: /var/log/flui-cert-bootstrap.log"
        fi
    fi

    # Async OIDC provisioning (parallel to flui-api boot)
    # Provisions the Zitadel project/apps/roles and patches flui-secrets/configmaps
    # so flui-api picks up OIDC_AUDIENCE from a single restart driven by this script.
    # Skips itself silently when AUTH_MODE != oidc.
    if [ "${AUTH_MODE:-}" = "oidc" ]; then
        log "→ Scheduling async OIDC provisioning..."
        if ! curl -fsSL "$SCRIPTS_BASE_URL/setup-zitadel-oidc.sh" -o /tmp/setup-zitadel-oidc.sh; then
            warn "Failed to download setup-zitadel-oidc.sh — OIDC bootstrap skipped (API-side fallback will handle it)"
        else
            chmod +x /tmp/setup-zitadel-oidc.sh
            (
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for flui-system namespace..."
                until kubectl get namespace flui-system >/dev/null 2>&1; do sleep 2; done
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for zitadel deployment to exist..."
                until kubectl get deployment zitadel -n flui-system >/dev/null 2>&1; do sleep 2; done
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for Zitadel deployment Available..."
                kubectl wait --for=condition=Available deployment/zitadel -n flui-system --timeout=900s
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for zitadel-bootstrap-pvc..."
                until kubectl get pvc zitadel-bootstrap-pvc -n flui-system >/dev/null 2>&1; do sleep 2; done
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Running setup-zitadel-oidc.sh..."
                MASTER_IP="$MASTER_IP" \
                    NIP_HOSTNAME_TOKEN="${NIP_HOSTNAME_TOKEN:-}" \
                    FLUI_BASE_DOMAIN="${FLUI_BASE_DOMAIN:-}" \
                    ZITADEL_DOMAIN="${ZITADEL_DOMAIN:-}" \
                    /tmp/setup-zitadel-oidc.sh
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ OIDC provisioning complete"
            ) > /var/log/flui-oidc-bootstrap.log 2>&1 &
            disown
            log "✓ OIDC bootstrap subshell started (PID $!) — log: /var/log/flui-oidc-bootstrap.log"
        fi
    fi

    log "→ Waiting for K3s to create the postgres pod..."
    until kubectl get pod -l app=postgres -n flui-system 2>/dev/null | grep -q "postgres"; do
        sleep 3
    done
    log "✅ K3s has created resources"

    log ""
    log "Waiting for observability stack components to be ready..."
    log "Maximum wait time: 10 minutes for databases, 5 minutes for other components"

    COMPONENT_TIMEOUT=300   # 5 minutes for most components
    POSTGRES_TIMEOUT=600    # 10 minutes for PostgreSQL (PVC binding + DB init)
    REDIS_TIMEOUT=600       # 10 minutes for Redis (PVC binding)

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

    log "→ Waiting for vmsingle, vmagent, kube-state-metrics, Loki, Grafana (parallel)..."
    update_health "deploying" "observability-components" ""

    kubectl wait --for=condition=ready pod -l app=vmsingle -n flui-control --timeout=${COMPONENT_TIMEOUT}s 2>/dev/null &
    PID_VMSINGLE=$!
    kubectl wait --for=condition=ready pod -l app=vmagent -n flui-control --timeout=${COMPONENT_TIMEOUT}s 2>/dev/null &
    PID_VMAGENT=$!
    kubectl wait --for=condition=ready pod -l app=vmalert -n flui-control --timeout=${COMPONENT_TIMEOUT}s 2>/dev/null &
    PID_VMALERT=$!
    kubectl wait --for=condition=ready pod -l app=kube-state-metrics -n flui-control --timeout=${COMPONENT_TIMEOUT}s 2>/dev/null &
    PID_KSM=$!
    kubectl wait --for=condition=ready pod -l app=loki -n flui-control --timeout=${COMPONENT_TIMEOUT}s 2>/dev/null &
    PID_LOKI=$!
    kubectl wait --for=condition=ready pod -l app=grafana -n flui-control --timeout=${COMPONENT_TIMEOUT}s 2>/dev/null &
    PID_GRAFANA=$!

    if wait $PID_VMSINGLE; then log "✅ vmsingle is ready"; else
        error_msg="vmsingle failed to become ready within ${COMPONENT_TIMEOUT}s"
        update_health "failed" "vmsingle" "$error_msg"; error "$error_msg"
    fi

    if wait $PID_VMAGENT; then log "✅ vmagent is ready"; else
        error_msg="vmagent failed to become ready within ${COMPONENT_TIMEOUT}s"
        update_health "failed" "vmagent" "$error_msg"; error "$error_msg"
    fi

    if wait $PID_VMALERT; then log "✅ vmalert is ready"; else
        warn "vmalert failed to become ready within ${COMPONENT_TIMEOUT}s (recording rules unavailable)"
    fi
    if wait $PID_KSM; then log "✅ kube-state-metrics is ready"; else
        warn "kube-state-metrics did not become ready within ${COMPONENT_TIMEOUT}s (non-critical)"
    fi
    if wait $PID_LOKI; then log "✅ Loki is ready"; else
        error_msg="Loki failed to become ready within ${COMPONENT_TIMEOUT}s"
        update_health "failed" "loki" "$error_msg"; error "$error_msg"
    fi
    if wait $PID_GRAFANA; then log "✅ Grafana is ready"; else
        error_msg="Grafana failed to become ready within ${COMPONENT_TIMEOUT}s"
        update_health "failed" "grafana" "$error_msg"; error "$error_msg"
    fi

    # Re-apply IngressRoutes: K3s may have applied them before Traefik CRDs existed at startup.
    log "→ Ensuring IngressRoute CRD is established..."
    if kubectl wait --for=condition=established crd/ingressroutes.traefik.io --timeout=120s 2>/dev/null; then
        log "✅ Traefik IngressRoute CRD ready — re-applying IngressRoute manifests..."
        kubectl apply -f "$MANIFEST_DIR/09-flui-api.yaml" 2>/dev/null || true
        kubectl apply -f "$MANIFEST_DIR/10-flui-web.yaml" 2>/dev/null || true
        if [ "$AUTH_MODE" = "oidc" ]; then
            kubectl apply -f "$MANIFEST_DIR/11-zitadel.yaml" 2>/dev/null || true
        fi
        log "✅ IngressRoute manifests applied"
    else
        warn "Traefik IngressRoute CRD not ready within 120s — IngressRoutes may be missing"
    fi

    log "→ Waiting for Flui API..."
    update_health "deploying" "flui-api" ""
    if kubectl wait --for=condition=ready pod -l app=flui-api -n flui-system --timeout=${COMPONENT_TIMEOUT}s 2>/dev/null; then
        log "✅ Flui API is ready"
    else
        warn "Flui API did not become ready within ${COMPONENT_TIMEOUT}s (non-critical, image may not be available yet)"
    fi

    log "→ Injecting kubeconfig into flui-secrets..."
    KUBECONFIG_B64=$(base64 -w 0 /etc/rancher/k3s/k3s.yaml)
    if kubectl patch secret flui-secrets -n flui-system \
        --type='json' \
        -p="[{\"op\":\"add\",\"path\":\"/data/KUBECONFIG_CONTENT\",\"value\":\"${KUBECONFIG_B64}\"}]" 2>/dev/null; then
        log "✅ Kubeconfig injected into flui-secrets"
        kubectl rollout restart deployment/flui-api -n flui-system 2>/dev/null || true
        log "✅ Flui API restarted to pick up kubeconfig"
    else
        warn "Failed to inject kubeconfig into flui-secrets (non-critical)"
    fi

    log "→ Waiting for Flui Web..."
    update_health "deploying" "flui-web" ""
    if kubectl wait --for=condition=ready pod -l app=flui-web -n flui-system --timeout=${COMPONENT_TIMEOUT}s 2>/dev/null; then
        log "✅ Flui Web is ready"
    else
        warn "Flui Web did not become ready within ${COMPONENT_TIMEOUT}s (non-critical, image may not be available yet)"
    fi

    if [ "$AUTH_MODE" = "oidc" ]; then
        log "→ Waiting for Zitadel API deployment (start-from-init runs init+setup+start)..."
        update_health "deploying" "zitadel" ""
        if kubectl rollout status deployment/zitadel -n flui-system --timeout=${COMPONENT_TIMEOUT}s 2>/dev/null; then
            log "✅ Zitadel API is ready"
        else
            warn "Zitadel API did not become ready within ${COMPONENT_TIMEOUT}s (non-critical)"
        fi
    fi

    log ""
    log "✅ All observability stack components are ready!"

    log ""
    log "=========================================="
    log "Service Endpoints"
    log "=========================================="
    log "Grafana:    cluster-internal only (kubectl port-forward grafana)"
    log "vmsingle:   NodePort 30428 (remote_write receiver, VNet-private)"
    log "PostgreSQL: postgres:5432 (fluicloud/$POSTGRES_PASSWORD) — cluster-internal"
    log "Redis:      redis:6379 (password: $REDIS_PASSWORD) — cluster-internal"
    log "Loki:       cluster-internal only"
    log "Flui API:   https://api.$FLUI_BASE_DOMAIN"
    log "Flui Web:   https://app.$FLUI_BASE_DOMAIN"
    if [ "$AUTH_MODE" = "oidc" ]; then
        log "Zitadel:    https://$ZITADEL_DOMAIN (admin: $ZITADEL_ADMIN_EMAIL)"
    else
        log "Auth:       Local JWT (AUTH_MODE=local)"
    fi
    log "Ingress:    http://$PRIMARY_IP:80 (Traefik)"
    log ""

    touch /var/log/observability-stack-ready
    log "✅ Marker file created: /var/log/observability-stack-ready"
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

    # Workload metrics push: vmagent in flui-monitoring namespace remote_writes
    # to vmsingle on the OBS cluster via VNet-private NodePort 30428.
    # Only deployed when DEPLOY_MONITORING_AGENT=true and OBSERVABILITY_CLUSTER_IP set.
    if [ "$DEPLOY_MONITORING_AGENT" = "true" ] && [ -n "$OBSERVABILITY_CLUSTER_IP" ]; then
        log "→ Deploying workload vmagent (push to ${OBSERVABILITY_CLUSTER_IP}:30428)..."
        MANIFEST_DIR="/var/lib/rancher/k3s/server/manifests"
        mkdir -p "$MANIFEST_DIR"
        export REMOTE_WRITE_URL="http://${OBSERVABILITY_CLUSTER_IP}:30428/api/v1/write"
        export CLUSTER_ID CLUSTER_NAME REMOTE_WRITE_URL
        if curl -fsSL "$MANIFESTS_BASE_URL/workload/vmagent.yaml" -o /tmp/vmagent.yaml; then
            if command -v envsubst &> /dev/null; then
                envsubst < /tmp/vmagent.yaml > "$MANIFEST_DIR/vmagent.yaml"
            else
                sed -e "s|\${REMOTE_WRITE_URL}|$REMOTE_WRITE_URL|g" \
                    -e "s/\${CLUSTER_ID}/$CLUSTER_ID/g" \
                    -e "s/\${CLUSTER_NAME}/$CLUSTER_NAME/g" \
                    /tmp/vmagent.yaml > "$MANIFEST_DIR/vmagent.yaml"
            fi
            log "✅ Workload vmagent manifest deployed"
            rm -f /tmp/vmagent.yaml

            # kube-state-metrics must run here too: the flui:app_* recording rules on
            # the OBS cluster join every metric against kube_pod_labels, which only KSM
            # produces. Without it this cluster's apps report null for every metric.
            log "→ Deploying workload kube-state-metrics..."
            if curl -fsSL "$MANIFESTS_BASE_URL/workload/kube-state-metrics.yaml" \
                -o "$MANIFEST_DIR/kube-state-metrics.yaml"; then
                log "✅ Workload kube-state-metrics manifest deployed"
            else
                warn "Failed to download kube-state-metrics manifest — app metrics will read null"
            fi
        else
            warn "Failed to download workload vmagent manifest — metrics push disabled"
        fi
    else
        log "ℹ Skipping workload vmagent (DEPLOY_MONITORING_AGENT=$DEPLOY_MONITORING_AGENT, OBSERVABILITY_CLUSTER_IP=${OBSERVABILITY_CLUSTER_IP:-empty})"
    fi

    update_health "ready" "k3s-only" ""
fi

touch /var/log/k3s-master-ready
log "✅ Marker file created: /var/log/k3s-master-ready"

log ""
if [ -n "${FLUI_BASE_DOMAIN:-}" ]; then
    log "Bootstrap complete. Readiness signal: https://app.$FLUI_BASE_DOMAIN/"
else
    log "Bootstrap complete."
fi
touch /var/log/flui-bootstrap-complete

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
