# Monitoring Stack — Grafana + Prometheus + Loki

Centralised observability for the homelab. **Grafana** provides dashboards,
**Prometheus** stores time-series metrics, **Loki** stores logs, **Promtail**
ships Docker container logs to Loki, **Node Exporter** exposes host-level
CPU / RAM / disk / network statistics, and **nvidia-smi-exporter** collects
NVIDIA GPU metrics via `nvidia-smi` (RTX 3090 / Ampere): utilization, VRAM,
temperature, power draw, clocks, P-state, throttle reasons, NVENC/NVDEC
sessions, and ECC errors.

```
                  ┌───────────────┐
Docker containers │   Promtail    │──push──► Loki ──────┐
                  └───────────────┘                      │
                  ┌───────────────┐                      ▼
Host OS           │ Node Exporter │──scrape─┐
NVIDIA runtime    │nvidia-smi-exporter│scrape─├─► Prometheus ──► Grafana ◄── You
/dev (S.M.A.R.T.) │smartctl-exporter│─scrape─┘
                  └───────────────┘
```

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Quick Start](#quick-start)
3. [Environment Variables](#environment-variables)
4. [Accessing Grafana](#accessing-grafana)
5. [VPS Configuration](#vps-configuration)
6. [Exploring Logs](#exploring-logs)
7. [Exploring Metrics](#exploring-metrics)
8. [Adding More Exporters](#adding-more-exporters)
9. [Maintenance](#maintenance)

---

## Prerequisites

| Requirement              | Why                                                                 |
| ------------------------ | ------------------------------------------------------------------- |
| Docker & Docker Compose  | Runs all monitoring containers.                                     |
| NVIDIA Container Toolkit | Exposes the RTX 3090 to Docker containers (exporter + Jellyfin).   |
| OpenVPN tunnel active    | VPS nginx must reach `<home-server-vpn-ip>:3100` (Grafana).        |
| DNS record               | `grafana.example.com` → VPS public IP.                              |
| Let's Encrypt cert       | TLS for `grafana.example.com`.                                      |

### Installing the NVIDIA Container Toolkit (host)

Required once on the bare-metal host before starting the stack.

```bash
# Add the NVIDIA package repository
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

# Install
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit

# Register the NVIDIA runtime with Docker and restart
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# Verify — should print RTX 3090 info
docker run --rm --gpus all nvidia/cuda:12.6.3-base-ubuntu22.04 nvidia-smi
```

> **Docker Compose GPU syntax** — This stack uses the canonical
> `deploy.resources.reservations.devices` block (not the invalid `gpus: all`
> shorthand). Both nvidia-smi-exporter and Jellyfin request the GPU this way.

---

## Quick Start

```bash
# 1. Copy the example .env and edit it
cd services/monitoring
cp .env.example .env
nano .env        # Set MONITORING_DATA_DIR, admin password, etc.

# 2. Create data directories (Grafana uses a named volume — no host dir needed)
mkdir -p "$MONITORING_DATA_DIR"/{prometheus,loki,promtail}

# 3. Start the stack
docker compose up -d

# 4. Check that all containers are healthy
docker compose ps
```

Grafana is now running on `http://localhost:3100`.

---

## Environment Variables

| Variable                     | Default      | Description                                       |
| ---------------------------- | ------------ | ------------------------------------------------- |
| `TZ`                         | `UTC`        | Timezone for all containers.                       |
| `MONITORING_CONFIG_DIR`      | —            | Host path for config files (only needed if you override the bind-mount). |
| `MONITORING_DATA_DIR`        | —            | Host path for persistent data (Grafana DB, Prometheus TSDB, Loki chunks). |
| `GRAFANA_HTTP_PORT`          | `3100`       | Host port for Grafana web UI.                      |
| `GF_SECURITY_ADMIN_USER`     | `admin`      | Grafana admin username.                            |
| `GF_SECURITY_ADMIN_PASSWORD` | `CHANGE_ME`  | Grafana admin password — **change this**.           |
| `PROMETHEUS_PORT`            | `9090`       | Host port for Prometheus (127.0.0.1 only).         |
| `LOKI_PORT`                  | `3101`       | Host port for Loki (127.0.0.1 only).               |
| `NODE_EXPORTER_PORT`         | `9100`       | Host port for Node Exporter (127.0.0.1 only).      |
| `NVIDIA_SMI_EXPORTER_PORT`   | `9835`       | Host port for the NVIDIA GPU Exporter (127.0.0.1 only).            |
| `NVIDIA_VISIBLE_DEVICES`     | `all`        | GPUs exposed to the exporter container (`all`, `0`, GPU UUID, etc.) |
| `SMARTCTL_EXPORTER_PORT`     | `9633`       | Host port for smartctl S.M.A.R.T. Exporter (127.0.0.1 only).      |

---

## Accessing Grafana

### Locally (no VPS)

Open `http://<home-server-ip>:3100` and log in with the admin credentials
from your `.env`.

### Via the internet (VPS reverse proxy)

Once the VPS is configured (see below), open `https://grafana.example.com`.
Authelia will prompt for 2FA before you reach Grafana.

---

## VPS Configuration

> These steps are **already done** in the repo configs. This section explains
> what was added so you can verify or adapt.

### 1. DNS

Create an A record:

```
grafana.example.com  →  <VPS public IP>
```

### 2. Let's Encrypt certificate

```bash
# On the VPS
certbot certonly --webroot -w /usr/local/www -d grafana.example.com
```

### 3. Nginx (`vps/nginx/conf.d/services.conf`)

- **Upstream**: `grafana_upstream` → `<home-server-vpn-ip>:3100`
- **HTTP block**: ACME challenge + redirect to HTTPS.
- **HTTPS block**: TLS termination, Authelia `auth_request`, `proxy_pass` to
  `grafana_upstream` with WebSocket support (`Upgrade` / `Connection` headers).

### 4. Authelia (`services/authelia/config/configuration.yml`)

```yaml
- domain: "grafana.example.com"
  policy: two_factor
```

### 5. PF firewall (`vps/pf.conf`)

Port `3100` added to `home_service_ports`.

### 6. Reload

```bash
# On the VPS
pfctl -f /etc/pf.conf
nginx -t && service nginx reload
```

---

## Exploring Logs

1. In Grafana, go to **Explore** (compass icon).
2. Select the **Loki** data source (top dropdown).
3. Use LogQL queries:

```logql
# All logs from the Authelia container
{container="authelia"}

# Errors from any container
{compose_project=~".+"} |= "error"

# Nextcloud logs in the last hour
{container="nextcloud_app"} | json | level = "error"
```

---

## Exploring Metrics

1. In Grafana, go to **Explore**.
2. Select the **Prometheus** data source.
3. Use PromQL queries:

```promql
# CPU usage (1-minute average)
100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100)

# Memory usage percentage
100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)

# Disk usage percentage (root filesystem)
100 - (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"} * 100)

# Network received bytes/sec
rate(node_network_receive_bytes_total{device="eth0"}[5m])

# ── NVIDIA RTX 3090 ────────────────────────────────────────────────────────

# GPU core utilization %
nvidia_gpu_utilization_percent

# VRAM used %
nvidia_vram_used_bytes / nvidia_vram_total_bytes * 100

# GPU die temperature (°C)
nvidia_temperature_celsius

# GPU power draw vs TDP limit (watts)
nvidia_power_draw_watts
nvidia_power_limit_watts

# Performance state (0 = P0 full speed, 8 = P8 idle)
nvidia_pstate

# Any throttle reason active? (1 = throttled)
nvidia_throttle_hw_slowdown
nvidia_throttle_hw_thermal_slowdown
nvidia_throttle_hw_power_brake
nvidia_throttle_sw_thermal_slowdown
nvidia_throttle_sw_power_cap

# Jellyfin NVENC/NVDEC hardware transcode sessions
nvidia_encoder_sessions
nvidia_decoder_sessions

# ECC errors since last driver load (N/A if ECC disabled on consumer GPU)
nvidia_ecc_corrected_volatile
nvidia_ecc_uncorrected_volatile

# ── Thermal sensors (host, via Node Exporter) ──────────────────────────────
# All hwmon thermal sensors (CPU, MB, memory)
node_hwmon_temp_celsius

# Drive temperature for all disks
smartctl_device_temperature{temperature_type="current"}

# Drive power-on hours (lifetime)
smartctl_device_power_on_seconds / 3600

# MD RAID array health (1 = active)
node_md_state
```

### Recommended Dashboards

The `nvidia-gpu.json` dashboard is **already provisioned** automatically — it
appears in Grafana under **Homelab → NVIDIA GPU — RTX 3090** on first start.

Additionally import these from [grafana.com/dashboards](https://grafana.com/grafana/dashboards/):

| Dashboard ID | Name                     | Purpose                                            |
| ------------ | ------------------------ | -------------------------------------------------- |
| **1860**     | Node Exporter Full       | Complete host CPU / RAM / disk / network overview  |
| **13639**    | Loki & Promtail          | Docker container log dashboard                     |

To import: **Dashboards → New → Import → Enter ID → Load → Select data source → Import**.

---

## Adding More Exporters

The stack is designed to grow. To monitor a specific service:

1. Add the exporter container to `docker-compose.yml` on the `monitoring` network.
2. Add a scrape job to `config/prometheus.yml`.
3. Restart: `docker compose up -d && docker compose restart prometheus`.

Examples:

| Service       | Exporter Image                          | Metrics Port |
| ------------- | --------------------------------------- | ------------ |
| AdGuard Home  | `ebrianne/adguard-exporter`             | 9617         |
| Nextcloud     | (built-in via Nextcloud Serverinfo app) | —            |
| Matrix Synapse| (built-in at `/_synapse/metrics`)       | 9000         |

---

## Maintenance

### Check container health

```bash
cd services/monitoring
docker compose ps
docker compose logs -f --tail=50
```

### Update images

```bash
docker compose pull
docker compose up -d
```

### Prometheus data retention

Configured to **90 days** by default (`--storage.tsdb.retention.time=90d`).
Adjust in `docker-compose.yml` under the `prometheus` command args.

### Backup

Back up `$MONITORING_DATA_DIR` to preserve Prometheus history and Loki logs.
Grafana uses a named Docker volume (`grafana-data`). To back it up:

```bash
docker run --rm -v grafana-data:/data -v $(pwd):/backup alpine \
  tar czf /backup/grafana-backup.tar.gz -C /data .
```
