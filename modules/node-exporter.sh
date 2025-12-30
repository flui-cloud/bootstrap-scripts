#!/bin/bash
# Node Exporter Installation Module
# Extracted from flui-init.sh for reusability across all server types
# Version: 1.7.0

install_node_exporter() {
    log "Installing Node Exporter v${NODE_EXPORTER_VERSION}..."

    local arch="linux-amd64"
    local filename="node_exporter-${NODE_EXPORTER_VERSION}.${arch}"
    local url="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${filename}.tar.gz"

    cd /tmp

    if ! curl -fsSL "$url" -o "${filename}.tar.gz"; then
        error "Failed to download Node Exporter"
    fi

    if ! tar xzf "${filename}.tar.gz"; then
        error "Failed to extract Node Exporter"
    fi

    if ! cp "${filename}/node_exporter" /usr/local/bin/; then
        error "Failed to install Node Exporter binary"
    fi

    chmod +x /usr/local/bin/node_exporter

    if ! useradd --system --no-create-home --shell /bin/false node_exporter 2>/dev/null; then
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

    systemctl daemon-reload
    if ! systemctl enable node-exporter; then
        error "Failed to enable Node Exporter service"
    fi

    if ! systemctl start node-exporter; then
        error "Failed to start Node Exporter service"
    fi

    sleep 3

    if curl -f http://localhost:9100/metrics &>/dev/null; then
        log "✅ Node Exporter installed and responding on port 9100"
    else
        warn "Node Exporter installed but not responding"
    fi

    rm -rf /tmp/node_exporter-* || true
}
