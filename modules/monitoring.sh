#!/bin/bash
# Monitoring Module Orchestrator
# Coordinates installation of Node Exporter and Vector
# Provides unified monitoring setup for all Flui server types

# Source required modules
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "${SCRIPT_DIR}/node-exporter.sh"
source "${SCRIPT_DIR}/vector.sh"

install_monitoring() {
    local PROMETHEUS_ENDPOINT="${1:-}"
    local LOKI_ENDPOINT="${2:-}"
    local SERVER_TYPE="${3:-generic}"
    local SERVER_ID="${4:-unknown}"
    local CLOUD_PROVIDER="${5:-unknown}"

    log "=========================================="
    log "Flui Monitoring Installation"
    log "=========================================="
    log "Server Type: ${SERVER_TYPE}"
    log "Server ID: ${SERVER_ID}"
    log "Cloud Provider: ${CLOUD_PROVIDER}"
    log "Prometheus Endpoint: ${PROMETHEUS_ENDPOINT:-not configured}"
    log "Loki Endpoint: ${LOKI_ENDPOINT:-not configured}"
    log "=========================================="

    # Install Node Exporter for Prometheus metrics
    install_node_exporter

    # Install Vector for log aggregation
    install_vector "$LOKI_ENDPOINT" "$SERVER_TYPE" "$SERVER_ID" "$CLOUD_PROVIDER"

    # Configure firewall rules for monitoring
    configure_monitoring_firewall

    log "=========================================="
    log "✅ Monitoring installation complete"
    log "=========================================="
}

configure_monitoring_firewall() {
    log "Configuring firewall rules for monitoring..."

    # Allow Node Exporter (9100) from private networks
    ufw allow from 10.0.0.0/8 to any port 9100 comment 'Node Exporter - Prometheus metrics' || true
    ufw allow from 172.16.0.0/12 to any port 9100 comment 'Node Exporter - Prometheus metrics' || true
    ufw allow from 192.168.0.0/16 to any port 9100 comment 'Node Exporter - Prometheus metrics' || true

    # Allow Vector API (8686) from private networks
    ufw allow from 10.0.0.0/8 to any port 8686 comment 'Vector API' || true
    ufw allow from 172.16.0.0/12 to any port 8686 comment 'Vector API' || true
    ufw allow from 192.168.0.0/16 to any port 8686 comment 'Vector API' || true

    log "✅ Firewall rules configured for monitoring"
}

# Export functions for use in parent scripts
export -f install_monitoring
export -f configure_monitoring_firewall
export -f install_node_exporter
export -f install_vector
