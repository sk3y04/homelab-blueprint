# AI Stack — Ollama + Open WebUI + OpenClaw

Local LLM inference stack for an NVIDIA RTX 3090 24 GB. **Ollama** serves
quantized models via a REST API, **Open WebUI** provides a full-featured
chat interface, **OpenClaw** adds an agent layer with future Discord
integration, and **DCGM Exporter** feeds GPU metrics into the existing
homelab Prometheus + Grafana.

```
                  ┌────────────────┐
You ──► browser ──┤  Open WebUI    │
                  │  :8080         │──────► Ollama :11434 ◄── RTX 3090
                  └────────────────┘               ▲
                  ┌────────────────┐               │
Discord (future)──┤  OpenClaw      │───────────────┘
                  │  :8081         │
                  └────────────────┘

                  ┌────────────────┐
Prometheus ◄──────┤ DCGM Exporter  │◄── RTX 3090
(monitoring stack)│  :9400         │
                  └────────────────┘
```

## Table of Contents

1. [Architecture](#architecture)
2. [Folder Structure](#folder-structure)
3. [Prerequisites](#prerequisites)
4. [Host Setup](#host-setup)
5. [Quick Start](#quick-start)
6. [Model Strategy](#model-strategy)
7. [Model Bootstrap](#model-bootstrap)
8. [OpenClaw Configuration](#openclaw-configuration)
9. [GPU Power Management](#gpu-power-management)
10. [Monitoring](#monitoring)
11. [LoRA Training Pipeline](#lora-training-pipeline)
12. [Security](#security)
13. [Backup & Restore](#backup--restore)
14. [Validation Checklist](#validation-checklist)
15. [Troubleshooting](#troubleshooting)
16. [Upgrade Procedure](#upgrade-procedure)

---

## Architecture

### What runs where

| Layer | Component | Why |
|-------|-----------|-----|
| **Host** | NVIDIA driver, CUDA toolkit, NVIDIA Container Toolkit, Docker Engine + Compose plugin | Bare minimum on host — everything else in containers. |
| **Container** | `ai-ollama` | LLM runtime with GPU passthrough. |
| **Container** | `ai-open-webui` | Web chat UI. CPU only — talks to Ollama over Docker network. |
| **Container** | `ai-openclaw` | Agent layer. CPU only — talks to Ollama's OpenAI-compatible API. |
| **Container** | `ai-dcgm-exporter` | GPU metrics exporter. Joins the existing `monitoring` network. |

### Network layout

```
┌─── ai-stack network (bridge) ──────────────────────────────────┐
│  ollama:11434 ◄── open-webui ◄── openclaw                      │
│  dcgm-exporter:9400                                            │
└────────────────────────────────────────────────────────────────┘
         │
         ├── dcgm-exporter also joins ─► monitoring network (external)
         │                                  └── prometheus scrapes it
         │
         └── Host ports (all 127.0.0.1):
               :11434  Ollama API
               :8080   Open WebUI
               :8081   OpenClaw
               :9400   DCGM Exporter
```

### Persistent storage layout

All data under `$AI_DATA_DIR` (default `/opt/ai-stack/data`):

```
/opt/ai-stack/data/
├── ollama/          # Models, manifests, blobs (~20-40 GB per model)
├── open-webui/      # SQLite DB, chat history, user accounts
├── openclaw/        # Agent state and conversation logs
└── lora-adapters/   # Future: exported GGUF LoRA adapters
```

---

## Folder Structure

```
services/ai-stack/
├── docker-compose.yml
├── .env.example
├── Modelfile.persona.example
├── start.sh
├── stop.sh
├── update.sh
├── healthcheck.sh
├── set-gpu-inference.sh
├── set-gpu-training.sh
└── config/
    └── openclaw/
        └── config.yaml
```

Dashboard and scrape configs are added to the existing monitoring stack:

```
services/monitoring/
├── config/
│   ├── prometheus.yml                          # ← DCGM scrape target added
│   └── grafana/provisioning/dashboards/
│       └── ai-dcgm-gpu.json                   # ← new dashboard
```

---

## Prerequisites

| Requirement | Why |
|-------------|-----|
| Rocky Linux 10.x with kernel 6.12+ | Host OS. |
| NVIDIA driver 550+ | RTX 3090 support with CUDA 12.x. |
| CUDA Toolkit 12.x | Host-level CUDA libraries. |
| NVIDIA Container Toolkit | Passes the GPU into Docker containers. |
| Docker Engine 24+ with Compose v2 | Container runtime. |
| Monitoring stack running | `services/monitoring` must be up so the `monitoring` network exists. |

---

## Host Setup

These commands are for Rocky Linux 10. Run them once on the bare-metal host.

### 1. NVIDIA Driver + CUDA Toolkit

```bash
# Enable EPEL and CRB (CodeReady Builder)
sudo dnf install -y epel-release
sudo dnf config-manager --set-enabled crb

# Add NVIDIA CUDA repository
sudo dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo

# Install driver and CUDA toolkit
sudo dnf module install -y nvidia-driver:latest-dkms
sudo dnf install -y cuda-toolkit

# Reboot to load the new kernel module
sudo reboot

# Verify after reboot
nvidia-smi
# Should show RTX 3090, driver version 550+, CUDA 12.x
```

### 2. NVIDIA Container Toolkit

```bash
# Add the NVIDIA container toolkit repository
curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
  | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo

# Install
sudo dnf install -y nvidia-container-toolkit

# Register the NVIDIA runtime with Docker
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# Verify — should print RTX 3090 info inside a container
docker run --rm --gpus all nvidia/cuda:12.6.3-base-ubuntu22.04 nvidia-smi
```

### 3. Docker Engine (if not already installed)

```bash
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
# Log out and back in for group membership to take effect.
```

### 4. Create data directories

```bash
sudo mkdir -p /opt/ai-stack/data/{ollama,open-webui,openclaw,lora-adapters}
sudo chown -R "$(id -u):$(id -g)" /opt/ai-stack
```

### 5. Set inference power limit

```bash
cd services/ai-stack
sudo bash set-gpu-inference.sh
# Sets RTX 3090 to 285W for 24/7 operation.
```

---

## Quick Start

```bash
# 1. Copy and configure .env
cd services/ai-stack
cp .env.example .env
# Edit .env — at minimum set:
#   OPEN_WEBUI_SECRET_KEY  (openssl rand -hex 32)
#   AI_DATA_DIR            (or keep /opt/ai-stack/data)

# 2. Ensure the monitoring stack is running (provides the 'monitoring' network)
cd ../monitoring
docker compose up -d
cd ../ai-stack

# 3. Start the AI stack
chmod +x *.sh
./start.sh

# 4. Pull models (first run — takes 10-30 min depending on connection)
docker exec ai-ollama ollama pull qwen3:32b
docker exec ai-ollama ollama pull qwen3:14b

# 5. Open WebUI — create your admin account
# Open http://127.0.0.1:8080 in a browser.
# After creating the admin account, set OPEN_WEBUI_ENABLE_SIGNUP=false in .env
# and restart: docker compose up -d open-webui

# 6. Verify
./healthcheck.sh
```

---

## Model Strategy

### RTX 3090 24 GB VRAM Budget

| Model | Quant | VRAM (approx) | Use |
|-------|-------|---------------|-----|
| `qwen3:32b` | Q4_K_M | ~20 GB | Main general-purpose reasoning |
| `qwen3:14b` | Q5_K_M | ~11 GB | Base for future LoRA fine-tuning |
| `qwen3-coder:14b` | Q5_K_M | ~11 GB | Code generation and review |

**Important constraints:**

- Only **one 32B model** fits in 24 GB VRAM at a time. The 14B models can coexist with headroom.
- `OLLAMA_MAX_LOADED_MODELS=1` ensures Ollama unloads the previous model before loading a new one, preventing OOM.
- If Ollama does not yet carry `qwen3-coder` as a tagged model, use `qwen2.5-coder:14b` as an alternative. Check availability:

```bash
docker exec ai-ollama ollama list    # see what's available locally
ollama show qwen3-coder:14b          # check if the tag exists in the registry
```

### Quantization notes

- **Q4_K_M**: Best balance of quality vs VRAM for 32B models on 24 GB. Negligible quality loss for chat.
- **Q5_K_M**: Slightly higher quality, fits comfortably for 14B models.
- **Q8_0**: Only use for 7B or smaller models if you need near-FP16 quality.

---

## Model Bootstrap

### Pull initial models

```bash
# General purpose (largest, ~20 GB VRAM)
docker exec ai-ollama ollama pull qwen3:32b

# Base for future LoRA training
docker exec ai-ollama ollama pull qwen3:14b

# Coding — use the best available tag
docker exec ai-ollama ollama pull qwen3-coder:14b
# If that tag doesn't exist yet:
# docker exec ai-ollama ollama pull qwen2.5-coder:14b
```

### Test each model

```bash
# Quick test — general model
docker exec ai-ollama ollama run qwen3:32b "What is the capital of France? Answer in one sentence."

# Quick test — coding model
docker exec ai-ollama ollama run qwen3-coder:14b "Write a Python function that checks if a number is prime."

# Quick test — base model
docker exec ai-ollama ollama run qwen3:14b "Explain Docker networking in three sentences."
```

### Verify persistence

Models are stored in `$AI_DATA_DIR/ollama` (bind-mounted to `/root/.ollama` inside the container). They survive container restarts and image updates:

```bash
# List all downloaded models
docker exec ai-ollama ollama list

# Check disk usage
du -sh /opt/ai-stack/data/ollama/
```

### Create a custom model from a LoRA adapter

See `Modelfile.persona.example` in the AI stack directory. After training and exporting your LoRA adapter to GGUF format:

```bash
# 1. Place the adapter file
cp persona-adapter.gguf /opt/ai-stack/data/lora-adapters/

# 2. Add these volumes to the ollama service in docker-compose.yml:
#    - ./Modelfile.persona.example:/models/Modelfile.persona:ro
#    - /opt/ai-stack/data/lora-adapters:/lora-adapters:ro

# 3. Restart Ollama
docker compose restart ollama

# 4. Create the model
docker exec ai-ollama ollama create persona -f /models/Modelfile.persona

# 5. Test it
docker exec ai-ollama ollama run persona "Hey, what's up?"

# 6. Update OpenClaw config to use the persona model:
#    Edit config/openclaw/config.yaml → llm.default_model: persona:latest
#    Restart: docker compose restart openclaw
```

---

## OpenClaw Configuration

OpenClaw is configured via `config/openclaw/config.yaml`. Key settings:

- **Backend**: Points to `http://ollama:11434/v1` (OpenAI-compatible)
- **Default model**: `qwen3:32b` — change to `persona:latest` after training
- **Discord integration**: Disabled by default. Uncomment the `discord` section in the config when ready.

### Switching models

Edit `config/openclaw/config.yaml`:

```yaml
llm:
  default_model: persona:latest   # was: qwen3:32b
```

Then restart: `docker compose restart openclaw`

### Discord integration (future)

When ready to connect OpenClaw to Discord:

1. Create a Discord bot at https://discord.com/developers/applications
2. Enable the **Message Content Intent** in Bot settings
3. Edit `config/openclaw/config.yaml`:

```yaml
integrations:
  discord:
    enabled: true
    bot_token: "your-bot-token-here"
    guild_ids: [123456789]
    channel_ids: [987654321]
    model: persona:latest
```

4. Restart: `docker compose restart openclaw`

> **Security note**: Store the Discord bot token in `.env` and reference it via
> environment variable rather than hardcoding in the YAML, if OpenClaw supports
> `${DISCORD_BOT_TOKEN}` substitution. Check OpenClaw docs for the exact mechanism.

---

## GPU Power Management

### Inference mode (285W) — daily operation

```bash
sudo ./set-gpu-inference.sh
```

Reduces power limit to 285W. On quantized LLM inference, the difference vs 350W is negligible — the GPU is mostly memory-bandwidth-bound, not compute-bound. Saves ~20-65W continuous draw and reduces heat.

### Training mode (350W) — LoRA fine-tuning

```bash
sudo ./set-gpu-training.sh
```

Restores full 350W TDP. Use this before starting LoRA training runs, then switch back to inference mode when done.

### Persist across reboots

nvidia-smi settings reset on reboot. To persist:

```bash
# Option 1: cron
sudo crontab -e
# Add:
@reboot /path/to/services/ai-stack/set-gpu-inference.sh

# Option 2: systemd unit
sudo tee /etc/systemd/system/gpu-power-limit.service << 'EOF'
[Unit]
Description=Set GPU power limit for inference
After=nvidia-persistenced.service

[Service]
Type=oneshot
ExecStart=/usr/bin/nvidia-smi -pm 1
ExecStart=/usr/bin/nvidia-smi -pl 285
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable gpu-power-limit.service
```

---

## Monitoring

DCGM Exporter joins the existing `monitoring` network. The homelab Prometheus
(`services/monitoring`) scrapes it via the `dcgm-gpu` job. The GPU metrics
dashboard is provisioned into the existing Grafana automatically.

### Dashboard: AI Stack — DCGM GPU Metrics

Located at `services/monitoring/config/grafana/provisioning/dashboards/ai-dcgm-gpu.json`.

Panels:
- **GPU Utilization** — gauge + time series
- **VRAM Used / Free** — gauge + time series (thresholds at 18 GB / 22 GB)
- **Power Draw** — gauge + time series (threshold line at 340W)
- **GPU Temperature** — gauge + time series (GPU core + memory junction)
- **Clock Speeds** — SM clock + memory clock over time

### Key metrics to watch

| Metric | Alert threshold | Meaning |
|--------|----------------|---------|
| `DCGM_FI_DEV_GPU_UTIL` | Sustained 100% | Model may be too large or too many parallel requests |
| `DCGM_FI_DEV_FB_USED` | > 22528 MiB | Close to OOM — reduce `OLLAMA_NUM_PARALLEL` |
| `DCGM_FI_DEV_GPU_TEMP` | > 85°C | Check case airflow, fan curve |
| `DCGM_FI_DEV_POWER_USAGE` | > 340W | Should only happen in training mode |

### Log locations

```bash
# Ollama logs
docker logs ai-ollama --tail 100 -f

# Open WebUI logs
docker logs ai-open-webui --tail 100 -f

# OpenClaw logs
docker logs ai-openclaw --tail 100 -f

# DCGM Exporter logs
docker logs ai-dcgm-exporter --tail 100 -f

# All AI stack logs
docker compose -f services/ai-stack/docker-compose.yml logs --tail 100 -f
```

If the existing Promtail is configured to ship all Docker container logs to Loki, the AI stack container logs are automatically available in Grafana's log explorer — filter by `container_name=~"ai-.*"`.

---

## LoRA Training Pipeline

> This section documents the future workflow. The stack is prepared but the
> training container is not yet included in docker-compose.yml.

### Overview

1. **Export Discord conversations** → clean text dataset
2. **Format** → chat template (e.g. ShareGPT or Alpaca format)
3. **Train LoRA** → using `unsloth` or `axolotl` in a GPU container
4. **Export adapter** → GGUF format via `llama.cpp`
5. **Create Ollama model** → using `Modelfile.persona.example`
6. **Switch OpenClaw** → point to `persona:latest`

### Training container (to be added later)

```yaml
# Add to docker-compose.yml when ready:
training:
  image: unsloth/unsloth:latest   # or axolotl, verify current image
  container_name: ai-training
  profiles: ["training"]          # only starts with: docker compose --profile training up
  volumes:
    - /opt/ai-stack/data/training:/workspace
    - /opt/ai-stack/data/lora-adapters:/output
  deploy:
    resources:
      reservations:
        devices:
          - driver: nvidia
            count: all
            capabilities: [gpu, utility]
  networks:
    - ai-stack
```

Start training with: `docker compose --profile training run training`

The `profiles: ["training"]` key ensures it never starts during normal `docker compose up -d`.

---

## Security

### Port binding

All services bind to `127.0.0.1` — nothing is exposed to the LAN or internet by default.
Access services via SSH tunnel or add a reverse proxy (Caddy/nginx) later.

```bash
# SSH tunnel example to access Open WebUI from your workstation:
ssh -L 8080:127.0.0.1:8080 user@homeserver
# Then open: http://localhost:8080
```

### Secrets in .env

| Variable | Sensitivity | Generation |
|----------|------------|------------|
| `OPEN_WEBUI_SECRET_KEY` | High — session encryption | `openssl rand -hex 32` |
| `OPENCLAW_IMAGE` | Low — image reference | N/A |

Discord bot tokens (future) should also go in `.env`, never in committed config files.

### Least privilege

- Open WebUI and OpenClaw have **no GPU access** — they only talk to Ollama over HTTP.
- DCGM Exporter has `SYS_ADMIN` capability — required to read GPU counters. It has no network egress outside the Docker networks.
- No container has access to the Docker socket.

### When adding a reverse proxy

If you later expose Open WebUI via your VPS nginx + Authelia:
- Add rate limiting on the reverse proxy.
- Ensure `OPEN_WEBUI_ENABLE_SIGNUP=false` in `.env`.
- Consider adding authentication headers from Authelia.

---

## Backup & Restore

### What to back up

| Data | Path | Priority |
|------|------|----------|
| Ollama models | `$AI_DATA_DIR/ollama/` | Low — can re-pull from registry. Back up only custom models. |
| Open WebUI data | `$AI_DATA_DIR/open-webui/` | Medium — chat history, user accounts, settings. |
| OpenClaw data | `$AI_DATA_DIR/openclaw/` | Medium — agent state. |
| LoRA adapters | `$AI_DATA_DIR/lora-adapters/` | **High** — training output, expensive to reproduce. |
| Config files | `services/ai-stack/` | **High** — in Git, push regularly. |

### Backup script example

```bash
#!/usr/bin/env bash
BACKUP_DIR="/backup/ai-stack/$(date +%Y-%m-%d)"
mkdir -p "$BACKUP_DIR"

# Back up configs (already in git, but belt-and-suspenders)
tar czf "$BACKUP_DIR/config.tar.gz" -C /path/to/homelab-blueprint services/ai-stack/

# Back up Open WebUI data (SQLite — stop for consistency)
docker compose -f services/ai-stack/docker-compose.yml stop open-webui
cp -a /opt/ai-stack/data/open-webui "$BACKUP_DIR/"
docker compose -f services/ai-stack/docker-compose.yml start open-webui

# Back up LoRA adapters
cp -a /opt/ai-stack/data/lora-adapters "$BACKUP_DIR/"

echo "Backup complete: $BACKUP_DIR"
```

---

## Validation Checklist

Run through this after first deployment:

- [ ] `nvidia-smi` shows RTX 3090 on the host
- [ ] `docker run --rm --gpus all nvidia/cuda:12.6.3-base-ubuntu22.04 nvidia-smi` works
- [ ] `./start.sh` completes without errors
- [ ] `./healthcheck.sh` reports all services healthy
- [ ] `docker exec ai-ollama ollama list` shows pulled models
- [ ] Open WebUI loads at `http://127.0.0.1:8080`
- [ ] Can send a message in Open WebUI and get a response
- [ ] `curl http://127.0.0.1:9400/metrics | grep DCGM_FI_DEV_GPU_UTIL` returns a value
- [ ] Prometheus target page shows `dcgm-gpu` as UP
- [ ] Grafana "AI Stack — DCGM GPU Metrics" dashboard shows data
- [ ] GPU power limit reads 285W (`nvidia-smi -q -d POWER | grep "Power Limit"`)
- [ ] `docker exec ai-ollama ollama run qwen3:32b "Hello"` returns a response

---

## Troubleshooting

### DCGM Exporter fails to start on RTX 3090

DCGM is designed for datacenter GPUs (Tesla, A100, H100). On consumer GeForce/RTX cards, it may fail with `DCGM initialization error`. If this happens:

1. Try the `--no-dcgm-exporter` approach — remove the `dcgm-exporter` service and rely on the existing `nvidia-smi-exporter` from the monitoring stack (it already scrapes the same GPU).

2. Or try an older DCGM image that has better consumer GPU support:
   ```yaml
   image: nvidia/dcgm-exporter:3.1.7-3.1.4-ubuntu20.04
   ```

3. As a last resort, add `--collectors /etc/dcgm-exporter/default-counters.csv` to only collect basic metrics.

### Ollama OOM (out of memory)

```bash
# Check VRAM usage
nvidia-smi

# Reduce parallel slots
# In .env:
OLLAMA_NUM_PARALLEL=1

# Or switch to a smaller model
docker exec ai-ollama ollama run qwen3:14b "test"
```

### Open WebUI can't connect to Ollama

```bash
# Verify Ollama is healthy
docker exec ai-ollama curl -sf http://localhost:11434/

# Check the Docker network
docker network inspect ai-stack

# Verify both containers are on the same network
docker inspect ai-ollama --format='{{json .NetworkSettings.Networks}}' | python3 -m json.tool
docker inspect ai-open-webui --format='{{json .NetworkSettings.Networks}}' | python3 -m json.tool
```

### OpenClaw image not found

OpenClaw may not have an official Docker image yet. If `docker pull` fails:

1. Comment out the `openclaw` service in `docker-compose.yml`
2. Use Open WebUI's built-in Tools/Functions feature as an interim agent layer
3. Check https://github.com/openclaw for the latest installation instructions
4. If OpenClaw is installed from source, build a local image:
   ```bash
   git clone https://github.com/openclaw/openclaw.git /opt/openclaw
   cd /opt/openclaw
   docker build -t openclaw/openclaw:latest .
   ```

### Container can't join 'monitoring' network

```bash
# The monitoring stack must be running first
cd ../monitoring
docker compose up -d

# Verify the network exists
docker network ls | grep monitoring

# If it doesn't exist, create it manually
docker network create monitoring
```

### Slow inference

```bash
# Check if the GPU is actually being used
nvidia-smi   # GPU utilization should be > 0% during generation

# Verify flash attention is enabled
docker logs ai-ollama 2>&1 | grep -i flash

# Check if the model is CPU-offloaded (happens when VRAM is full)
docker logs ai-ollama 2>&1 | grep -i "offload\|cpu"
```

---

## Upgrade Procedure

```bash
cd services/ai-stack

# 1. Pull latest images
./update.sh

# 2. Verify health
./healthcheck.sh

# 3. Check for new model versions (optional)
docker exec ai-ollama ollama pull qwen3:32b
docker exec ai-ollama ollama pull qwen3:14b
```

Ollama model data is persistent — image updates do not affect downloaded models.
Open WebUI data (chat history, accounts) is persistent in the bind mount —
image updates do not affect it.
