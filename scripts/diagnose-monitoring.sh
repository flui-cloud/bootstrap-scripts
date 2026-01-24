#!/bin/bash
# Flui Monitoring Stack Diagnostics
# This script diagnoses the monitoring stack (node-exporter and vector)
# on Flui-managed K3s nodes
#
# Usage:
#   ./diagnose-monitoring.sh [OPTIONS]
#
# Options:
#   --json          Output in JSON format for parsing
#   --verbose       Show detailed logs
#   --test-loki     Test sending logs to Loki
#   --fix           Attempt to restart failed services
#   --help          Show this help message

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse command line options
JSON_OUTPUT=false
VERBOSE=false
TEST_LOKI=false
AUTO_FIX=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --test-loki)
            TEST_LOKI=true
            shift
            ;;
        --fix)
            AUTO_FIX=true
            shift
            ;;
        --help)
            head -n 15 "$0" | tail -n 13
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Logging functions
log_info() {
    if [ "$JSON_OUTPUT" = false ]; then
        echo -e "${GREEN}✓${NC} $1"
    fi
}

log_warn() {
    if [ "$JSON_OUTPUT" = false ]; then
        echo -e "${YELLOW}⚠${NC} $1"
    fi
}

log_error() {
    if [ "$JSON_OUTPUT" = false ]; then
        echo -e "${RED}✗${NC} $1"
    fi
}

log_section() {
    if [ "$JSON_OUTPUT" = false ]; then
        echo ""
        echo -e "${BLUE}========================================${NC}"
        echo -e "${BLUE}$1${NC}"
        echo -e "${BLUE}========================================${NC}"
    fi
}

# Initialize result variables
OVERALL_STATUS="healthy"
ISSUES=()
NODE_EXPORTER_RUNNING=false
NODE_EXPORTER_REACHABLE=false
VECTOR_RUNNING=false
VECTOR_API_REACHABLE=false
LOKI_ENDPOINT=""
OBS_CLUSTER_REACHABLE=false

#================================================#
# 1. SYSTEM INFORMATION
#================================================#
log_section "System Information"

HOSTNAME=$(hostname)
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

log_info "Hostname: $HOSTNAME"
log_info "Timestamp: $TIMESTAMP"
log_info "User: $(whoami)"

#================================================#
# 2. CHECK NODE EXPORTER
#================================================#
log_section "Node Exporter Status"

