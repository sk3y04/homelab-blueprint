# Monitoring Stack — Grafana + Prometheus + Loki

Centralised observability for the homelab. **Grafana** provides dashboards,
**Prometheus** stores time-series metrics, **Loki** stores logs, **Promtail**
ships Docker container logs to Loki, and **Node Exporter** exposes host-level
CPU / RAM / disk / network statistics.

```
                  ┌───────────────┐
Docker containers │   Promtail    │──push──► Loki ──────┐
                  └───────────────┘                      │
                  ┌───────────────┐                      ▼
Host OS           │ Node Exporter │──scrape── Prometheus ──► Grafana ◄── You
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

| Requirement            | Why                                                  |
| ---------------------- | ---------------------------------------------------- |
| Docker & Docker Compose | Runs the five containers.                           |
| OpenVPN tunnel active  | VPS nginx must reach `10.40.40.2:3100` (Grafana).    |
| DNS record             | `grafana.skey.ovh` → VPS public IP.                  |
| Let's Encrypt cert     | TLS for `grafana.skey.ovh`.                          |

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

# 4. Check that all five containers are healthy
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

---

## Accessing Grafana

### Locally (no VPS)

Open `http://<home-server-ip>:3100` and log in with the admin credentials
from your `.env`.

### Via the internet (VPS reverse proxy)

Once the VPS is configured (see below), open `https://grafana.skey.ovh`.
Authelia will prompt for 2FA before you reach Grafana.

---

## VPS Configuration

> These steps are **already done** in the repo configs. This section explains
> what was added so you can verify or adapt.

### 1. DNS

Create an A record:

```
grafana.skey.ovh  →  <VPS public IP>
```

### 2. Let's Encrypt certificate

```bash
# On the VPS
certbot certonly --webroot -w /usr/local/www -d grafana.skey.ovh
```

### 3. Nginx (`vps/nginx/conf.d/services.conf`)

- **Upstream**: `grafana_upstream` → `10.40.40.2:3100`
- **HTTP block**: ACME challenge + redirect to HTTPS.
- **HTTPS block**: TLS termination, Authelia `auth_request`, `proxy_pass` to
  `grafana_upstream` with WebSocket support (`Upgrade` / `Connection` headers).

### 4. Authelia (`services/authelia/config/configuration.yml`)

```yaml
- domain: "grafana.skey.ovh"
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
```

### Recommended Dashboards

Import these from [grafana.com/dashboards](https://grafana.com/grafana/dashboards/):

| Dashboard ID | Name                     | Purpose                        |
| ------------ | ------------------------ | ------------------------------ |
| **1860**     | Node Exporter Full       | Complete host metrics overview |
| **13639**    | Loki & Promtail          | Docker container log dashboard |

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
