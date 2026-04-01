# OpenClaw — Self-Hosted AI Agent Gateway

Standalone deployment of [OpenClaw](https://github.com/openclaw/openclaw), a
self-hosted personal AI assistant gateway that bridges messaging platforms
(Discord, WhatsApp, Telegram, etc.) to local AI agents.

OpenClaw connects to Ollama on the same Docker host for LLM inference. It was
previously an experimental profile inside the AI stack and has been separated
into its own compose project for independent lifecycle management.

> **Compose project**: `services/openclaw/`
> **Full operational docs**: `services/openclaw/README.md`

```
┌─── openclaw network ────────────────┐
│  openclaw-gateway:18789             │
└─────────────────────────────────────┘
         │
         └── joins ─► ai-stack network
                         └── ollama:11434 (LLM backend)
```

## Quick Start

```bash
# 1. Create RAID6 directories
mkdir -p /home/skey/raid6/openclaw/{data,workspace,logs,backups}
chown -R 1000:1000 /home/skey/raid6/openclaw

# 2. Configure
cd services/openclaw
cp .env.example .env
# Edit .env — set OPENCLAW_GATEWAY_TOKEN (openssl rand -hex 32)

# 3. Ensure ai-stack is running (provides Ollama + the ai-stack network)
cd ../ai-stack && ./start.sh
cd ../openclaw

# 4. Start OpenClaw
docker compose up -d

# 5. Verify
curl -sf http://127.0.0.1:18789/healthz && echo "OK"
```

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Compose project | Standalone (`services/openclaw/`) | Independent upgrade/restart lifecycle |
| Ollama connectivity | External network join (`ai-stack`) | Docker DNS, no host port exposure |
| Config format | Official `openclaw.json` | Aligned with upstream docs |
| Port | 18789 (official) | Matches upstream defaults |
| Storage | RAID6 bind mounts | Survives container recreation and upgrades |
| Exposure | `127.0.0.1` only | Not accessible from LAN or reverse proxy |
| Image | Pinned release tag on GHCR | Reproducible, no surprise upgrades |

## Persistent Storage

All persistent data lives on RAID6 at `/home/skey/raid6/openclaw/`:

| Directory | Maps to | Purpose |
|-----------|---------|---------|
| `data/` | `/home/node/.openclaw` | Config, credentials, session state |
| `workspace/` | `/home/node/.openclaw/workspace` | Agent skills, project files |
| `logs/` | `/tmp/openclaw` | Rolling logs |
| `backups/` | *(host only)* | Tarball snapshots |

## LLM Configuration

OpenClaw talks to Ollama via Docker DNS at `http://ollama:11434/v1` using the
OpenAI-compatible API. No API key needed for local Ollama.

To use a LoRA persona model after training, update the `default_model` in
`openclaw.json` to `persona:latest` and restart.

## Operations

### Backup

```bash
cd services/openclaw
./scripts/backup.sh              # full backup
./scripts/backup.sh --data-only  # skip logs
```

### Update

```bash
cd services/openclaw
./scripts/update.sh                                      # pull configured tag
./scripts/update.sh ghcr.io/openclaw/openclaw:2026.3.15  # specific version
```

### Health Check

```bash
# Quick
curl -sf http://127.0.0.1:18789/healthz

# Full snapshot
docker compose exec openclaw-gateway node dist/index.js health --token "$OPENCLAW_GATEWAY_TOKEN"
```

### Logs

```bash
docker logs openclaw-gateway --tail 100 -f
```

If Promtail ships Docker container logs to Loki, filter by
`container_name="openclaw-gateway"` in Grafana.

## Discord Integration

When ready to connect OpenClaw to Discord:

1. Create a Discord bot at https://discord.com/developers/applications
2. Enable the **Message Content Intent** in Bot settings
3. Add the bot token to `.env` (not in committed files):
   ```
   OPENCLAW_DISCORD_TOKEN=your-bot-token-here
   ```
4. Configure `openclaw.json` with guild/channel IDs
5. Restart: `docker compose restart openclaw-gateway`

## Migration from AI Stack

If migrating from the previous `--profile openclaw` setup in `services/ai-stack/`:

1. Stop old container: `cd services/ai-stack && docker compose --profile openclaw stop openclaw`
2. Copy existing data: `cp -a /opt/ai-stack/data/openclaw/* /home/skey/raid6/openclaw/data/`
3. Convert `config.yaml` to official `openclaw.json` format (see upstream docs)
4. Start standalone: `cd services/openclaw && docker compose up -d`
5. Verify: `curl -sf http://127.0.0.1:18789/healthz`

## Troubleshooting

See `services/openclaw/README.md` for detailed troubleshooting covering:

- Gateway unreachable from host
- Cannot reach Ollama
- Permission denied on RAID6 directories
- OOM during startup
- Disk growth hotspots
