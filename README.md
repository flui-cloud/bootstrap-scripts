# Flui Bootstrap

Bootstrap scripts and Kubernetes manifests for Flui.cloud infrastructure provisioning.

## Overview

This repository contains the initialization scripts and manifests used by Flui.cloud to provision and configure cloud infrastructure. Scripts are downloaded and executed during server creation via cloud-init.

## Repository Structure

```
.
├── scripts/          # Server initialization scripts
├── modules/          # Shared script modules
├── manifests/        # Kubernetes manifests
│   └── observability/  # Full observability stack
└── docs/             # Additional documentation
```

## Scripts

### `scripts/flui-init.sh`
Base initialization script that sets up:
- System updates and essential packages
- Monitoring agents (node_exporter, Vector)
- SSH Certificate Authority enrollment
- Security hardening

### `scripts/k3s-master-init.sh`
K3s master node initialization that:
- Downloads and executes flui-init.sh
- Installs K3s in server mode
- Deploys the observability stack
- Configures health monitoring endpoint
- Sets up kubeconfig and kubectl

### `scripts/k3s-worker-init.sh`
K3s worker node initialization that:
- Downloads and executes flui-init.sh
- Installs K3s in agent mode
- Joins the cluster using the master node IP and token

## Modules

### `modules/vector.sh`
Configures Vector as the unified log collector for both host and Kubernetes pod logs. See [docs/LOGGING_PATTERNS.md](docs/LOGGING_PATTERNS.md) for details.

### `modules/monitoring.sh`
Sets up Prometheus node_exporter and related monitoring agents.

### `modules/node-exporter.sh`
Installs and configures the Prometheus node exporter.

## Observability Stack

Deployed via manifests in `manifests/control/`:

| Manifest | Component |
|---|---|
| `00-secrets.yaml` | Secrets |
| `00a-traefik-config.yaml` | Traefik ingress config |
| `01-namespace.yaml` | Namespace |
| `02-postgres.yaml` | PostgreSQL |
| `03-redis.yaml` | Redis |
| `04-prometheus-config.yaml` | Prometheus configuration |
| `04a-kube-state-metrics.yaml` | Kube state metrics |
| `05-prometheus.yaml` | Prometheus |
| `06-loki.yaml` | Loki (log storage) |
| `07-grafana-datasources.yaml` | Grafana datasources |
| `08-grafana.yaml` | Grafana |
| `09-flui-api.yaml` | Flui API |
| `10-flui-web.yaml` | Flui Web |
| `11-zitadel.yaml` | Zitadel (authentication) |
| `12-flui-web-config.yaml` | Flui Web configuration |

## Usage

These scripts are automatically downloaded and executed by Flui.cloud during infrastructure provisioning. They are not meant to be run manually.

### Environment Variables

The scripts expect various environment variables to be set (see individual scripts for details):
- `INSTANCE_ID`, `INSTANCE_NAME`, `CLOUD_PROVIDER`
- `CLUSTER_ID`, `CLUSTER_NAME`, `K3S_TOKEN`
- `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `GRAFANA_PASSWORD`
- `ZITADEL_MASTER_KEY`

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

### Branching

- `master` branch: Production-ready scripts
- `feature/*` branches: New features and fixes — merge into master via pull request
- Tags: Use semantic versioning (v1.0.0, v1.1.0, etc.)

## Security

These scripts run with root privileges during server initialization. Always review changes carefully before merging to master.

## License

Copyright © 2026 Dawit Abate Woldeamanuel

This project is licensed under the GNU General Public License v3.0 — see the [LICENSE](LICENSE) file for details.
