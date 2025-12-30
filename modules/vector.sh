#!/bin/bash
# Vector Log Aggregation Module
# Extracted from flui-init.sh for reusability across all server types
# Version: 0.34.1
# Supports dynamic Loki endpoint configuration with enhanced logging

install_vector() {
    local LOKI_ENDPOINT="${1:-}"
    local SERVER_TYPE="${2:-generic}"
    local SERVER_ID="${3:-unknown}"
    local CLOUD_PROVIDER="${4:-unknown}"

    log "Installing Vector v0.34.1..."
    log "Configuration: SERVER_TYPE=${SERVER_TYPE}, SERVER_ID=${SERVER_ID}, LOKI_ENDPOINT=${LOKI_ENDPOINT}"

    # Download and install Vector
    cd /tmp
    wget -q https://packages.timber.io/vector/0.34.1/vector-0.34.1-x86_64-unknown-linux-musl.tar.gz
    tar xzf vector-0.34.1-x86_64-unknown-linux-musl.tar.gz
    cp vector-x86_64-unknown-linux-musl/bin/vector /usr/local/bin/
    chmod +x /usr/local/bin/vector
    rm -rf vector-*

    # Create required directories
    mkdir -p /etc/vector
    mkdir -p /var/lib/vector
    mkdir -p /var/log/vector
    mkdir -p /var/log/flui

    # Generate Vector configuration with conditional Loki sink
    if [ -n "$LOKI_ENDPOINT" ]; then
        log "Configuring Vector with Loki endpoint: $LOKI_ENDPOINT"
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
.cloud_provider = "CLOUD_PROVIDER_PLACEHOLDER"
.cluster_type = "CLUSTER_TYPE_PLACEHOLDER"
.source_type = "journald"
.filename = "journald"
'''

# Transform: enrich syslog files
[transforms.enrich_syslog]
type = "remap"
inputs = ["syslog"]
source = '''
.hostname = get_hostname!()
.server_type = "SERVER_TYPE_PLACEHOLDER"
.server_id = "SERVER_ID_PLACEHOLDER"
.cloud_provider = "CLOUD_PROVIDER_PLACEHOLDER"
.cluster_type = "CLUSTER_TYPE_PLACEHOLDER"
.source_type = "syslog"
.filename = replace!(.file, r'^.*/([^/]+)$', "$1")
'''

# Transform: enrich init logs
[transforms.enrich_flui_init]
type = "remap"
inputs = ["flui_init_logs"]
source = '''
.hostname = get_hostname!()
.server_type = "SERVER_TYPE_PLACEHOLDER"
.server_id = "SERVER_ID_PLACEHOLDER"
.cloud_provider = "CLOUD_PROVIDER_PLACEHOLDER"
.cluster_type = "CLUSTER_TYPE_PLACEHOLDER"
.source_type = "init"
.filename = replace!(.file, r'^.*/([^/]+)$', "$1")
'''

# Transform: enrich application logs
[transforms.enrich_flui_logs]
type = "remap"
inputs = ["flui_logs"]
source = '''
.hostname = get_hostname!()
.server_type = "SERVER_TYPE_PLACEHOLDER"
.server_id = "SERVER_ID_PLACEHOLDER"
.cloud_provider = "CLOUD_PROVIDER_PLACEHOLDER"
.cluster_type = "CLUSTER_TYPE_PLACEHOLDER"
.source_type = "application"
.filename = replace!(.file, r'^.*/([^/]+)$', "$1")
'''

# Sink: Loki
[sinks.loki]
type = "loki"
inputs = ["enrich_journald", "enrich_syslog", "enrich_flui_init", "enrich_flui_logs"]
endpoint = "http://LOKI_ENDPOINT_PLACEHOLDER"
encoding.codec = "json"
labels.hostname = "{{ hostname }}"
labels.server_type = "{{ server_type }}"
labels.cluster_type = "{{ cluster_type }}"
labels.source_type = "{{ source_type }}"
labels.filename = "{{ filename }}"

# Sink: File backup
[sinks.file_backup]
type = "file"
inputs = ["enrich_journald", "enrich_syslog", "enrich_flui_init", "enrich_flui_logs"]
path = "/var/log/vector/flui-%Y-%m-%d.log"
encoding.codec = "json"
compression = "gzip"
EOF

        # Replace placeholders with actual values
        sed -i "s|SERVER_TYPE_PLACEHOLDER|${SERVER_TYPE}|g" /etc/vector/vector.toml
        sed -i "s|SERVER_ID_PLACEHOLDER|${SERVER_ID}|g" /etc/vector/vector.toml
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

    if curl -f http://localhost:8686/health &>/dev/null; then
        log "✅ Vector installed and responding on port 8686"
    else
        warn "Vector installed but health check failed - service may still be starting"
    fi
}
