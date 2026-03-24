# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Kubernetes infrastructure repository for deploying MOSIP, Esignet, Inji, and other Digital Public Goods (DPG) platforms. It contains shell scripts, Helm values files, Ansible playbooks, and Kubernetes YAML manifests — no application source code. Licensed under MPL 2.0.

All infrastructure lives under `k8s-infra/`. The git root is `k8s-infra/`.

## Architecture

The repo is organized by infrastructure concern, each as a self-contained directory with its own `install.sh`, `delete.sh`, values files, and README:

- **k8-cluster/** — Cluster provisioning. On-prem via RKE1/RKE2 (with Ansible playbooks for RKE2), cloud via AWS/Azure/GCP/Oracle.
- **ingress/** — Ingress controllers. Istio service mesh (loadbalancer and nodeport variants) and ingress-nginx.
- **storage-class/** — Persistent storage: NFS, Longhorn, EBS, EFS, Ceph CSI.
- **monitoring/** — Prometheus/Grafana stack via Rancher Monitoring Helm charts (namespace: `cattle-monitoring-system`).
- **logging/** — ELK stack (Elasticsearch + Kibana) with Rancher Logging operator (namespace: `cattle-logging-system`).
- **alerting/** — Alertmanager config and custom PrometheusRule alerts (node CPU, memory, disk, PV usage, node-not-ready).
- **nginx/** — Nginx reverse proxy configs for on-prem deployments, per domain (mosip, esignet, observation).
- **observation/** — Observation cluster stack: Keycloak (RBAC) + Rancher UI.
- **apps/** — Application cluster apps: Keycloak + Rancher UI (separate from observation cluster).
- **wireguard/** — WireGuard VPN setup.
- **utils/** — Maintenance scripts: cert backup/restore, SSL renewal, RKE recovery, Rancher role creation, httpbin test deployments.

## Common Patterns

### Install/Delete Scripts
Most components follow the same pattern:
```bash
./install.sh [kubeconfig]    # optional kubeconfig path as first arg
./delete.sh [kubeconfig]
```
Scripts set `KUBECONFIG` from the first argument, create a namespace, add Helm repos, then install charts with `-f values.yaml`. Error handling uses `set -e -o errexit -o nounset -o errtrace -o pipefail`.

### Helm Charts
Most Helm installs reference `mosip/` chart repo. Values are in co-located `values.yaml` files. Override values via `--set` flags in the install scripts.

### Ansible (RKE2 only)
RKE2 cluster setup uses Ansible playbooks in `k8s-infra/k8-cluster/on-prem/rke2/ansible/`. Entry point is `main.yaml`. Inventory and variables (e.g., `RKE2_PATH`, `INSTALL_RKE2_VERSION`) must be configured before running.

## Key Tools Required

- `kubectl`, `helm`, `istioctl` — Kubernetes management
- `ansible-playbook` — RKE2 cluster provisioning
- `eksctl` — AWS EKS cluster management (see `k8-cluster/csp/aws/`)
- `rke` — RKE1 cluster management
- `wg` — WireGuard VPN

## Local Development (Docker Desktop)

Local dev scripts are split across two repos, matching the production architecture:

- **`k8s-infra/local/`** — Infrastructure layer (ingress, nginx reverse proxy, monitoring, logging)
- **`mosip-infra/deployment/v3/local/`** — MOSIP application layer (external components + core services)

### Architecture Mapping

Production uses two clusters with Istio. Local dev collapses into a single Docker Desktop node:

| Production | Local dev replacement | Repo |
|---|---|---|
| LB / Nginx | `nginx-local.yaml` (NodePort 30000) | k8s-infra |
| Istio ingress gateways (public + internal) | ingress-nginx (NodePort 30080/30443) | k8s-infra |
| Rancher+IAM observation cluster | Skipped (no Rancher locally) | — |
| MOSIP application Keycloak | `install-external.sh keycloak` | mosip-infra |
| PostgreSQL, Kafka, MinIO (external) | `install-external.sh` (in-cluster) | mosip-infra |
| HSM | SoftHSM (in-cluster) | mosip-infra |
| ABIS, BioSDK | mock-abis, biosdk (in-cluster) | mosip-infra |

### Deployment Profiles

All scripts support tiered profiles. Pick based on available RAM:

| RAM | k8s-infra | mosip-infra external | mosip-infra services | What you get |
|-----|-----------|---------------------|---------------------|-------------|
| **8GB** | `./setup.sh minimal` | `./install-external.sh minimal` | `./install-services.sh minimal` | Identity store + kernel APIs |
| **16GB** | `./setup.sh dev` | `./install-external.sh poc` | `./install-services.sh poc` | + ID verification + data pipeline |
| **24GB+** | `./setup.sh all` | `./install-external.sh all` | `./install-services.sh all` | Full stack incl. registration + portals |

Profiles are additive — running `core` after `minimal` adds services without reinstalling.

### Quick Start

```bash
# Step 1: Infrastructure (k8s-infra)
cd k8s-infra/local
./setup.sh minimal              # ingress-nginx + nginx reverse proxy

# Step 2: MOSIP external components (mosip-infra)
cd ../../mosip-infra/deployment/v3/local
./install-external.sh minimal   # postgres, keycloak, softhsm

# Step 3: MOSIP core services (mosip-infra)
./install-services.sh minimal   # config-server, kernel, idrepo, keymanager

# Check health
./install-services.sh status
```

### Local Dev Gotchas

- **JVM heap**: MOSIP images hardcode 1.5GB heap (`-Xms1575M -Xmx1575M`). Scripts override to 512MB via `additionalResources.javaOpts` (not `extraEnvVars` — many charts already define `JDK_JAVA_OPTIONS`, causing duplicate env conflicts).
- **Init containers**: `openjdk:11-jre` removed from Docker Hub. Scripts patch to `eclipse-temurin:11-jre` via `skip_cacerts_init` BEFORE calling `wait_ready` — patching after the helm install but before the pod starts avoids `ImagePullBackOff` on the init container.
- **Bitnami image verification**: MOSIP custom images fail checks. Scripts pass `--set global.security.allowInsecureImages=true`.
- **Docker Hub rate limits**: If pods get `ImagePullBackOff`, pre-pull images: `docker pull mosipid/<image>:1.3.0`.
- **Storage**: Uses `hostpath` (Docker Desktop default). No NFS/EBS needed.
- **Resource overcommit**: Scripts use minimal requests (10m CPU, 64Mi memory) with higher limits (1Gi) to allow K8s overcommit.

### Deployment Lessons Learned

#### Sequential deployment is critical
Services MUST be deployed one at a time, waiting for each to reach `1/1 Ready` before starting the next. Deploying all at once causes memory thrashing (12+ JVMs competing for RAM), API server timeouts, and cascading CrashLoops. The `wait_ready` function polls every 5 seconds and detects crashes immediately instead of blocking on timeouts.

#### Config-server bootstrap dependencies
Config-server mounts env vars from 14+ configmaps/secrets across many namespaces (activemq, keycloak, s3, softhsm, etc.). On a fresh deploy these don't exist yet, causing `CreateContainerConfigError`. The `bootstrap_config_server_deps` function creates stubs with placeholder values. Key gotcha: `s3` must be created as BOTH a configmap AND a secret (the chart references both types).

#### Config-server must use Recreate strategy
The default RollingUpdate strategy creates two config-server pods simultaneously, causing port conflicts and stale config. Scripts patch the deployment to `Recreate` strategy after install.

#### Postgres initialization
- Use the production `init_values.yaml` file (at `deployment/v3/external/postgres/init_values.yaml`) as source of truth for all databases — it includes `mosip_idmap`, `mosip_otp`, `mosip_digitalcard` which are easy to miss when hardcoding.
- The `postgres-postgresql` secret uses key `postgresql-password` but the postgres-init chart expects `postgres-password` — scripts patch the secret to add both keys.
- Additional DB users not created by postgres-init: `otpuser`, `idmapuser`, `regdeviceuser`, `authdeviceuser` — scripts create these manually with the same password.
- Salt tables (`uin_hash_salt`, `uin_encrypt_salt`) must exist in `mosip_idmap.idmap` and `mosip_idrepo.idrepo` schemas before `idrepo-saltgen` runs.

#### SoftHSM PIN alignment
SoftHSM generates a random PIN on first install. This PIN is the authoritative source — do not generate a separate PIN in conf-secrets. Scripts copy the PIN from `softhsm/softhsm-kernel` secret to wherever config-server needs it. If the PIN doesn't match, keymanager fails with `CKR_PIN_INCORRECT`.

#### Keygen jobs skipped locally
The `kernel-keygen` and `ida-keygen` Helm jobs have a known NPE with Spring Boot 3.x classloader (`LaunchedClassLoader.loadClass` — `"name" is null`). Keymanager and IDA generate keys on first request, so keygen is safely skipped.

#### Service-specific dependencies
- **BioSDK**: Identity service calls `http://biosdk-service.biosdk/biosdk-service/init` at startup — hard fails without it. Helm release name must be `biosdk-service` (not `biosdk`) so the K8s service name matches the config property.
- **mock-smtp**: Notifier health check connects to `mock-smtp.mock-smtp:8025` — fails readiness probe without it. Must be in minimal profile.
- **Keycloak**: Two Keycloak instances are intentional in production (one for Rancher+IAM cluster management, one for MOSIP application IAM). Local dev only needs the MOSIP one.

#### CRDs required
MOSIP Helm charts create `ServiceMonitor` and `VirtualService` resources. Install these CRDs before any MOSIP charts:
- ServiceMonitor: from prometheus-community helm charts
- VirtualService: from Istio CRD manifests (just the CRDs, not Istio itself)

#### Keycloak first boot
Keycloak's first boot takes 2-3 minutes for DB migration. The liveness probe may kill it before it's ready. The second boot is fast since migrations are done. This is expected — don't treat the first restart as a crash.

## Working With This Repo

- There are no build steps, tests, or linters — this is purely infrastructure-as-code.
- Changes are typically to Helm values YAML files or shell scripts.
- When modifying install scripts, preserve the existing error-handling boilerplate at the bottom.
- Many scripts use interactive `read -p` prompts, so they cannot be run non-interactively without modification.
