#!/bin/bash
# Vector Log Aggregation Module
# Extracted from flui-init.sh for reusability across all server types
# Version: 0.34.1
# Supports dynamic Loki endpoint configuration with enhanced logging

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

# Test connectivity to Loki endpoint
test_loki_connectivity() {
    local LOKI_ENDPOINT="$1"
    local LOG_FILE="$2"

    echo "Testing connectivity to Loki endpoint: $LOKI_ENDPOINT" >> "$LOG_FILE"
    echo "Starting connectivity test at $(date)" >> "$LOG_FILE"

    # Parse host and port
    local LOKI_HOST=$(echo "$LOKI_ENDPOINT" | cut -d':' -f1)
    local LOKI_PORT=$(echo "$LOKI_ENDPOINT" | cut -d':' -f2)

    echo "Parsed: LOKI_HOST=$LOKI_HOST, LOKI_PORT=$LOKI_PORT" >> "$LOG_FILE"

    # Test 1: Ping host (optional, may fail if ICMP blocked)
    echo "Test 1/4: Starting ping test..." >> "$LOG_FILE"
    if timeout 3 ping -c 1 -W 2 "$LOKI_HOST" &>/dev/null; then
        echo "  ✓ Host $LOKI_HOST is reachable (ping)" >> "$LOG_FILE"
    else
        echo "  ⚠ Host $LOKI_HOST not responding to ping (may be blocked)" >> "$LOG_FILE"
    fi
    echo "Test 1/4: Ping test completed" >> "$LOG_FILE"

    # Test 2: TCP connection to Loki port
    echo "Test 2/4: Starting TCP connection test..." >> "$LOG_FILE"
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$LOKI_HOST/$LOKI_PORT" 2>/dev/null; then
        echo "  ✓ Port $LOKI_PORT is open on $LOKI_HOST" >> "$LOG_FILE"
    else
        echo "  ✗ Port $LOKI_PORT is NOT reachable on $LOKI_HOST" >> "$LOG_FILE"
        warn "Loki endpoint $LOKI_ENDPOINT is not reachable - logs may not be forwarded"
        # NON facciamo return 1 qui - continuiamo comunque
    fi
    echo "Test 2/4: TCP connection test completed" >> "$LOG_FILE"

    # Test 3: HTTP health check (if Loki has health endpoint)
    echo "Test 3/4: Starting HTTP health check..." >> "$LOG_FILE"
    local HEALTH_URL="http://${LOKI_ENDPOINT}/ready"
    if timeout 5 curl -f -s -m 3 "$HEALTH_URL" &>/dev/null; then
        echo "  ✓ Loki health endpoint responding at $HEALTH_URL" >> "$LOG_FILE"
    else
        echo "  ⚠ Loki health endpoint not responding (endpoint may not support /ready)" >> "$LOG_FILE"
    fi
    echo "Test 3/4: HTTP health check completed" >> "$LOG_FILE"

    # Test 4: Measure latency
    echo "Test 4/4: Starting latency measurement..." >> "$LOG_FILE"
    local START_TIME=$(date +%s%N 2>/dev/null || echo "0")
    if [ "$START_TIME" != "0" ]; then
        if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$LOKI_HOST/$LOKI_PORT" 2>/dev/null; then
            local END_TIME=$(date +%s%N 2>/dev/null || echo "$START_TIME")
            if [ "$END_TIME" != "$START_TIME" ]; then
                local LATENCY_MS=$(( (END_TIME - START_TIME) / 1000000 ))
                echo "  ✓ Network latency to Loki: ${LATENCY_MS}ms" >> "$LOG_FILE"
            fi
        fi
    else
        echo "  ⚠ nanosecond date not supported, skipping latency test" >> "$LOG_FILE"
    fi
    echo "Test 4/4: Latency measurement completed" >> "$LOG_FILE"

    echo "Connectivity test completed at $(date)" >> "$LOG_FILE"
    # Ritorniamo sempre 0 per non bloccare l'installazione
    return 0
}

# Export function so it can be called from within timeout
export -f test_loki_connectivity