if systemctl is-active --quiet node-exporter; then
    NODE_EXPORTER_RUNNING=true
    log_info "Node Exporter service is running"

    # Check metrics endpoint
    if curl -f -s -m 3 http://localhost:9100/metrics >/dev/null 2>&1; then
        NODE_EXPORTER_REACHABLE=true
        METRICS_COUNT=$(curl -s http://localhost:9100/metrics 2>/dev/null | grep -c "^node_" || echo "0")
        log_info "Metrics endpoint responding (${METRICS_COUNT} metrics)"

        if [ "$VERBOSE" = true ] && [ "$JSON_OUTPUT" = false ]; then
            echo "Sample metrics (first 5):"
            curl -s http://localhost:9100/metrics 2>/dev/null | grep "^node_" | head -5
        fi
    else
        NODE_EXPORTER_REACHABLE=false
        log_error "Metrics endpoint NOT responding on port 9100"
        OVERALL_STATUS="degraded"
        ISSUES+=("node_exporter_endpoint_unreachable")
    fi

    # Show service status
    if [ "$VERBOSE" = true ] && [ "$JSON_OUTPUT" = false ]; then
        echo "Service status:"
        systemctl status node-exporter --no-pager | head -10
    fi
else
    NODE_EXPORTER_RUNNING=false
    log_error "Node Exporter service is NOT running"
    OVERALL_STATUS="unhealthy"
    ISSUES+=("node_exporter_not_running")

    if [ "$VERBOSE" = true ] && [ "$JSON_OUTPUT" = false ]; then
        echo "Last 20 log lines:"
        journalctl -u node-exporter -n 20 --no-pager
    fi

    # Auto-fix if requested
    if [ "$AUTO_FIX" = true ]; then
        log_warn "Attempting to restart node-exporter..."
        if sudo systemctl restart node-exporter; then
            log_info "Node Exporter restarted successfully"
            sleep 2
            if systemctl is-active --quiet node-exporter; then
                NODE_EXPORTER_RUNNING=true
                log_info "Node Exporter is now running"
            fi
        fi
    fi
fi

# Check installation log
if [ -f /var/log/flui/node-exporter/install.log ]; then
    log_info "Installation log found: /var/log/flui/node-exporter/install.log"
    if [ "$VERBOSE" = true ] && [ "$JSON_OUTPUT" = false ]; then
        echo "Last 10 lines of installation log:"
        tail -10 /var/log/flui/node-exporter/install.log
    fi
else
    log_warn "Installation log not found (expected at /var/log/flui/node-exporter/install.log)"
fi

#================================================#
# 3. CHECK VECTOR
#================================================#
log_section "Vector Status"

if systemctl is-active --quiet vector; then
    VECTOR_RUNNING=true
    log_info "Vector service is running"

    # Check API endpoint
    if curl -f -s -m 3 http://localhost:8686/health >/dev/null 2>&1; then
        VECTOR_API_REACHABLE=true
        log_info "Vector API responding on port 8686"

        if [ "$VERBOSE" = true ] && [ "$JSON_OUTPUT" = false ]; then
            echo "Vector health response:"
            curl -s http://localhost:8686/health 2>/dev/null || echo "Failed to get health"
        fi
    else
        VECTOR_API_REACHABLE=false
        log_warn "Vector API NOT responding (service may still be starting)"
        ISSUES+=("vector_api_unreachable")
    fi

    # Check service status
    if [ "$VERBOSE" = true ] && [ "$JSON_OUTPUT" = false ]; then
        echo "Service status:"
        systemctl status vector --no-pager | head -10
    fi
else
    VECTOR_RUNNING=false
    log_error "Vector service is NOT running"
    OVERALL_STATUS="unhealthy"
    ISSUES+=("vector_not_running")

    if [ "$VERBOSE" = true ] && [ "$JSON_OUTPUT" = false ]; then
        echo "Last 20 log lines:"
        journalctl -u vector -n 20 --no-pager
    fi

    # Auto-fix if requested
    if [ "$AUTO_FIX" = true ]; then
        log_warn "Attempting to restart vector..."
        if sudo systemctl restart vector; then
            log_info "Vector restarted successfully"
            sleep 2
            if systemctl is-active --quiet vector; then
                VECTOR_RUNNING=true
                log_info "Vector is now running"
            fi
        fi
    fi
fi

# Check Vector configuration
if [ -f /etc/vector/vector.toml ]; then
    log_info "Vector configuration found: /etc/vector/vector.toml"

    # Extract Loki endpoint from config
    LOKI_ENDPOINT=$(grep -oP 'endpoint = "http://\K[^"]+' /etc/vector/vector.toml | head -1 || echo "")

    if [ -n "$LOKI_ENDPOINT" ]; then
        log_info "Loki endpoint configured: $LOKI_ENDPOINT"
    else
        log_warn "Loki endpoint not found in Vector config"
        ISSUES+=("vector_no_loki_endpoint")
    fi

    if [ "$VERBOSE" = true ] && [ "$JSON_OUTPUT" = false ]; then
        echo "Vector configuration (Loki sink):"
        grep -A 5 "\[sinks.loki\]" /etc/vector/vector.toml || echo "Loki sink not found"
    fi
else
    log_error "Vector configuration NOT found at /etc/vector/vector.toml"
    OVERALL_STATUS="unhealthy"
    ISSUES+=("vector_config_missing")
fi

# Check installation log
if [ -f /var/log/flui/vector/install.log ]; then
    log_info "Installation log found: /var/log/flui/vector/install.log"
    if [ "$VERBOSE" = true ] && [ "$JSON_OUTPUT" = false ]; then
        echo "Last 10 lines of installation log:"
        tail -10 /var/log/flui/vector/install.log
    fi
else
    log_warn "Installation log not found (expected at /var/log/flui/vector/install.log)"
fi

#================================================#
# 4. CHECK OBSERVABILITY CLUSTER CONNECTIVITY
#================================================#
if [ -n "$LOKI_ENDPOINT" ] && [[ "$LOKI_ENDPOINT" != *"localhost"* ]] && [[ "$LOKI_ENDPOINT" != *"127.0.0.1"* ]]; then
    log_section "Observability Cluster Connectivity"

    OBS_HOST=$(echo "$LOKI_ENDPOINT" | cut -d':' -f1)
    OBS_PORT=$(echo "$LOKI_ENDPOINT" | cut -d':' -f2)

    log_info "Testing connection to observability cluster: $OBS_HOST:$OBS_PORT"

    # Ping test
    if ping -c 2 -W 3 "$OBS_HOST" >/dev/null 2>&1; then
        log_info "Observability cluster host is reachable (ping)"
    else
        log_warn "Observability cluster not responding to ping (may be blocked)"
    fi

    # TCP connection test
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$OBS_HOST/$OBS_PORT" 2>/dev/null; then
        OBS_CLUSTER_REACHABLE=true
        log_info "Loki port $OBS_PORT is reachable"

        # Measure latency
        START_TIME=$(date +%s%N 2>/dev/null || echo "0")
        if timeout 3 bash -c "cat < /dev/null > /dev/tcp/$OBS_HOST/$OBS_PORT" 2>/dev/null; then
            END_TIME=$(date +%s%N 2>/dev/null || echo "$START_TIME")
            if [ "$START_TIME" != "0" ] && [ "$END_TIME" != "$START_TIME" ]; then
                LATENCY_MS=$(( (END_TIME - START_TIME) / 1000000 ))
                log_info "Network latency: ${LATENCY_MS}ms"
            fi
        fi
    else
        OBS_CLUSTER_REACHABLE=false
        log_error "Loki port $OBS_PORT is NOT reachable"
        log_error "Check firewall rules on observability cluster"
        OVERALL_STATUS="degraded"
        ISSUES+=("observability_cluster_unreachable")
    fi

    # Test Loki health endpoint
    LOKI_HEALTH_URL="http://${LOKI_ENDPOINT}/ready"
    if curl -f -s -m 3 "$LOKI_HEALTH_URL" >/dev/null 2>&1; then
        log_info "Loki health endpoint responding"
    else
        log_warn "Loki health endpoint not responding (may not support /ready)"
    fi

    # Test log sending if requested
    if [ "$TEST_LOKI" = true ]; then
        log_section "Testing Log Sending to Loki"

        TEST_LOG_PAYLOAD=$(cat <<EOF
{
  "streams": [
    {
      "stream": {
        "hostname": "$HOSTNAME",
        "source": "diagnose-monitoring",
        "test": "true"
      },
      "values": [
        ["$(date +%s)000000000", "Test log from diagnose-monitoring.sh at $(date)"]
      ]
    }
  ]
}
EOF
)

        LOKI_PUSH_URL="http://${LOKI_ENDPOINT}/loki/api/v1/push"
        if curl -f -s -X POST -H "Content-Type: application/json" -d "$TEST_LOG_PAYLOAD" "$LOKI_PUSH_URL" 2>/dev/null; then
            log_info "Successfully sent test log to Loki"
        else
            log_error "Failed to send test log to Loki"
            ISSUES+=("loki_push_failed")
        fi
    fi
fi

#================================================#
# 5. CHECK MONITORING HEALTH REPORT
#================================================#
if [ -f /var/log/flui/monitoring/health.json ]; then
    log_section "Last Health Report"

    if [ "$JSON_OUTPUT" = false ]; then
        cat /var/log/flui/monitoring/health.json | grep -v "^$" | head -20
    fi
else
    log_warn "Health report not found (expected at /var/log/flui/monitoring/health.json)"
fi

#================================================#
# 6. OUTPUT RESULTS
#================================================#
if [ "$JSON_OUTPUT" = true ]; then
    # JSON output for parsing
    cat <<EOF
{
  "timestamp": "$TIMESTAMP",
  "hostname": "$HOSTNAME",
  "overall_status": "$OVERALL_STATUS",
  "node_exporter": {
    "running": $NODE_EXPORTER_RUNNING,
    "metrics_reachable": $NODE_EXPORTER_REACHABLE
  },
  "vector": {
    "running": $VECTOR_RUNNING,
    "api_reachable": $VECTOR_API_REACHABLE,
    "loki_endpoint": "$LOKI_ENDPOINT"
  },
  "observability_cluster": {
    "configured": $([ -n "$LOKI_ENDPOINT" ] && echo "true" || echo "false"),
    "reachable": $OBS_CLUSTER_REACHABLE
  },
  "issues": [$(IFS=,; echo "${ISSUES[*]}" | sed 's/\([^,]*\)/"\1"/g')]
}
EOF
else
    # Human-readable summary
    log_section "Summary"

    if [ "$OVERALL_STATUS" = "healthy" ]; then
        echo -e "${GREEN}✅ Overall Status: HEALTHY${NC}"
        echo "All monitoring services are working correctly."
    elif [ "$OVERALL_STATUS" = "degraded" ]; then
        echo -e "${YELLOW}⚠ Overall Status: DEGRADED${NC}"
        echo "Monitoring is running but some issues were detected:"
        for issue in "${ISSUES[@]}"; do
            echo "  - $issue"
        done
    else
        echo -e "${RED}✗ Overall Status: UNHEALTHY${NC}"
        echo "Critical issues detected with monitoring services:"
        for issue in "${ISSUES[@]}"; do
            echo "  - $issue"
        done
    fi

    echo ""
    echo "Quick diagnostics commands:"
    echo "  journalctl -u node-exporter -f     # Follow node-exporter logs"
    echo "  journalctl -u vector -f            # Follow vector logs"
    echo "  curl http://localhost:9100/metrics # Check metrics endpoint"
    echo "  curl http://localhost:8686/health  # Check Vector API"
    echo "  systemctl status node-exporter     # Service status"
    echo "  systemctl status vector            # Service status"
    echo ""
    echo "Log files:"
    echo "  /var/log/flui/node-exporter/install.log"
    echo "  /var/log/flui/vector/install.log"
    echo "  /var/log/flui/monitoring/health.json"
fi

# Exit code based on status
if [ "$OVERALL_STATUS" = "healthy" ]; then
    exit 0
elif [ "$OVERALL_STATUS" = "degraded" ]; then
    exit 1
else
    exit 2
fi
