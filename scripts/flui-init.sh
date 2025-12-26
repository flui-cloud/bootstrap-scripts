#!/bin/bash
# flui-init.sh - Podman + System Monitoring installer for Ubuntu 22/24
# Version: 1.2.0
# Now uses modular monitoring components from modules/ directory

set -euo pipefail

# Configuration
readonly FLUI_USER="flui"
readonly LOG_FILE="/var/log/flui-init.log"
readonly NODE_EXPORTER_VERSION="1.7.0"
readonly VECTOR_VERSION="0.34.1"

# Monitoring configuration (can be overridden by environment variables)
PROMETHEUS_ENDPOINT="${PROMETHEUS_ENDPOINT:-}"
LOKI_ENDPOINT="${LOKI_ENDPOINT:-}"
SERVER_TYPE="${SERVER_TYPE:-vps}"
SERVER_ID="${INSTANCE_ID:-unknown}"
CLOUD_PROVIDER="${CLOUD_PROVIDER:-unknown}"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[$(date +'%H:%M:%S')]${NC} WARNING: $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[$(date +'%H:%M:%S')]${NC} ERROR: $1" | tee -a "$LOG_FILE"
    exit 1
}

detect_system() {
    log "Detecting system..."
    
    if [[ ! -f /etc/os-release ]]; then
        error "/etc/os-release not found"
    fi
    
    source /etc/os-release
    
    if [[ "$ID" != "ubuntu" ]]; then
        error "Unsupported OS: $ID (only Ubuntu supported)"
    fi
    
    case "$VERSION_ID" in
        "22.04"|"24.04")
            log "Ubuntu $VERSION_ID detected"
            ;;
        *)
            error "Unsupported Ubuntu version: $VERSION_ID"
            ;;
    esac
    
    if [[ "$(uname -m)" != "x86_64" ]]; then
        error "Unsupported architecture: $(uname -m)"
    fi
    
    log "✅ System validation passed"
}

update_system() {
    log "Updating system packages..."
    
    export DEBIAN_FRONTEND=noninteractive
    
    if ! apt-get update -qq; then
        error "Failed to update package lists"
    fi
    
    if ! apt-get install -qq -y curl wget ca-certificates gnupg software-properties-common apt-transport-https tar gzip systemd; then
        error "Failed to install essential packages"
    fi
    
    log "✅ System packages updated"
}

install_podman() {
    log "Installing Podman..."
    
    case "$VERSION_ID" in
        "22.04")
            log "Setting up Podman repository for Ubuntu 22.04..."
            local repo_url="https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_22.04/"
            local key_url="https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable/xUbuntu_22.04/Release.key"
            
            echo "deb ${repo_url} /" | tee /etc/apt/sources.list.d/kubic-libcontainers.list > /dev/null
            
            if ! curl -fsSL "$key_url" | gpg --dearmor -o /usr/share/keyrings/kubic-libcontainers.gpg; then
                error "Failed to add Podman repository key"
            fi
            
            echo "deb [signed-by=/usr/share/keyrings/kubic-libcontainers.gpg] ${repo_url} /" | tee /etc/apt/sources.list.d/kubic-libcontainers.list > /dev/null
            ;;
            
        "24.04")
            log "Enabling universe repository for Ubuntu 24.04..."
            if ! add-apt-repository -y universe; then
                error "Failed to enable universe repository"
            fi
            ;;
    esac
    
    if ! apt-get update -qq; then
        error "Failed to update package lists"
    fi
    
    if ! apt-get install -qq -y podman crun slirp4netns fuse-overlayfs buildah skopeo; then
        error "Failed to install Podman packages"
    fi
    
    if ! command -v podman &> /dev/null; then
        error "Podman installation verification failed"
    fi
    
    local podman_version=$(podman --version)
    log "✅ Podman installed: $podman_version"
    
    mkdir -p /etc/containers
    cat > /etc/containers/containers.conf << 'EOF'
[containers]
default_capabilities = [
  "CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "KILL",
  "NET_BIND_SERVICE", "SETFCAP", "SETGID", "SETPCAP", "SETUID", "SYS_CHROOT"
]

