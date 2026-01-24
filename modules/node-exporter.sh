#!/bin/bash
# Node Exporter Installation Module
# Extracted from flui-init.sh for reusability across all server types
# Version: 1.7.0

install_node_exporter() {
    log "Installing Node Exporter v${NODE_EXPORTER_VERSION}..."

    # Create log directory for Node Exporter installation
    mkdir -p /var/log/flui/node-exporter
    local INSTALL_LOG="/var/log/flui/node-exporter/install.log"

    {
        echo "=== Node Exporter Installation Started ==="
        echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Version: ${NODE_EXPORTER_VERSION}"
        echo "=================================="
    } >> "$INSTALL_LOG"

    local arch="linux-amd64"
    local filename="node_exporter-${NODE_EXPORTER_VERSION}.${arch}"
    local url="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${filename}.tar.gz"

    cd /tmp
    echo "Downloading from: $url" >> "$INSTALL_LOG"

    if curl -fsSL "$url" -o "${filename}.tar.gz" 2>> "$INSTALL_LOG"; then
        echo "✓ Node Exporter downloaded successfully" >> "$INSTALL_LOG"
    else
        echo "✗ Failed to download Node Exporter from $url" >> "$INSTALL_LOG"
        error "Failed to download Node Exporter - check $INSTALL_LOG"
    fi

    if tar xzf "${filename}.tar.gz" 2>> "$INSTALL_LOG"; then
        echo "✓ Node Exporter archive extracted" >> "$INSTALL_LOG"
    else
        echo "✗ Failed to extract Node Exporter archive" >> "$INSTALL_LOG"
        error "Failed to extract Node Exporter - check $INSTALL_LOG"
    fi

    if cp "${filename}/node_exporter" /usr/local/bin/ 2>> "$INSTALL_LOG"; then
        echo "✓ Node Exporter binary copied to /usr/local/bin/" >> "$INSTALL_LOG"
    else
        echo "✗ Failed to copy Node Exporter binary" >> "$INSTALL_LOG"
        error "Failed to install Node Exporter binary - check $INSTALL_LOG"
    fi

    chmod +x /usr/local/bin/node_exporter
    echo "✓ Node Exporter binary made executable" >> "$INSTALL_LOG"

    if useradd --system --no-create-home --shell /bin/false node_exporter 2>> "$INSTALL_LOG"; then
        echo "✓ Created system user 'node_exporter'" >> "$INSTALL_LOG"
    else
        echo "⚠ User 'node_exporter' already exists (skipped)" >> "$INSTALL_LOG"
        log "Node exporter user already exists"
    fi

    cat > /etc/systemd/system/node-exporter.service << 'EOF'
[Unit]
Description=Node Exporter
Documentation=https://prometheus.io/docs/guides/node-exporter/
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter \
    --collector.systemd \
    --collector.processes \
    --collector.interrupts \
    --collector.tcpstat \
    --collector.cpu.info \
    --collector.diskstats \
    --collector.filesystem \
    --collector.loadavg \
    --collector.meminfo \
    --collector.netdev \
    --collector.netstat \
    --collector.stat \
    --collector.time \
    --collector.uname \
    --collector.vmstat \
    --web.listen-address=:9100 \
    --web.telemetry-path=/metrics

SyslogIdentifier=node_exporter
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    echo "Creating systemd service..." >> "$INSTALL_LOG"
    systemctl daemon-reload 2>> "$INSTALL_LOG"

    if systemctl enable node-exporter 2>> "$INSTALL_LOG"; then
        echo "✓ Node Exporter service enabled" >> "$INSTALL_LOG"
    else
        echo "✗ Failed to enable Node Exporter service" >> "$INSTALL_LOG"
        error "Failed to enable Node Exporter service - check $INSTALL_LOG"
    fi

    if systemctl start node-exporter 2>> "$INSTALL_LOG"; then
        echo "✓ Node Exporter service started" >> "$INSTALL_LOG"
    else
        echo "✗ Failed to start Node Exporter service" >> "$INSTALL_LOG"
        error "Failed to start Node Exporter service - check $INSTALL_LOG"
    fi

    sleep 3

    # Enhanced health check with metrics verification
    echo "=== Node Exporter Health Check ===" >> "$INSTALL_LOG"

    if curl -f http://localhost:9100/metrics &>/dev/null; then
        log "✅ Node Exporter installed and responding on port 9100"
        echo "✓ Node Exporter metrics endpoint responding" >> "$INSTALL_LOG"

        # Count and log sample metrics
        local METRICS_COUNT=$(curl -s http://localhost:9100/metrics 2>/dev/null | grep -c "^node_" || echo "0")
        echo "✓ Exporting $METRICS_COUNT metrics" >> "$INSTALL_LOG"

        # Log first 10 metrics as sample
        echo "Sample metrics (first 10):" >> "$INSTALL_LOG"
        curl -s http://localhost:9100/metrics 2>/dev/null | grep "^node_" | head -10 >> "$INSTALL_LOG" || true

        # Check systemd service status
        if systemctl is-active --quiet node-exporter; then
            echo "✓ Node Exporter systemd service is active" >> "$INSTALL_LOG"
        fi

    else
        warn "Node Exporter installed but not responding"
        echo "✗ Node Exporter metrics endpoint NOT responding" >> "$INSTALL_LOG"

        # Debug info
        echo "Systemd status:" >> "$INSTALL_LOG"
        systemctl status node-exporter --no-pager >> "$INSTALL_LOG" 2>&1 || true

        echo "Last 20 lines of journald logs:" >> "$INSTALL_LOG"
        journalctl -u node-exporter -n 20 --no-pager >> "$INSTALL_LOG" 2>&1 || true
    fi

    echo "=== Node Exporter Installation Complete ===" >> "$INSTALL_LOG"
    echo "Installation log available at: $INSTALL_LOG" >> "$INSTALL_LOG"

    log "Node Exporter installation log: $INSTALL_LOG"

    rm -rf /tmp/node_exporter-* || true
}
