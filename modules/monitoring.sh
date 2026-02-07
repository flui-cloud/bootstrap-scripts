#!/bin/bash
# Monitoring Module Orchestrator
# Coordinates installation of Node Exporter and Vector
# Provides unified monitoring setup for all Flui server types

# Define logging functions if not already defined (for standalone execution)
if ! type log &>/dev/null; then
    log() {
        echo "[$(date +'%H:%M:%S')] $1"
    }
fi

if ! type warn &>/dev/null; then
    warn() {
        echo "[$(date +'%H:%M:%S')] WARNING: $1"
    }
fi

if ! type error &>/dev/null; then
    error() {
        echo "[$(date +'%H:%M:%S')] ERROR: $1"
        exit 1
    }
fi

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
    local CLUSTER_ID="${6:-unknown}"
    local CLUSTER_NAME="${7:-unknown}"

    log "=========================================="
    log "Flui Monitoring Installation"
    log "=========================================="
    log "Server Type: ${SERVER_TYPE}"
    log "Server ID: ${SERVER_ID}"
    log "Cluster ID: ${CLUSTER_ID}"
    log "Cluster Name: ${CLUSTER_NAME}"
    log "Cloud Provider: ${CLOUD_PROVIDER}"
    log "Prometheus Endpoint: ${PROMETHEUS_ENDPOINT:-not configured}"
    log "Loki Endpoint: ${LOKI_ENDPOINT:-not configured}"
    log "=========================================="

    # Install Node Exporter for Prometheus metrics
    install_node_exporter

    # Install Vector for log aggregation
    install_vector "$LOKI_ENDPOINT" "$SERVER_TYPE" "$SERVER_ID" "$CLOUD_PROVIDER" "$CLUSTER_ID" "$CLUSTER_NAME"

    # Note: Firewall rules are managed at cloud provider level (Hetzner/Contabo)
    # Node Exporter (9100) and Vector (8686) are internal services not exposed publicly
    # Prometheus scrapes Node Exporter via internal cluster network

    # Verify monitoring health after installation
    verify_monitoring_health "$SERVER_TYPE" "$LOKI_ENDPOINT"

    log "=========================================="
    log "✅ Monitoring installation complete"
    log "=========================================="
}

# Verify monitoring stack health
verify_monitoring_health() {
    local SERVER_TYPE="$1"
    local LOKI_ENDPOINT="$2"

    log "=========================================="
    log "Verifying Monitoring Health"
    log "=========================================="

    mkdir -p /var/log/flui/monitoring
    local HEALTH_LOG="/var/log/flui/monitoring/health.json"
    local STATUS="healthy"
    local ISSUES=()

    # Check 1: Node Exporter
    log "Checking Node Exporter..."
    if systemctl is-active --quiet node-exporter; then
        log "  ✓ Node Exporter service is running"

        if curl -f -s -m 3 http://localhost:9100/metrics >/dev/null 2>&1; then
            log "  ✓ Node Exporter metrics endpoint responding"
            local METRICS_COUNT=$(curl -s http://localhost:9100/metrics 2>/dev/null | grep -c "^node_" || echo "0")
            log "  ✓ Exporting $METRICS_COUNT metrics"
        else
            warn "  ✗ Node Exporter metrics endpoint not responding"
            STATUS="degraded"
            ISSUES+=("node_exporter_metrics_unreachable")
        fi
    else
        warn "  ✗ Node Exporter service is NOT running"
        STATUS="unhealthy"
        ISSUES+=("node_exporter_not_running")
    fi

    # Check 2: Vector
    log "Checking Vector..."
    if systemctl is-active --quiet vector; then
        log "  ✓ Vector service is running"

        if curl -f -s -m 3 http://localhost:8686/health >/dev/null 2>&1; then
            log "  ✓ Vector API responding on port 8686"
        else
            warn "  ⚠ Vector API not responding (service may still be starting)"
            ISSUES+=("vector_api_slow_start")
        fi

        # Verify Vector configuration
        if [ -f /etc/vector/vector.toml ]; then
            if [ -n "$LOKI_ENDPOINT" ]; then
                if grep -q "$LOKI_ENDPOINT" /etc/vector/vector.toml; then
                    log "  ✓ Vector configured with Loki endpoint: $LOKI_ENDPOINT"
                else
                    warn "  ✗ Loki endpoint not found in Vector config"
                    STATUS="degraded"
                    ISSUES+=("vector_config_missing_loki")
                fi
            fi
        else
            warn "  ✗ Vector configuration file not found"
            STATUS="unhealthy"
            ISSUES+=("vector_config_missing")
        fi
    else
        warn "  ✗ Vector service is NOT running"
        STATUS="unhealthy"
        ISSUES+=("vector_not_running")
    fi

    # Generate health report JSON
    cat > "$HEALTH_LOG" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "$STATUS",
  "server_type": "$SERVER_TYPE",
  "loki_endpoint": "${LOKI_ENDPOINT:-not_configured}",
  "services": {
    "node_exporter": {
      "running": $(systemctl is-active --quiet node-exporter && echo "true" || echo "false"),
      "metrics_reachable": $(curl -f -s -m 2 http://localhost:9100/metrics >/dev/null 2>&1 && echo "true" || echo "false")
    },
    "vector": {
      "running": $(systemctl is-active --quiet vector && echo "true" || echo "false"),
      "api_reachable": $(curl -f -s -m 2 http://localhost:8686/health >/dev/null 2>&1 && echo "true" || echo "false")
    }
  },
  "issues": [$(IFS=,; echo "${ISSUES[*]}" | sed 's/\([^,]*\)/"\1"/g')]
}
EOF

    log "Health report saved to: $HEALTH_LOG"

    if [ "$STATUS" = "healthy" ]; then
        log "✅ All monitoring services are healthy"
    elif [ "$STATUS" = "degraded" ]; then
        warn "⚠ Monitoring is running but some issues detected"
    else
        warn "✗ Monitoring has critical issues"
    fi

    log "=========================================="
}

# Export functions for use in parent scripts
export -f install_monitoring
export -f install_node_exporter
export -f install_vector