[engine]
runtime = "crun"

[engine.runtimes]
crun = ["/usr/bin/crun"]
EOF
    
    log "✅ Podman configuration completed"
}

# Source monitoring modules
# These modules are now shared across all server types (VPS, K3s nodes, Build Agents)
MODULES_DIR="$(dirname "$0")/modules"

# Check if modules directory exists, if not try alternate path
if [ ! -d "$MODULES_DIR" ]; then
    # When embedded in cloud-init, modules might be in different location
    MODULES_DIR="/tmp/flui-modules"
fi

# Try to load monitoring modules, but don't fail if they're not available
# This makes the script more resilient - monitoring is optional, CA installation is critical
if [ -f "${MODULES_DIR}/monitoring.sh" ]; then
    if source "${MODULES_DIR}/node-exporter.sh" && \
       source "${MODULES_DIR}/vector.sh" && \
       source "${MODULES_DIR}/monitoring.sh"; then
        log "✅ Monitoring modules loaded from ${MODULES_DIR}"
    else
        warn "Failed to load some monitoring modules from ${MODULES_DIR}"
        warn "Continuing without monitoring - this is non-critical"
    fi
else
    warn "Monitoring modules not found in ${MODULES_DIR}"
    warn "Continuing without monitoring - CA installation and security are still enforced"
fi

configure_logging() {
    log "Configuring system logging..."
    
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/flui.conf << 'EOF'
[Journal]
Storage=persistent
Compress=yes
MaxRetentionSec=7days
MaxFileSec=100M
SystemMaxUse=1G
ForwardToSyslog=yes
EOF

    systemctl restart systemd-journald
    log "✅ System logging configured"
}

setup_flui_user() {
    log "Setting up flui user..."
    
    if ! id "$FLUI_USER" &>/dev/null; then
        if ! useradd -m -s /bin/bash "$FLUI_USER"; then
            error "Failed to create user: $FLUI_USER"
        fi
        log "Created user: $FLUI_USER"
    else
        log "User $FLUI_USER already exists"
    fi
    
    local subuid_entry="${FLUI_USER}:100000:65536"
    
    if ! grep -q "^${FLUI_USER}:" /etc/subuid; then
        echo "$subuid_entry" >> /etc/subuid
    fi
    
    if ! grep -q "^${FLUI_USER}:" /etc/subgid; then
        echo "$subuid_entry" >> /etc/subgid
    fi
    
    if ! loginctl enable-linger "$FLUI_USER"; then
        warn "Failed to enable lingering for $FLUI_USER"
    fi
    
    sudo -u "$FLUI_USER" mkdir -p \
        "/home/$FLUI_USER/.config/containers" \
        "/home/$FLUI_USER/.local/share/containers" \
        "/home/$FLUI_USER/.config/systemd/user" \
        "/home/$FLUI_USER/logs" \
        "/home/$FLUI_USER/data"
    
    sudo -u "$FLUI_USER" cat > "/home/$FLUI_USER/.config/containers/storage.conf" << 'EOF'
[storage]
driver = "overlay"
runroot = "/run/user/1000/containers"
graphroot = "/home/flui/.local/share/containers/storage"

[storage.options]
additionalimagestores = []

[storage.options.overlay]
mountopt = "nodev"
EOF

    chown -R "$FLUI_USER:$FLUI_USER" "/home/$FLUI_USER"
    log "✅ Flui user configured"
}

