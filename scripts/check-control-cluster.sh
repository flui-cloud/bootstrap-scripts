#!/bin/bash
# Check Control Cluster Accessibility from Workload Node
# This script verifies network connectivity from a workload cluster node
# to the central control cluster
#
# Usage:
#   ./check-control-cluster.sh [OBSERVABILITY_IP]
#
# If OBSERVABILITY_IP is not provided, script will try to extract it from Vector config

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get control cluster IP from argument or Vector config
OBSERVABILITY_IP="${1:-}"

if [ -z "$OBSERVABILITY_IP" ]; then
    echo "No control cluster IP provided. Checking Vector configuration..."

    if [ -f /etc/vector/vector.toml ]; then
        # Extract IP from Loki endpoint in Vector config
        LOKI_ENDPOINT=$(grep -oP 'endpoint = "http://\K[^"]+' /etc/vector/vector.toml | head -1 || echo "")

        if [ -n "$LOKI_ENDPOINT" ]; then
            OBSERVABILITY_IP=$(echo "$LOKI_ENDPOINT" | cut -d':' -f1)
            echo -e "${GREEN}Found control cluster IP from Vector config: $OBSERVABILITY_IP${NC}"
        else
            echo -e "${RED}ERROR: Could not extract control cluster IP from Vector config${NC}"
            echo "Usage: $0 <control-cluster-ip>"
            exit 1
        fi
    else
        echo -e "${RED}ERROR: Vector config not found and no IP provided${NC}"
        echo "Usage: $0 <control-cluster-ip>"
        exit 1
    fi
