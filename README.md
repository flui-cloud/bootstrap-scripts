# Flui Bootstrap

Bootstrap scripts for Flui.cloud infrastructure provisioning.

## Overview

This repository contains the initialization scripts used by Flui.cloud to provision and configure cloud infrastructure. These scripts are downloaded and executed during server creation via cloud-init.

## Scripts

### `scripts/flui-init.sh`
Base initialization script that sets up:
- System updates and essential packages
- Podman container runtime
- Monitoring agents (node_exporter, promtail)
- SSH Certificate Authority enrollment
- Security hardening

### `scripts/k3s-master-init.sh`
K3s master node initialization that:
- Downloads and executes flui-init.sh
- Installs K3s in server mode
- Deploys observability stack (PostgreSQL, Redis, Prometheus, Loki, Grafana)
- Configures health monitoring endpoint
- Sets up kubeconfig and kubectl

### `scripts/k3s-worker-init.sh`
K3s worker node initialization that:
- Downloads and executes flui-init.sh
- Installs K3s in agent mode
- Joins the cluster using the master node IP and token

## Usage

These scripts are automatically downloaded and executed by Flui.cloud during infrastructure provisioning. They are not meant to be run manually.

### Environment Variables

The scripts expect various environment variables to be set (see individual scripts for details):
- `INSTANCE_ID`, `INSTANCE_NAME`, `CLOUD_PROVIDER`
- `CLUSTER_ID`, `CLUSTER_NAME`, `K3S_TOKEN`
- `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `GRAFANA_PASSWORD` (for observability stack)

### Custom Base URL

You can override the scripts download URL by setting:
```bash
export SCRIPTS_BASE_URL="https://your-custom-url.com/scripts"
```

## Development

### Testing Changes

Before committing changes, validate bash syntax:
```bash
bash -n scripts/flui-init.sh
bash -n scripts/k3s-master-init.sh
bash -n scripts/k3s-worker-init.sh
```

### Versioning

- `main` branch: Production-ready scripts
- `develop` branch: Development and testing
- Tags: Use semantic versioning (v1.0.0, v1.1.0, etc.)

## Security

These scripts run with root privileges during server initialization. Always review changes carefully before merging to main.

## License

Copyright © 2025 Flui.cloud