install_vector() {
    local LOKI_ENDPOINT="${1:-}"
    local SERVER_TYPE="${2:-generic}"
    local SERVER_ID="${3:-unknown}"
    local CLOUD_PROVIDER="${4:-unknown}"
    local CLUSTER_ID="${5:-unknown}"
    local CLUSTER_NAME="${6:-unknown}"

    # Create log directory for Vector installation
    mkdir -p /var/log/flui/vector
    local INSTALL_LOG="/var/log/flui/vector/install.log"

    log "Installing Vector v0.34.1..."
    log "Configuration: SERVER_TYPE=${SERVER_TYPE}, SERVER_ID=${SERVER_ID}, CLUSTER_ID=${CLUSTER_ID}, CLUSTER_NAME=${CLUSTER_NAME}, LOKI_ENDPOINT=${LOKI_ENDPOINT}"

    # Log to dedicated file
    {
        echo "=== Vector Installation Started ==="
        echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Server Type: ${SERVER_TYPE}"
        echo "Server ID: ${SERVER_ID}"
        echo "Cluster ID: ${CLUSTER_ID}"
        echo "Cluster Name: ${CLUSTER_NAME}"
        echo "Cloud Provider: ${CLOUD_PROVIDER}"
        echo "Loki Endpoint: ${LOKI_ENDPOINT:-not configured}"
        echo "=================================="
    } >> "$INSTALL_LOG"

    # Download and install Vector
    cd /tmp
    echo "Downloading Vector..." >> "$INSTALL_LOG"

    if wget -q https://packages.timber.io/vector/0.34.1/vector-0.34.1-x86_64-unknown-linux-musl.tar.gz 2>> "$INSTALL_LOG"; then
        echo "✓ Vector downloaded successfully" >> "$INSTALL_LOG"
    else
        echo "✗ Failed to download Vector" >> "$INSTALL_LOG"
        error "Failed to download Vector - check $INSTALL_LOG"
    fi

    tar xzf vector-0.34.1-x86_64-unknown-linux-musl.tar.gz 2>> "$INSTALL_LOG"
    cp vector-x86_64-unknown-linux-musl/bin/vector /usr/local/bin/
    chmod +x /usr/local/bin/vector
    rm -rf vector-*

    echo "✓ Vector binary installed to /usr/local/bin/vector" >> "$INSTALL_LOG"

    # Create required directories
    mkdir -p /etc/vector
    mkdir -p /var/lib/vector
    mkdir -p /var/log/vector
    mkdir -p /var/log/flui

    # Generate Vector configuration with conditional Loki sink
    if [ -n "$LOKI_ENDPOINT" ]; then
        log "Configuring Vector with Loki endpoint: $LOKI_ENDPOINT"
        echo "Configuring Vector with Loki endpoint: $LOKI_ENDPOINT" >> "$INSTALL_LOG"

        # Test connectivity to Loki endpoint BEFORE configuring
        # WRAPPED con timeout globale e gestione errori per evitare blocchi
        echo "About to start connectivity test..." >> "$INSTALL_LOG"
        if timeout 30 bash -c "test_loki_connectivity '$LOKI_ENDPOINT' '$INSTALL_LOG'"; then
            echo "✓ Connectivity test completed successfully" >> "$INSTALL_LOG"
        else
            warn "Connectivity test failed or timed out, but continuing installation"
            echo "⚠ Connectivity test failed or timed out (exit code: $?), continuing anyway" >> "$INSTALL_LOG"
        fi
        echo "Connectivity test phase finished, proceeding with configuration..." >> "$INSTALL_LOG"

        cat > /etc/vector/vector.toml << 'EOF'
# Global configuration
data_dir = "/var/lib/vector"

# API interna per health checks
[api]
enabled = true
address = "0.0.0.0:8686"

# Source: journald logs
[sources.journald]
type = "journald"
current_boot_only = false

# Source: syslog files
[sources.syslog]
type = "file"
include = ["/var/log/syslog", "/var/log/kern.log", "/var/log/auth.log"]
read_from = "end"

# Source: flui/k3s init logs
[sources.flui_init_logs]
type = "file"
include = [
  "/var/log/flui-init.log",
  "/var/log/k3s-master-init.log",
  "/var/log/k3s-worker-init.log",
  "/var/log/k3s-install.log",
  "/var/log/cloud-init.log",
  "/var/log/cloud-init-output.log"
]
read_from = "beginning"

# Source: flui application logs
[sources.flui_logs]
type = "file"
include = ["/home/flui/logs/*.log", "/var/log/flui/*.log"]
read_from = "end"

# Transform: enrich journald logs
[transforms.enrich_journald]
type = "remap"
inputs = ["journald"]
source = '''
.hostname = get_hostname!()
.server_type = "SERVER_TYPE_PLACEHOLDER"
.server_id = "SERVER_ID_PLACEHOLDER"
.cluster_id = "CLUSTER_ID_PLACEHOLDER"
.cluster_name = "CLUSTER_NAME_PLACEHOLDER"
.cloud_provider = "CLOUD_PROVIDER_PLACEHOLDER"
.cluster_type = "CLUSTER_TYPE_PLACEHOLDER"
.source_type = "journald"
.filename = "journald"

# Extract service name from journald metadata (SYSLOG_IDENTIFIER or _SYSTEMD_UNIT)
.service = .SYSLOG_IDENTIFIER
if is_null(.service) { .service = .UNIT }
if is_null(.service) { .service = "unknown" }
'''

# Transform: enrich syslog files
[transforms.enrich_syslog]
type = "remap"
inputs = ["syslog"]
source = '''
.hostname = get_hostname!()
.server_type = "SERVER_TYPE_PLACEHOLDER"
.server_id = "SERVER_ID_PLACEHOLDER"
.cluster_id = "CLUSTER_ID_PLACEHOLDER"
.cluster_name = "CLUSTER_NAME_PLACEHOLDER"
.cloud_provider = "CLOUD_PROVIDER_PLACEHOLDER"
.cluster_type = "CLUSTER_TYPE_PLACEHOLDER"
.source_type = "syslog"
.filename = replace(to_string!(.file), r'^.*/', "")

# For syslog, service is derived from filename (e.g., "syslog", "kern.log", "auth.log")
.service = replace(.filename, r'\.log$', "")
'''

# Transform: enrich init logs
[transforms.enrich_flui_init]
type = "remap"
inputs = ["flui_init_logs"]
source = '''
.hostname = get_hostname!()
.server_type = "SERVER_TYPE_PLACEHOLDER"
.server_id = "SERVER_ID_PLACEHOLDER"
.cluster_id = "CLUSTER_ID_PLACEHOLDER"
.cluster_name = "CLUSTER_NAME_PLACEHOLDER"
.cloud_provider = "CLOUD_PROVIDER_PLACEHOLDER"
.cluster_type = "CLUSTER_TYPE_PLACEHOLDER"
.source_type = "init"
.filename = replace(to_string!(.file), r'^.*/', "")

# Service is the init script name (e.g., "flui-init", "k3s-master-init")
.service = replace(.filename, r'\.log$', "")
'''

# Transform: enrich application logs
[transforms.enrich_flui_logs]
type = "remap"
inputs = ["flui_logs"]
source = '''
.hostname = get_hostname!()
.server_type = "SERVER_TYPE_PLACEHOLDER"
.server_id = "SERVER_ID_PLACEHOLDER"
.cluster_id = "CLUSTER_ID_PLACEHOLDER"
.cluster_name = "CLUSTER_NAME_PLACEHOLDER"
.cloud_provider = "CLOUD_PROVIDER_PLACEHOLDER"
.cluster_type = "CLUSTER_TYPE_PLACEHOLDER"
.source_type = "application"
.filename = replace(to_string!(.file), r'^.*/', "")

# Service is the application log file name
.service = replace(.filename, r'\.log$', "")
'''

# Sink: Loki
[sinks.loki]
type = "loki"
inputs = ["enrich_journald", "enrich_syslog", "enrich_flui_init", "enrich_flui_logs"]
endpoint = "http://LOKI_ENDPOINT_PLACEHOLDER"
encoding.codec = "json"
labels.cluster_id = "{{ cluster_id }}"
labels.cluster_name = "{{ cluster_name }}"
labels.server_id = "{{ server_id }}"
labels.hostname = "{{ hostname }}"
labels.service = "{{ service }}"
labels.server_type = "{{ server_type }}"
labels.cluster_type = "{{ cluster_type }}"
labels.cloud_provider = "{{ cloud_provider }}"
labels.source_type = "{{ source_type }}"
labels.filename = "{{ filename }}"

# Sink: File backup
[sinks.file_backup]
type = "file"
inputs = ["enrich_journald", "enrich_syslog", "enrich_flui_init", "enrich_flui_logs"]
path = "/var/log/vector/flui-%Y-%m-%d.log"
encoding.codec = "json"
compression = "gzip"

# DEBUG Sink: Human-readable debug output with all fields
[sinks.debug_console]
type = "file"
inputs = ["enrich_journald"]
path = "/var/log/vector/debug-enriched.log"
encoding.codec = "json"
# Sample only 1% of logs to avoid flooding
[sinks.debug_console.buffer]
max_events = 100
EOF

        # Replace placeholders with actual values
        sed -i "s|SERVER_TYPE_PLACEHOLDER|${SERVER_TYPE}|g" /etc/vector/vector.toml
        sed -i "s|SERVER_ID_PLACEHOLDER|${SERVER_ID}|g" /etc/vector/vector.toml
        sed -i "s|CLUSTER_ID_PLACEHOLDER|${CLUSTER_ID}|g" /etc/vector/vector.toml
        sed -i "s|CLUSTER_NAME_PLACEHOLDER|${CLUSTER_NAME}|g" /etc/vector/vector.toml
        sed -i "s|CLOUD_PROVIDER_PLACEHOLDER|${CLOUD_PROVIDER}|g" /etc/vector/vector.toml
        sed -i "s|LOKI_ENDPOINT_PLACEHOLDER|${LOKI_ENDPOINT}|g" /etc/vector/vector.toml

        # Set cluster_type based on server_type
        if [[ "$SERVER_TYPE" == "k3s-master" ]] && [[ "$LOKI_ENDPOINT" == *"localhost"* || "$LOKI_ENDPOINT" == *"127.0.0.1"* ]]; then
            sed -i "s|CLUSTER_TYPE_PLACEHOLDER|observability|g" /etc/vector/vector.toml
        else
            sed -i "s|CLUSTER_TYPE_PLACEHOLDER|workload|g" /etc/vector/vector.toml
        fi
    else
        log "Configuring Vector without Loki (file output only)"
        cat > /etc/vector/vector.toml << 'EOF'
# API interna per health checks
[api]
enabled = true
address = "0.0.0.0:8686"

# Source: journald logs
[sources.journald]
type = "journald"
current_boot_only = false

# Source: syslog files
[sources.syslog]
type = "file"
include = ["/var/log/syslog", "/var/log/kern.log", "/var/log/auth.log"]
read_from = "end"

# Transform: enrich all logs
[transforms.enrich]
type = "remap"
inputs = ["journald", "syslog"]
source = '''
.hostname = get_hostname!()
.server_type = "SERVER_TYPE_PLACEHOLDER"
.server_id = "SERVER_ID_PLACEHOLDER"
.cluster_id = "CLUSTER_ID_PLACEHOLDER"
.cloud_provider = "CLOUD_PROVIDER_PLACEHOLDER"
'''

# Sink: Console output
[sinks.console]
type = "console"
inputs = ["enrich"]
encoding.codec = "json"

# Sink: File output
[sinks.file_output]
type = "file"
inputs = ["enrich"]
path = "/var/log/vector/flui-%Y-%m-%d.log"
encoding.codec = "json"
compression = "gzip"
EOF

        # Replace placeholders
        sed -i "s|SERVER_TYPE_PLACEHOLDER|${SERVER_TYPE}|g" /etc/vector/vector.toml
        sed -i "s|SERVER_ID_PLACEHOLDER|${SERVER_ID}|g" /etc/vector/vector.toml
        sed -i "s|CLUSTER_ID_PLACEHOLDER|${CLUSTER_ID}|g" /etc/vector/vector.toml
        sed -i "s|CLOUD_PROVIDER_PLACEHOLDER|${CLOUD_PROVIDER}|g" /etc/vector/vector.toml
    fi

    # Create systemd service
    cat > /etc/systemd/system/vector.service << 'EOF'
[Unit]
Description=Vector Log Aggregator
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/vector --config /etc/vector/vector.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    if ! systemctl enable vector; then
        error "Failed to enable Vector service"
    fi

    if ! systemctl start vector; then
        error "Failed to start Vector service"
    fi

    sleep 3

    # Enhanced health check with detailed logging
    echo "=== Vector Health Check ===" >> "$INSTALL_LOG"
    if curl -f http://localhost:8686/health &>/dev/null; then
        log "✅ Vector installed and responding on port 8686"
        echo "✓ Vector API health check passed" >> "$INSTALL_LOG"

        # Get Vector version and config info
        if command -v vector &>/dev/null; then
            INSTALLED_VECTOR_VERSION=$(vector --version 2>/dev/null | head -n1)
            echo "Vector Version: $INSTALLED_VECTOR_VERSION" >> "$INSTALL_LOG"
        fi

        # Show configured Loki endpoint
        if [ -f /etc/vector/vector.toml ] && [ -n "$LOKI_ENDPOINT" ]; then
            if grep -q "$LOKI_ENDPOINT" /etc/vector/vector.toml; then
                echo "✓ Loki endpoint configured: $LOKI_ENDPOINT" >> "$INSTALL_LOG"
            else
                echo "⚠ Loki endpoint NOT found in config (expected: $LOKI_ENDPOINT)" >> "$INSTALL_LOG"
                warn "Vector config may not have been updated correctly"
            fi
        fi

        # Check systemd service status
        if systemctl is-active --quiet vector; then
            echo "✓ Vector systemd service is active" >> "$INSTALL_LOG"
        else
            echo "✗ Vector systemd service is NOT active" >> "$INSTALL_LOG"
        fi

    else
        warn "Vector installed but health check failed - service may still be starting"
        echo "✗ Vector API health check failed" >> "$INSTALL_LOG"

        # Debug info
        echo "Systemd status:" >> "$INSTALL_LOG"
        systemctl status vector --no-pager >> "$INSTALL_LOG" 2>&1 || true

        echo "Last 20 lines of journald logs:" >> "$INSTALL_LOG"
        journalctl -u vector -n 20 --no-pager >> "$INSTALL_LOG" 2>&1 || true
    fi

    echo "=== Vector Installation Complete ===" >> "$INSTALL_LOG"
    echo "Installation log available at: $INSTALL_LOG" >> "$INSTALL_LOG"

    log "Vector installation log: $INSTALL_LOG"
}