install_ca_public_key() {
    log "Installing SSH Certificate Authority..."

    # Check if CA public key is provided via environment variable
    if [[ -z "${FLUI_CA_PUBLIC_KEY:-}" ]]; then
        warn "FLUI_CA_PUBLIC_KEY not set, skipping CA installation"
        return 0
    fi

    # Backup existing sshd_config
    if [[ -f /etc/ssh/sshd_config ]]; then
        cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"
    fi

    # Install CA public key
    echo "$FLUI_CA_PUBLIC_KEY" > /etc/ssh/trusted_user_ca_keys
    chmod 644 /etc/ssh/trusted_user_ca_keys
    log "✅ CA public key installed to /etc/ssh/trusted_user_ca_keys"

    # Configure sshd to trust CA
    if ! grep -q "^TrustedUserCAKeys" /etc/ssh/sshd_config; then
        echo "TrustedUserCAKeys /etc/ssh/trusted_user_ca_keys" >> /etc/ssh/sshd_config
        log "✅ TrustedUserCAKeys configured in sshd_config"
    else
        log "⊙ TrustedUserCAKeys already configured"
    fi

    # Disable password authentication (security hardening)
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    log "✅ Password authentication disabled"

    # Reload SSH daemon
    if systemctl reload sshd 2>/dev/null; then
        log "✅ SSH daemon reloaded (sshd)"
    elif systemctl reload ssh 2>/dev/null; then
        log "✅ SSH daemon reloaded (ssh)"
    else
        warn "Could not reload SSH daemon. Manual restart may be required."
        warn "SSH will use new configuration after next connection."
        # Don't fail - SSH reload is non-critical since we're already connected
    fi

    log "✅ SSH CA installation completed"
}

configure_security() {
    log "Configuring security..."

    if ! apt-get install -qq -y ufw fail2ban; then
        warn "Failed to install security packages"
        return
    fi

    ufw --force reset &>/dev/null
    ufw --force enable &>/dev/null

    local ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | cut -d: -f2 | head -1)
    ssh_port=${ssh_port:-22}
    ufw allow "$ssh_port/tcp" comment "SSH" &>/dev/null

    # Note: Monitoring firewall rules (ports 9100, 8686) are now managed
    # by configure_monitoring_firewall() in modules/monitoring.sh

    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3

[sshd]
enabled = true
port = $ssh_port
filter = sshd
logpath = /var/log/auth.log
EOF

    systemctl enable --now fail2ban &>/dev/null
    log "✅ Security configured"
}

test_installations() {
    log "Testing installations..."
    
    if ! sudo -u "$FLUI_USER" podman --version &>/dev/null; then
        error "Podman test failed"
    fi
    
    if ! timeout 30 sudo -u "$FLUI_USER" podman run --rm alpine:latest echo "Test" &>/dev/null; then
        warn "Container test failed"
    else
        log "✅ Container test passed"
    fi
    
    if curl -f -s http://localhost:9100/metrics >/dev/null 2>&1; then
        log "✅ Node Exporter responding"
    else
        warn "Node Exporter not responding"
    fi
    
    if curl -s http://localhost:8686/health &>/dev/null; then
        log "✅ Vector API responding"
    else
        warn "Vector API not responding"
    fi
    
    log "✅ Installation testing completed"
}

cleanup() {
    log "Cleaning up..."
    apt-get autoremove -qq -y &>/dev/null || true
    apt-get autoclean -qq &>/dev/null || true
    rm -rf /tmp/flui-* /tmp/node_exporter-* /var/tmp/flui-* || true
    log "✅ Cleanup completed"
}

main() {
    local start_time=$(date +%s)

    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"

    log "🚀 Starting Flui.cloud installation"

    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
    fi

    detect_system

    # CRITICAL: Install CA public key FIRST, before any operations that might fail
    # This ensures SSH access is always available for debugging
    install_ca_public_key

    update_system
    install_podman
    # Use modular monitoring installation (Node Exporter + Vector)
    # Note: Monitoring modules are optional and loaded conditionally above
    if type install_monitoring &>/dev/null; then
        install_monitoring "$PROMETHEUS_ENDPOINT" "$LOKI_ENDPOINT" "$SERVER_TYPE" "$SERVER_ID" "$CLOUD_PROVIDER"
    else
        log "⚠️  Monitoring installation skipped (modules not available)"
    fi
    configure_logging
    setup_flui_user
    configure_security
    test_installations
    cleanup

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log ""
    log "🎉 Flui.cloud installation completed!"
    log "⏱️  Duration: ${duration} seconds"
    log "✅ Instance ready for deployment!"
}

trap 'error "Script failed at line $LINENO"' ERR
main "$@"