fi

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Control Cluster Connectivity Test${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Target: $OBSERVABILITY_IP"
echo "From: $(hostname) ($(hostname -I | awk '{print $1}'))"
echo "Timestamp: $(date)"
echo ""

OVERALL_RESULT="pass"
ISSUES=()

#================================================#
# 1. DNS/IP Resolution
#================================================#
echo -e "${BLUE}[1/6]${NC} Checking IP address resolution..."

if [[ "$OBSERVABILITY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${GREEN}✓${NC} Valid IP address: $OBSERVABILITY_IP"
else
    # Might be a hostname, try to resolve
    if RESOLVED_IP=$(host "$OBSERVABILITY_IP" 2>/dev/null | grep "has address" | awk '{print $4}' | head -1); then
        echo -e "${GREEN}✓${NC} Hostname resolved: $OBSERVABILITY_IP -> $RESOLVED_IP"
        OBSERVABILITY_IP="$RESOLVED_IP"
    else
        echo -e "${RED}✗${NC} Failed to resolve hostname: $OBSERVABILITY_IP"
        OVERALL_RESULT="fail"
        ISSUES+=("dns_resolution_failed")
    fi
fi

#================================================#
# 2. ICMP Ping Test
#================================================#
echo -e "${BLUE}[2/6]${NC} Testing ICMP connectivity (ping)..."

if ping -c 3 -W 5 "$OBSERVABILITY_IP" >/dev/null 2>&1; then
    # Calculate average latency
    AVG_LATENCY=$(ping -c 3 -W 5 "$OBSERVABILITY_IP" 2>/dev/null | tail -1 | awk -F '/' '{print $5}' || echo "N/A")
    echo -e "${GREEN}✓${NC} Host is reachable via ping (avg latency: ${AVG_LATENCY}ms)"
else
    echo -e "${YELLOW}⚠${NC} Host not responding to ping (ICMP may be blocked by firewall)"
    echo "  This is not critical - TCP connectivity is more important"
fi

#================================================#
# 3. Loki Port (30100) TCP Test
#================================================#
echo -e "${BLUE}[3/6]${NC} Testing Loki port (30100) connectivity..."

if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$OBSERVABILITY_IP/30100" 2>/dev/null; then
    echo -e "${GREEN}✓${NC} Port 30100 (Loki) is open and reachable"

    # Measure TCP handshake latency
    START_TIME=$(date +%s%N)
    timeout 3 bash -c "cat < /dev/null > /dev/tcp/$OBSERVABILITY_IP/30100" 2>/dev/null
    END_TIME=$(date +%s%N)
    LATENCY_MS=$(( (END_TIME - START_TIME) / 1000000 ))
    echo "  TCP connection latency: ${LATENCY_MS}ms"
else
    echo -e "${RED}✗${NC} Port 30100 (Loki) is NOT reachable"
    echo "  This means logs will NOT be forwarded to the control cluster"
    OVERALL_RESULT="fail"
    ISSUES+=("loki_port_unreachable")
fi

#================================================#
# 4. Prometheus Port (30090) TCP Test
#================================================#
echo -e "${BLUE}[4/6]${NC} Testing Prometheus port (30090) connectivity..."

if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$OBSERVABILITY_IP/30090" 2>/dev/null; then
    echo -e "${GREEN}✓${NC} Port 30090 (Prometheus) is open and reachable"
else
    echo -e "${YELLOW}⚠${NC} Port 30090 (Prometheus) is NOT reachable"
    echo "  This may affect metrics scraping from the control cluster"
    ISSUES+=("prometheus_port_unreachable")
fi

#================================================#
# 5. Loki HTTP Health Check
#================================================#
echo -e "${BLUE}[5/6]${NC} Testing Loki HTTP health endpoint..."

LOKI_HEALTH_URL="http://${OBSERVABILITY_IP}:30100/ready"

if command -v curl &>/dev/null; then
    if curl -f -s -m 5 "$LOKI_HEALTH_URL" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Loki health endpoint responding at $LOKI_HEALTH_URL"
    else
        echo -e "${YELLOW}⚠${NC} Loki health endpoint not responding"
        echo "  Endpoint: $LOKI_HEALTH_URL"
        echo "  Loki may not support /ready endpoint, or may be starting up"
    fi
else
    echo -e "${YELLOW}⚠${NC} curl not available - skipping HTTP test"
fi

#================================================#
# 6. Test Loki Log Push
#================================================#
echo -e "${BLUE}[6/6]${NC} Testing Loki log push API..."

if command -v curl &>/dev/null; then
    LOKI_PUSH_URL="http://${OBSERVABILITY_IP}:30100/loki/api/v1/push"

    TEST_PAYLOAD=$(cat <<EOF
{
  "streams": [
    {
      "stream": {
        "hostname": "$(hostname)",
        "source": "connectivity-test",
        "test": "true"
      },
      "values": [
        ["$(date +%s)000000000", "Connectivity test from $(hostname) at $(date)"]
      ]
    }
  ]
}
EOF
)

    if curl -f -s -X POST -H "Content-Type: application/json" -d "$TEST_PAYLOAD" "$LOKI_PUSH_URL" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Successfully sent test log to Loki"
        echo "  Endpoint: $LOKI_PUSH_URL"
    else
        echo -e "${RED}✗${NC} Failed to send test log to Loki"
        echo "  Endpoint: $LOKI_PUSH_URL"
        echo "  This indicates that log forwarding will fail"
        OVERALL_RESULT="fail"
        ISSUES+=("loki_push_failed")
    fi
else
    echo -e "${YELLOW}⚠${NC} curl not available - skipping log push test"
fi

#================================================#
# 7. Route and Network Info
#================================================#
echo ""
echo -e "${BLUE}Network Information:${NC}"
echo ""

# Show route to control cluster
if command -v ip &>/dev/null; then
    echo "Route to $OBSERVABILITY_IP:"
    ip route get "$OBSERVABILITY_IP" 2>/dev/null || echo "  Unable to determine route"
fi

# Show active network interfaces
echo ""
echo "Active network interfaces:"
ip addr show | grep -E "^[0-9]+:|inet " | grep -v "127.0.0.1" || echo "  No interfaces found"

#================================================#
# 8. Summary
#================================================#
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

if [ "$OVERALL_RESULT" = "pass" ]; then
    echo -e "${GREEN}✅ PASS${NC} - Control cluster is fully reachable"
    echo ""
    echo "All connectivity tests passed. Logs should be forwarding correctly."
    exit 0
else
    echo -e "${RED}❌ FAIL${NC} - Connectivity issues detected"
    echo ""
    echo "Issues found:"
    for issue in "${ISSUES[@]}"; do
        echo "  - $issue"
    done
    echo ""
    echo "Troubleshooting steps:"
    echo "  1. Check firewall rules on control cluster"
    echo "     - Ensure port 30100 (Loki) is open for incoming traffic"
    echo "     - Ensure port 30090 (Prometheus) is open for incoming traffic"
    echo ""
    echo "  2. Check if control cluster is running:"
    echo "     ssh <observability-node> 'systemctl status k3s'"
    echo ""
    echo "  3. Verify Loki is running on control cluster:"
    echo "     ssh <observability-node> 'kubectl get pods -A | grep loki'"
    echo ""
    echo "  4. Check network connectivity:"
    echo "     traceroute $OBSERVABILITY_IP"
    echo "     mtr $OBSERVABILITY_IP"
    echo ""
    echo "  5. Check firewall on this node (workload cluster):"
    echo "     sudo iptables -L -n"
    exit 1
fi
