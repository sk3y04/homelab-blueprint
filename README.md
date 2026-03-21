# Homelab Blueprint

[![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![Services](https://img.shields.io/badge/Services-15-green.svg)](#services)
[![Host Services](https://img.shields.io/badge/Host_Services-2-orange.svg)](#-monero-full-node--xmrig-mining)
[![Rocky Linux](https://img.shields.io/badge/Rocky_Linux-10-10B981?logo=rockylinux&logoColor=white)](https://rockylinux.org/)

Production-ready Docker Compose stacks and host service configs for a self-hosted home server — 15 Docker services + Monero full node & XMRig miner, VPS reverse-proxy architecture, Authelia 2FA, local AI workloads, and full observability. Fork it, configure your `.env` files, and deploy.

---

## Table of Contents

- [Overview](#overview)
- [Server Hardware](#server-hardware)
- [Services](#services)
  - [Jellyfin](#-jellyfin--media-server)
  - [Nextcloud](#-nextcloud--personal-cloud)
  - [Code Server](#-code-server--remote-development)
   - [AI Stack](#-ai-stack--local-llm--agent-platform)
   - [ComfyUI](#-comfyui--image--video-generation)
  - [Apache Guacamole](#-apache-guacamole--remote-desktop-gateway)
  - [P2P / Gluetun VPN Stack](#-p2p--gluetun-vpn-stack)
  - [Minecraft Server](#-minecraft-server)
  - [CoolerControl](#%EF%B8%8F-coolercontrol--hardware-monitoring)
  - [Authelia](#-authelia--authentication-gateway)
  - [AdGuard Home](#-adguard-home--dns-ad-blocker)
  - [Matrix Synapse + Element](#-matrix-synapse--element--federated-messaging)
  - [Monitoring Stack](#-monitoring-stack--observability)
  - [BentoPDF](#-bentopdf--pdf-toolkit)
  - [TriliumNext Notes](#-triliumnext-notes--personal-knowledge-base)
  - [Monero Full Node & XMRig Mining](#%EF%B8%8F-monero-full-node--xmrig-mining)
- [Guides](#guides)
  - [Network Architecture](NETWORK.md)
   - [AI Stack](guide/AI_STACK.md)
   - [ComfyUI](guide/COMFYUI.md)
   - [AI Persona LoRA Training](guide/AI_PERSONA_TRAINING.md)
   - [AI Persona Evaluation Checklist](guide/AI_PERSONA_EVAL.md)
  - [Nginx Reverse Proxy](guide/NGINX.md)
  - [Authelia 2FA Gateway](guide/AUTHELIA.md)
  - [VPS Hardening](guide/HARDENING.md)
  - [Monitoring Stack](guide/MONITORING.md)
  - [Monero Full Node & XMRig Mining](guide/MONERO.md)
- [Prerequisites](#prerequisites)
- [Getting Started](#getting-started)
- [Project Structure](#project-structure)
- [Environment Variables](#environment-variables)

---

## Overview

This repository contains production-ready Docker Compose stacks that I use daily on my home server. Key design principles:

- **Environment-driven configuration** — All secrets, paths, and ports are externalized to `.env` files.
- **Isolation** — Each service lives in its own directory and can be started/stopped independently.
- **Persistence** — All application data is bind-mounted to the host for easy backups and portability.
- **Security** — P2P traffic is fully tunneled through a WireGuard VPN via Gluetun; services are designed to sit behind a reverse proxy.
- **GPU sharing** — The RTX 3090 is split across local LLM inference, coding agents, and ComfyUI image/video workflows with monitoring in Grafana.

---

## Server Hardware

### 🖥️ Home Server

| Component | Specification |
|---|---|
| **OS** | Rocky Linux 10 (Red Quartz) x86_64 |
| **CPU** | Intel Xeon E5-2697 v4 — 18 cores / 36 threads @ 2.3 GHz (Turbo 3.6 GHz) |
| **RAM** | 64 GB DDR4 ECC |
| **GPU** | NVIDIA RTX 3090 24 GB (NVENC/NVDEC hardware transcoding) |
| **Storage** | 70 GB `/` (xfs) · 390 GB `/home` (xfs) · 12 TB RAID6 (xfs) · 3 TB RAID1 (xfs LUKS encrypted) |

### ☁️ FreeBSD VPS (Reverse Proxy)

| Component | Specification |
|---|---|
| **OS** | FreeBSD 14 |
| **CPU** | Intel Core (Haswell) — 6 vCPUs @ 2.39 GHz |
| **RAM** | 12 GB |
| **Storage** | 100 GB `/` (ufs) |
| **Role** | Nginx reverse proxy, Let's Encrypt TLS, OpenVPN tunnel endpoint, PF firewall |

---

## Services

### 🎬 Jellyfin — Media Server

> 📖 **Guide:** [Full Setup Guide](guide/JELLYFIN.md)

| | |
|---|---|
| **Directory** | `services/jellyfin/` |
| **Image** | `jellyfin/jellyfin:latest` |
| **Purpose** | Free and open-source media streaming server |
| **Port** | `8096` (HTTP) |

- Hardware transcoding support via NVIDIA Container Toolkit (NVENC/NVDEC).
- Media library mounted read-only from host storage.
- Runs on a dedicated `media_internal` bridge network.

---

### ☁️ Nextcloud — Personal Cloud

> 📖 **Guide:** [Full Setup Guide](guide/NEXTCLOUD.md)

| | |
|---|---|
| **Directory** | `services/nextcloud/` |
| **Image** | `nextcloud:32-apache` |
| **Purpose** | Self-hosted file sync, sharing, and collaboration platform |
| **Port** | Configurable HTTP port |

Full-stack deployment with four containers:

| Container | Image | Role |
|---|---|---|
| `nextcloud_app` | `nextcloud:32-apache` | Main web application |
| `nextcloud_db` | `mariadb:10.11` | Database backend |
| `nextcloud_redis` | `redis:7-alpine` | Transactional file locking & cache |
| `nextcloud_cron` | `nextcloud:32-apache` | Background job processor |

- External RAID storage mounted at `/mnt/external/raid6`.
- Configurable PHP memory and upload limits.
- All services communicate on an isolated `nextcloud` bridge network.

---

### 💻 Code Server — Remote Development

> 📖 **Guide:** [Full Setup Guide](guide/CODE_SERVER.md)

| | |
|---|---|
| **Directory** | `services/code-server/` |
| **Image** | `linuxserver/code-server:4.107.0` |
| **Purpose** | Browser-based VS Code for remote development |
| **Port** | `8443` (HTTPS) |

- Password-protected access.
- Persistent configuration, extensions, and workspace data.
- Configurable default workspace directory.

---

### 🤖 AI Stack — Local LLM + Agent Platform

> 📖 **Guide:** [Full Setup Guide](guide/AI_STACK.md)

| | |
|---|---|
| **Directory** | `services/ai-stack/` |
| **Images** | `ollama/ollama:latest`, `ghcr.io/open-webui/open-webui:main`, `ghcr.io/anomalyco/opencode:latest`, `ghcr.io/openclaw/openclaw:latest` (optional profile), `nvcr.io/nvidia/k8s/dcgm-exporter:*` |
| **Purpose** | Local LLM inference, chat UI, coding agent, persona experimentation, and GPU telemetry |
| **Ports** | `11434` (Ollama API), `8080` (Open WebUI), `4096` (OpenCode), `8081` (OpenClaw), `9400` (DCGM exporter) |

Five-container deployment:

| Container | Image | Role |
|---|---|---|
| `ai-ollama` | `ollama/ollama:latest` | GPU-accelerated local model runtime |
| `ai-open-webui` | `ghcr.io/open-webui/open-webui:main` | Browser chat UI for local models |
| `ai-opencode` | `ghcr.io/anomalyco/opencode:latest` | Browser-based coding agent bound to the checked-out repo |
| `ai-openclaw` | `ghcr.io/openclaw/openclaw:latest` | Optional profile for experimental agent / Discord integration |
| `ai-dcgm-exporter` | `nvcr.io/nvidia/k8s/dcgm-exporter:*` | Prometheus GPU exporter for the RTX 3090 |

- Designed around a single NVIDIA RTX 3090 24 GB with Ollama as the shared model backend.
- Includes Open WebUI for chat and OpenCode for browser-based repo work; OpenClaw is available as an optional experimental profile.
- Ships helper scripts for start/stop/update, health checks, GPU power profiles, and persona LoRA training/export.
- DCGM metrics feed directly into the existing Monitoring Stack dashboards.

---

### 🎨 ComfyUI — Image & Video Generation

> 📖 **Guide:** [Full Setup Guide](guide/COMFYUI.md)

| | |
|---|---|
| **Directory** | `services/comfyui/` |
| **Image** | Custom build from `services/comfyui/Dockerfile` |
| **Purpose** | GPU-accelerated node-based image and video generation with Stable Diffusion, FLUX, and WAN workflows |
| **Port** | `8188` (Web UI + API) |

- Runs with full NVIDIA GPU passthrough and persistent host-mounted model, workflow, cache, and output directories.
- Uses a curated bootstrap flow with helper scripts for first-run setup, custom node installs, updates, backups, and validation.
- Designed to coexist with the AI Stack on the same RTX 3090, with documented VRAM strategies for SDXL, FLUX, and WAN workloads.
- Keeps monitoring responsibilities in the existing AI Stack + Monitoring Stack instead of duplicating GPU exporters.

---

### 🖥️ Apache Guacamole — Remote Desktop Gateway

> 📖 **Guide:** [Full Setup Guide](guide/GUACAMOLE.md)

| | |
|---|---|
| **Directory** | `services/guacamole/` |
| **Image** | `guacamole/guacamole:1.6.0` |
| **Purpose** | Clientless remote desktop gateway (RDP, SSH, VNC) |
| **Port** | `8080` (HTTP, behind nginx) |

Three-tier architecture:

| Container | Image | Role |
|---|---|---|
| `guacd_compose` | `guacamole/guacd:1.6.0` | Guacamole proxy daemon |
| `postgres_guacamole_compose` | `postgres:15.2-alpine` | Authentication & connection database |
| `guacamole_compose` | `guacamole/guacamole:1.6.0` | Web application |

- Includes a `prepare.sh` script that initializes the PostgreSQL database schema and generates self-signed SSL certificates.
- Session recording support with persistent storage.
- Shared drive mounting for file transfer.

> [!NOTE]
> The Guacamole stack is based on [boschkundendienst/guacamole-docker-compose](https://github.com/boschkundendienst/guacamole-docker-compose) with customizations for this homelab setup.

---

### 🔒 P2P / Gluetun VPN Stack

> 📖 **Guide:** [Full Setup Guide](guide/P2P_VPN.md)

| | |
|---|---|
| **Directory** | `services/p2p-gluetun/` |
| **Image** | `qmcgaw/gluetun:latest` |
| **Purpose** | Route P2P traffic through a WireGuard VPN tunnel |

All client containers share Gluetun's network stack (`network_mode: service:gluetun`), ensuring zero traffic leaks outside the VPN.

| Container | Image | Role |
|---|---|---|
| `gluetun` | `qmcgaw/gluetun:latest` | WireGuard VPN gateway |
| `qbittorrent` | `lscr.io/linuxserver/qbittorrent:latest` | BitTorrent client |
| `soulseek` | `realies/soulseek:latest` | P2P music sharing client |

- WireGuard-based VPN with configurable provider, endpoint, and keys.
- VPN port forwarding for optimal P2P connectivity.
- Shared media library mounts across download clients.
- All ports are exposed through the Gluetun container only.

---

### 🎮 Minecraft Server

> 📖 **Guide:** [Full Setup Guide](guide/MINECRAFT.md)

| | |
|---|---|
| **Directory** | `services/minecraft-server/` |
| **Image** | `itzg/minecraft-server:latest` |
| **Purpose** | Vanilla Minecraft Java Edition server |
| **Port** | `25565` (TCP) |

- Auto-updates daily via `pull_policy: daily`.
- Interactive console access (TTY + STDIN).
- Persistent world data and server configuration.
- Configurable Minecraft version.

---

### 🌡️ CoolerControl — Hardware Monitoring

> 📖 **Guide:** [Full Setup Guide](guide/COOLERCONTROL.md)

| | |
|---|---|
| **Directory** | `services/coolercontrol/` |
| **Image** | `coolercontrol/coolercontrold` |
| **Purpose** | Fan and cooling hardware monitoring & control |
| **Port** | `11987` (Web UI) |

- Runs in **privileged mode** for direct hardware sensor access.
- Persistent configuration storage.

---

### 🛡️ Authelia — Authentication Gateway

> 📖 **Guide:** [Full Setup Guide](guide/AUTHELIA.md)

| | |
|---|---|
| **Directory** | `services/authelia/` |
| **Image** | `authelia/authelia:latest` |
| **Purpose** | Centralized SSO portal with two-factor authentication |
| **Port** | `9091` (HTTP, behind nginx) |

- **WebAuthn** (YubiKey) as primary 2FA with **TOTP** as backup.
- File-based user database (no external DB required).
- Integrates with Nginx via `auth_request` for transparent protection of all services.
- Configurable per-service access policies (bypass / one-factor / two-factor).

---

### 🚫 AdGuard Home — DNS Ad Blocker

> 📖 **Guide:** [Full Setup Guide](guide/ADGUARD.md)

| | |
|---|---|
| **Directory** | `services/adguard-home/` |
| **Image** | `adguard/adguardhome:latest` |
| **Purpose** | Network-wide DNS ad/tracker blocking |
| **Port** | `3000` (Web UI), `53` (DNS) |

- Blocks ads, trackers, and malicious domains at the DNS level for all LAN clients.
- Web dashboard for configuration, query logs, and statistics.
- DNS port (53 TCP/UDP) exposed on the host — point your router or clients to the server's LAN IP.
- Persistent configuration and work data via bind mounts.

> [!NOTE]
> Ensure no other service (e.g. `systemd-resolved`) is binding port 53 on the host before starting AdGuard Home. On first run, complete the setup wizard at `http://<host-ip>:3000`.

---

### 💬 Matrix Synapse + Element — Federated Messaging

> 📖 **Guide:** [Full Setup Guide](guide/MATRIX.md)

| | |
|---|---|
| **Directory** | `services/matrix-synapse/` |
| **Images** | `matrixdotorg/synapse:latest`, `postgres:16-alpine`, `vectorim/element-web:latest` |
| **Purpose** | Federated messaging homeserver with a browser-based chat client |
| **Ports** | `8008` (Synapse HTTP), `8088` (Element Web HTTP) |

Three-container deployment:

| Container | Image | Role |
|---|---|---|
| `synapse` | `matrixdotorg/synapse:latest` | Matrix homeserver (federation + client API) |
| `synapse_db` | `postgres:16-alpine` | PostgreSQL database for Synapse |
| `element_web` | `vectorim/element-web:latest` | Browser-based Matrix chat client (Element) |

- **Identity:** Matrix IDs are `@user:example.com` — the server name is your base domain, with `.well-known` delegation pointing federation to `matrix.<domain>`.
- Includes a `prepare.sh` script that generates `homeserver.yaml`, signing keys, patches the database config for PostgreSQL, and creates an Element Web `config.json`.
- All services communicate on an isolated `matrix` bridge network.
- Synapse admin API is protected by Authelia 2FA; federation/client API endpoints are publicly accessible for interoperability.

> [!NOTE]
> Run `./prepare.sh` inside the `services/matrix-synapse/` directory **before** the first `docker compose up`. After starting, create your first admin user:
> ```bash
> docker exec -it synapse register_new_matrix_user -c /data/homeserver.yaml http://localhost:8008
> ```
> Verify federation at https://federationtester.matrix.org/

---

### 📊 Monitoring Stack — Observability

> 📖 **Guide:** [Full Setup Guide](guide/MONITORING.md)

| | |
|---|---|
| **Directory** | `services/monitoring/` |
| **Images** | `grafana/grafana-oss:latest`, `prom/prometheus:latest`, `grafana/loki:latest`, `grafana/promtail:latest`, `prom/node-exporter:latest` |
| **Purpose** | Centralized metrics, logs, and dashboards for the entire homelab |
| **Port** | `3100` (Grafana Web UI) |

Six-container deployment:

| Container | Image | Role |
|---|---|---|
| `grafana` | `grafana/grafana-oss:latest` | Dashboard & visualization UI |
| `prometheus` | `prom/prometheus:latest` | Time-series metrics database |
| `loki` | `grafana/loki:latest` | Log aggregation backend |
| `promtail` | `grafana/promtail:latest` | Docker log shipper → Loki |
| `node-exporter` | `prom/node-exporter:latest` | Host CPU / RAM / disk / network metrics |
| `xmrig-exporter` | local build (`xmrig-exporter/Dockerfile`) | XMRig HTTP API → Prometheus metrics (`:9189`) |

- **Grafana** is the only publicly exposed service (reverse-proxied and protected by Authelia 2FA). All other components are bound to `127.0.0.1`.
- Prometheus and Loki data sources are **auto-provisioned** on first boot — no manual setup needed.
- Promtail auto-discovers all running Docker containers and ships their logs to Loki.
- Ships with three pre-built dashboards: **Host Metrics** (CPU, RAM, disk, network gauges and graphs), **Container Logs** (searchable log viewer with error highlighting), and **XMRig Mining** (hashrate, shares, pool connection, hugepage allocation).
- `xmrig-exporter` translates XMRig's HTTP API (`0.0.0.0:18088`) into Prometheus text format — no changes to XMRig itself required.
- All six services share a private `monitoring` bridge network.

---

### 📄 BentoPDF — PDF Toolkit

> 📖 **Guide:** [Full Setup Guide](guide/BENTOPDF.md)

| | |
|---|---|
| **Directory** | `services/bentopdf/` |
| **Image** | `ghcr.io/alam00000/bentopdf:latest` |
| **Purpose** | Privacy-first PDF toolkit — all processing happens in the browser |
| **Port** | `8084` (HTTP) |

- Merge, split, compress, convert, rotate, watermark, and more — entirely client-side via WebAssembly.
- No files are ever uploaded to a server; everything stays in the user's browser.
- LibreOffice WASM integration enables Word/Excel/PowerPoint to PDF conversion.
- Minimal server resource requirements (static site served by nginx).
- Requires `Cross-Origin-Opener-Policy` and `Cross-Origin-Embedder-Policy` headers for full functionality.

---

### 📝 TriliumNext Notes — Personal Knowledge Base

> 📖 **Guide:** [Full Setup Guide](guide/TRILIUM.md)

| | |
|---|---|
| **Directory** | `services/trilium/` |
| **Image** | `ghcr.io/triliumnext/notes:v0.95.0` |
| **Purpose** | Hierarchical note-taking and personal knowledge base |
| **Port** | `8085` (HTTP) |

- Rich WYSIWYG editing with Markdown, code blocks, math equations, and diagrams.
- Hierarchical tree structure with note cloning (same note in multiple locations).
- Full-text search, relation maps, and custom JavaScript scripting.
- Embedded SQLite database — no external DB service required.
- Bi-directional sync with TriliumNext desktop clients.
- All data stored in a single directory for easy backups.

---

### ⛏️ Monero Full Node & XMRig Mining

> 📖 **Guide:** [Full Setup Guide](guide/MONERO.md)

| | |
|---|---|
| **Directory** | `services/xmrig/` |
| **Type** | Native host services (systemd) — not Docker |
| **Purpose** | Monero full node, Ledger hardware wallet, and CPU mining via MoneroOcean |

Two systemd services running directly on the host:

| Service | Binary | Role |
|---|---|---|
| `monerod` | `/opt/monero/monerod` | Monero full node — P2P `18080`, RPC `127.0.0.1:18081` |
| `xmrig` | `/opt/xmrig/xmrig` | XMRig CPU miner — HTTP API `0.0.0.0:18088` |

- **`services/xmrig/setup.sh`** — automated idempotent installer: builds XMRig from source, configures hugepages & MSR, writes `config.json`, installs the systemd unit, and starts mining. Usage: `sudo ./setup.sh <WALLET_ADDRESS> [WORKER_NAME] [MAX_THREADS_HINT]`
- `monerod` runs a **pruned** blockchain (~70 GB vs ~200 GB) with RPC restricted to localhost.
- XMRig targets **MoneroOcean** pool over TLS port 443 for maximum firewall compatibility.
- **Ledger Nano S Plus** support via `monero-wallet-cli --generate-from-device` (Guide 2 in MONERO.md covers udev rules, wallet generation, and common failure points).
- **Hugepages** (2 MB) and **MSR wrmsr mod** are pre-configured for maximum RandomX hash rate (+10–15%).
- Mining metrics flow into the Monitoring Stack via the `xmrig-exporter` sidecar container — no additional config needed.

> [!NOTE]
> `monerod` initial sync takes several hours to days depending on bandwidth. XMRig can be started immediately but should be pointed at a local or remote daemon that has completed sync for accurate mining.

---

## Guides

Detailed setup guides for the infrastructure surrounding these Docker stacks:

| Guide | Description |
|---|---|
| [Network Architecture](NETWORK.md) | VPN tunnel topology, domain mapping, TLS configuration, and request flow |
| [AI Stack](guide/AI_STACK.md) | Ollama + Open WebUI + OpenCode + OpenClaw + DCGM exporter on the RTX 3090 |
| [ComfyUI](guide/COMFYUI.md) | GPU-accelerated image and video generation with custom nodes and model strategy |
| [AI Persona LoRA Training](guide/AI_PERSONA_TRAINING.md) | End-to-end dataset preparation, QLoRA training, GGUF export, and Ollama deployment |
| [AI Persona Evaluation Checklist](guide/AI_PERSONA_EVAL.md) | Manual scoring rubric for promoting or rejecting persona LoRA runs |
| [Nginx Reverse Proxy](guide/NGINX.md) | Step-by-step Nginx setup on the FreeBSD VPS with Let's Encrypt |
| [Authelia 2FA Gateway](guide/AUTHELIA.md) | Authelia setup with YubiKey WebAuthn + TOTP backup |
| [VPS Hardening](guide/HARDENING.md) | Fail2ban + PF firewall configuration on FreeBSD |
| [Monitoring Stack](guide/MONITORING.md) | Grafana + Prometheus + Loki setup, dashboards, and log queries |
| [Monero Full Node & XMRig Mining](guide/MONERO.md) | monerod setup, Ledger wallet, XMRig build & systemd config, MoneroOcean pool, Prometheus exporter |

**Recommended reading order:** Network Architecture → Nginx → Authelia → Hardening → Monitoring → AI Stack → ComfyUI → Monero

---

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) (v20.10+)
- [Docker Compose](https://docs.docker.com/compose/install/) (v2.0+)
- A `.env` file in each service directory (see [Environment Variables](#environment-variables))

---

## Getting Started

1. **Clone the repository:**

   ```bash
   git clone https://github.com/sk3y04/homelab-blueprint.git
   cd homelab-blueprint
   ```

2. **Create config files from templates:**

   ```bash
   # Copy all .env.example files to .env
   find services/ -name '.env.example' -exec sh -c 'cp "$1" "${1%.example}"' _ {} \;

   # Copy example config files
   cp vps/pf.example.conf vps/pf.conf
   cp vps/nginx/nginx.example.conf vps/nginx/nginx.conf
   cp vps/nginx/conf.d/services.example.conf vps/nginx/conf.d/services.conf
   ```

   Edit each `.env` and config file with your own domains, IPs, secrets, and paths.

3. **Start a service:**

   ```bash
   cd services/jellyfin/
   docker compose up -d
   ```

4. **Stop a service:**

   ```bash
   docker compose down
   ```

> [!NOTE]
> For Apache Guacamole, run `./prepare.sh` inside the `services/guacamole/` directory **before** the first `docker compose up` to initialize the database and generate SSL certificates.

> [!TIP]
> The example configuration files use default ports (e.g., Nextcloud on `:80`, qBittorrent on `:8081`, Guacamole on `:8080`). You can customize these in your `.env` files to avoid conflicts with your own setup. Make sure the corresponding Nginx upstream definitions match your chosen ports.

---

## Project Structure

```
.
├── README.md
├── CONTRIBUTING.md
├── LICENSE
├── NETWORK.md                          # Network architecture & remote access
├── guide/
│   ├── ADGUARD.md                      # AdGuard Home setup guide
│   ├── AI_PERSONA_EVAL.md              # Persona model evaluation checklist
│   ├── AI_PERSONA_TRAINING.md          # Persona LoRA training workflow guide
│   ├── AI_STACK.md                     # Local LLM + agent platform guide
│   ├── AUTHELIA.md                     # Authelia 2FA gateway setup guide
│   ├── BENTOPDF.md                     # BentoPDF setup guide
│   ├── CODE_SERVER.md                  # Code Server setup guide
│   ├── COMFYUI.md                      # ComfyUI image/video generation guide
│   ├── COOLERCONTROL.md                # CoolerControl setup guide
│   ├── GUACAMOLE.md                    # Apache Guacamole setup guide
│   ├── HARDENING.md                    # Fail2ban & PF firewall guide
│   ├── JELLYFIN.md                     # Jellyfin setup guide
│   ├── MATRIX.md                       # Matrix Synapse + Element setup guide
│   ├── MINECRAFT.md                    # Minecraft server setup guide
│   ├── MONITORING.md                   # Monitoring stack setup guide
│   ├── MONERO.md                       # Monero full node, Ledger wallet & XMRig guide
│   ├── NEXTCLOUD.md                    # Nextcloud setup guide
│   ├── NGINX.md                        # Nginx reverse proxy setup guide
│   ├── P2P_VPN.md                      # P2P / Gluetun VPN setup guide
│   └── TRILIUM.md                      # TriliumNext Notes setup guide
├── vps/
│   ├── pf.example.conf                 # PF firewall config (template)
│   └── nginx/
│       ├── nginx.example.conf          # Main Nginx config (template)
│       └── conf.d/
│           └── services.example.conf   # Upstream & server blocks (template)
└── services/
    ├── adguard-home/
    │   └── docker-compose.yml              # DNS ad blocker
    ├── authelia/
    │   ├── docker-compose.yml              # Authentication gateway
    │   └── config/
    │       ├── configuration.example.yml   # Authelia config (template)
    │       └── users_database.example.yml  # User database (template)
   ├── ai-stack/
   │   ├── docker-compose.yml              # Ollama + Open WebUI + OpenCode + OpenClaw + DCGM exporter
   │   ├── deploy-persona.sh               # Deploy GGUF persona adapter into Ollama
   │   ├── healthcheck.sh                  # Stack health and GPU/API checks
   │   ├── Modelfile.persona.example       # Example Ollama persona model definition
   │   ├── promote-persona-defaults.sh     # Switch default services to a persona model
   │   ├── set-gpu-inference.sh            # Lower GPU power profile for daily inference
   │   ├── set-gpu-training.sh             # Raise GPU power profile for training runs
   │   ├── start.sh                        # Start the AI stack
   │   ├── stop.sh                         # Stop the AI stack
   │   ├── update.sh                       # Update stack images and restart
   │   ├── config/
   │   │   ├── opencode/                   # OpenCode model/provider config
   │   │   └── openclaw/                   # OpenClaw agent config
   │   └── scripts/                        # Persona dataset, training, and export helpers
    ├── bentopdf/
    │   └── docker-compose.yml              # Privacy-first PDF toolkit
    ├── code-server/
    │   └── docker-compose.yml              # Browser-based VS Code
   ├── comfyui/
   │   ├── docker-compose.yml              # ComfyUI service definition
   │   ├── Dockerfile                      # Custom ComfyUI image build
   │   ├── config/
   │   │   └── extra_model_paths.example.yaml  # Optional shared model paths
   │   └── scripts/                        # Init, backup, update, and validation helpers
    ├── coolercontrol/
    │   └── docker-compose.yml              # Hardware fan/cooling control
    ├── guacamole/
    │   ├── docker-compose.yml              # Remote desktop gateway
    │   ├── prepare.sh                      # DB init & SSL cert generator
    │   ├── drive/                          # Shared file transfer drive
    │   └── init/
    │       └── initdb.sql                  # Guacamole DB schema
    ├── jellyfin/
    │   └── docker-compose.yml              # Media streaming server
    ├── matrix-synapse/
    │   ├── docker-compose.yml              # Matrix homeserver + Element Web
    │   └── prepare.sh                      # Synapse config generator
    ├── minecraft-server/
    │   └── docker-compose.yml              # Minecraft Java server
    ├── monitoring/
    │   ├── docker-compose.yml              # Grafana + Prometheus + Loki + xmrig-exporter
    │   ├── xmrig-exporter/
    │   │   ├── Dockerfile                  # Alpine Python 3.12 exporter image
    │   │   └── exporter.py                 # XMRig HTTP API → Prometheus metrics
    │   └── config/
    │       ├── prometheus.yml              # Prometheus scrape targets (incl. xmrig)
    │       ├── loki-config.yaml            # Loki storage configuration
    │       ├── promtail-config.yaml        # Promtail Docker log discovery
    │       └── grafana/
    │           └── provisioning/           # Auto-configured datasources & dashboards
    ├── nextcloud/
    │   └── docker-compose.yml              # Personal cloud platform
    ├── p2p-gluetun/
    │   └── docker-compose.yml              # VPN-tunneled P2P clients
    ├── trilium/
    │   └── docker-compose.yml              # TriliumNext personal knowledge base
    └── xmrig/
        └── setup.sh                        # Automated XMRig + MoneroOcean installer
```

---

## Environment Variables

Each service reads its configuration from a `.env` file in its respective directory. Below is a summary of the key variables per stack.

<details>
<summary><strong>🔑 Common Variables</strong></summary>

| Variable | Description | Example |
|---|---|---|
| `PUID` | User ID for file permissions | `1000` |
| `PGID` | Group ID for file permissions | `1000` |
| `TZ` | Timezone | `Europe/Warsaw` |

</details>

<details>
<summary><strong>🎬 Jellyfin</strong></summary>

| Variable | Description |
|---|---|
| `JELLYFIN_HTTP_PORT` | Host port for Jellyfin web UI |
| `JELLYFIN_PUBLISHED_SERVER_URL` | Externally reachable URL for clients |
| `JELLYFIN_CONFIG_DIR` | Path to config directory on host |
| `JELLYFIN_CACHE_DIR` | Path to cache directory on host |
| `MEDIA_ROOT_DIR` | Path to media library root |
| `TMP_DIR` | Path to temporary directory |

</details>

<details>
<summary><strong>☁️ Nextcloud</strong></summary>

| Variable | Description |
|---|---|
| `NEXTCLOUD_HTTP_PORT` | Host port for Nextcloud web UI |
| `MYSQL_ROOT_PASSWORD` | MariaDB root password |
| `MYSQL_PASSWORD` | Nextcloud DB user password |
| `MYSQL_DATABASE` | Database name |
| `MYSQL_USER` | Database user |
| `MARIADB_AUTO_UPGRADE` | Enable automatic DB upgrades |
| `REDIS_PASSWORD` | Redis authentication password |
| `NEXTCLOUD_DB_DIR` | Host path for MariaDB data |
| `NEXTCLOUD_REDIS_DIR` | Host path for Redis data |
| `NEXTCLOUD_DATA_DIR` | Host path for user files |
| `NEXTCLOUD_CONFIG_DIR` | Host path for Nextcloud config |
| `NEXTCLOUD_CUSTOM_APPS_DIR` | Host path for custom apps |
| `NEXTCLOUD_THEMES_DIR` | Host path for themes |
| `NEXTCLOUD_TRUSTED_DOMAINS` | Space-separated trusted domains |
| `NEXTCLOUD_PHP_MEMORY_LIMIT` | PHP memory limit (e.g., `512M`) |
| `NEXTCLOUD_PHP_UPLOAD_LIMIT` | PHP upload limit (e.g., `16G`) |
| `RAID_ROOT_DIR` | External RAID mount path |

</details>

<details>
<summary><strong>💻 Code Server</strong></summary>

| Variable | Description |
|---|---|
| `CODE_SERVER_PASSWORD` | Web UI password |
| `CODE_SERVER_DEFAULT_WORKSPACE` | Default workspace path |
| `CODE_SERVER_CONFIG_DIR` | Host path for config data |
| `CODE_SERVER_HTTP_PORT` | Host port for web UI |

</details>

<details>
<summary><strong>🤖 AI Stack</strong></summary>

| Variable | Description |
|---|---|
| `AI_ACTIVE_DATA_DIR` | Host path for active AI data: Ollama models, Open WebUI state, OpenCode state, adapters, training workspace |
| `AI_ARCHIVE_DATA_DIR` | Host path for cold storage: raw datasets, archived runs, old adapters, long-term backups |
| `OLLAMA_PORT` | Host port for the Ollama API |
| `OPEN_WEBUI_PORT` | Host port for the Open WebUI interface |
| `OPEN_WEBUI_SECRET_KEY` | Session and secret key for Open WebUI |
| `OPEN_WEBUI_ENABLE_SIGNUP` | Enable or disable self-service account creation |
| `OPENCLAW_PORT` | Host port for the OpenClaw API/UI |
| `OPENCLAW_DEFAULT_MODEL` | Default model OpenClaw should request from Ollama |
| `OPENCODE_PORT` | Host port for the OpenCode web UI |
| `OPENCODE_SERVER_USERNAME` | Basic auth username for OpenCode |
| `OPENCODE_SERVER_PASSWORD` | Basic auth password for OpenCode |
| `OPENCODE_MODEL` | Primary coding model used by OpenCode |
| `OPENCODE_SMALL_MODEL` | Secondary lightweight model used by OpenCode |
| `DCGM_EXPORTER_PORT` | Host port for the NVIDIA DCGM Prometheus exporter |
| `AI_TRAINING_IMAGE` | Optional training image used by the opt-in persona training profile |
| `LLAMA_CPP_DIR` | Local checkout path for `llama.cpp` export tooling |

</details>

<details>
<summary><strong>🎨 ComfyUI</strong></summary>

| Variable | Description |
|---|---|
| `COMFYUI_DATA_DIR` | Host path for ComfyUI models, custom nodes, cache, user data, inputs, and outputs |
| `COMFYUI_PORT` | Host port for the ComfyUI web UI and API |
| `PYTORCH_IMAGE` | PyTorch CUDA base image used to build the ComfyUI container |
| `COMFYUI_VERSION` | ComfyUI git ref to build (`master`, tag, or commit) |
| `COMFYUI_EXTRA_ARGS` | Extra CLI arguments passed to ComfyUI at runtime |

</details>

<details>
<summary><strong>🖥️ Guacamole</strong></summary>

| Variable | Description |
|---|---|
| `PGDATA` | PostgreSQL data directory inside container |
| `POSTGRES_DB` | PostgreSQL database name |
| `POSTGRES_PASSWORD` | PostgreSQL password |
| `POSTGRES_USER` | PostgreSQL user |
| `GUACAMOLE_GROUP_ADD` | Supplementary group for Guacamole |
| `RECORDING_SEARCH_PATH` | Path to session recordings |

</details>

<details>
<summary><strong>🔒 P2P / Gluetun</strong></summary>

| Variable | Description |
|---|---|
| `VPN_SERVICE_PROVIDER` | VPN provider name |
| `VPN_TYPE` | VPN protocol (`wireguard`) |
| `VPN_ENDPOINT_IP` | VPN server IP |
| `VPN_ENDPOINT_PORT` | VPN server port |
| `WIREGUARD_PUBLIC_KEY` | WireGuard public key |
| `WIREGUARD_PRIVATE_KEY` | WireGuard private key |
| `WIREGUARD_ADDRESSES` | WireGuard client address |
| `FIREWALL_VPN_INPUT_PORTS` | Allowed inbound ports through VPN |
| `GLUETUN_QBITTORRENT_WEBUI_PORT` | Host port for qBittorrent web UI |
| `GLUETUN_SOULSEEK_WEBUI_PORT` | Host port for Soulseek noVNC UI |
| `QBITTORRENT_CONFIG_DIR` | Host path for qBittorrent config |
| `QBITTORRENT_DOWNLOADS_DIR` | Host path for downloads |
| `SOULSEEK_APPDATA_DIR` | Host path for Soulseek app data |
| `MEDIA_MUSIC_DIR` | Shared music library path |
| `MEDIA_MOVIES_DIR` | Shared movies library path |
| `MEDIA_SERIES_DIR` | Shared series library path |

</details>

<details>
<summary><strong>🎮 Minecraft</strong></summary>

| Variable | Description |
|---|---|
| `MINECRAFT_PORT` | Host port for the server |
| `EULA` | Accept Minecraft EULA (`TRUE`) |
| `VERSION` | Minecraft version to run |
| `MINECRAFT_DATA_DIR` | Host path for world/server data |

</details>

<details>
<summary><strong>🌡️ CoolerControl</strong></summary>

| Variable | Description |
|---|---|
| `COOLERCONTROL_PORT` | Host port for web UI |
| `COOLERCONTROL_CONFIG_DIR` | Host path for configuration |

</details>

<details>
<summary><strong>🚫 AdGuard Home</strong></summary>

| Variable | Description |
|---|---|
| `ADGUARD_CONFIG_DIR` | Host path for AdGuard Home configuration |
| `ADGUARD_WORK_DIR` | Host path for AdGuard Home runtime data |
| `ADGUARD_DNS_PORT` | Host port for DNS (default `53`) |
| `ADGUARD_WEB_PORT` | Host port for web dashboard (default `3000`) |

</details>

<details>
<summary><strong>🛡️ Authelia</strong></summary>

| Variable | Description |
|---|---|
| `AUTHELIA_PORT` | Host port for Authelia web UI |
| `AUTHELIA_CONFIG_DIR` | Host path for Authelia configuration |
| `AUTHELIA_JWT_SECRET` | JWT secret for identity validation |
| `AUTHELIA_SESSION_SECRET` | Session encryption secret |
| `AUTHELIA_STORAGE_ENCRYPTION_KEY` | Storage encryption key |

</details>

<details>
<summary><strong>💬 Matrix Synapse + Element</strong></summary>

| Variable | Description |
|---|---|
| `SYNAPSE_HTTP_PORT` | Host port for Synapse HTTP API |
| `SYNAPSE_DATA_DIR` | Host path for Synapse data (homeserver.yaml, media, keys) |
| `SYNAPSE_DB_DIR` | Host path for PostgreSQL data files |
| `SYNAPSE_POSTGRES_DB` | PostgreSQL database name |
| `SYNAPSE_POSTGRES_USER` | PostgreSQL user |
| `SYNAPSE_POSTGRES_PASSWORD` | PostgreSQL password |
| `ELEMENT_HTTP_PORT` | Host port for Element Web UI |
| `ELEMENT_CONFIG_FILE` | Path to Element Web config.json on host |

</details>

<details>
<summary><strong>📊 Monitoring Stack</strong></summary>

| Variable | Description |
|---|---|
| `MONITORING_DATA_DIR` | Host path for persistent data (Prometheus TSDB, Loki chunks) |
| `GRAFANA_HTTP_PORT` | Host port for Grafana web UI (default `3100`) |
| `GF_SECURITY_ADMIN_USER` | Grafana admin username |
| `GF_SECURITY_ADMIN_PASSWORD` | Grafana admin password |
| `PROMETHEUS_PORT` | Host port for Prometheus (default `9090`, 127.0.0.1 only) |
| `LOKI_PORT` | Host port for Loki (default `3101`, 127.0.0.1 only) |
| `NODE_EXPORTER_PORT` | Host port for Node Exporter (default `9100`, 127.0.0.1 only) |

</details>

<details>
<summary><strong>📄 BentoPDF</strong></summary>

| Variable | Description |
|---|---|
| `PUID` | User ID for file permissions |
| `PGID` | Group ID for file permissions |
| `BENTOPDF_HTTP_PORT` | Host port for BentoPDF web UI (default `8084`) |

</details>

<details>
<summary><strong>📝 TriliumNext Notes</strong></summary>

| Variable | Description |
|---|---|
| `TZ` | Timezone |
| `TRILIUM_HTTP_PORT` | Host port for TriliumNext web UI (default `8085`) |
| `TRILIUM_DATA_DIR` | Host path for persistent note data, config, and backups |

</details>
