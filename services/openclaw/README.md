# OpenClaw — Standalone Deployment

Standalone Docker Compose deployment of [OpenClaw](https://github.com/openclaw/openclaw),
a self-hosted personal AI assistant gateway. Separated from the main AI stack
for independent lifecycle management, upgrades, and storage.

## Architecture

```
 ┌─── openclaw network (bridge) ──────────┐
 │  openclaw-gateway:18789                │
 └────────────────────────────────────────┘
          │
          └── also joins ─► ai-stack network (external)
                               └── ollama:11434
```

OpenClaw connects to Ollama via Docker DNS on the shared `ai-stack` network.
The gateway port is published on `127.0.0.1` only — not exposed to the LAN.

## Prerequisites

- AI stack running (`services/ai-stack`) — provides Ollama and the `ai-stack` network
- RAID6 directories created and owned by `1000:1000`

## Quick Start

### 1. Create RAID6 directories

```bash
mkdir -p /home/skey/raid6/openclaw/{data,workspace,logs,backups}
chown -R 1000:1000 /home/skey/raid6/openclaw
```

### 2. Configure

```bash
cd services/openclaw
cp .env.example .env
# Edit .env — at minimum set:
#   OPENCLAW_GATEWAY_TOKEN  (openssl rand -hex 32)
```

### 3. Start

```bash
docker compose up -d
```

### 4. Verify

```bash
# Liveness probe
curl -sf http://127.0.0.1:18789/healthz

# Readiness probe
curl -sf http://127.0.0.1:18789/readyz

# Docker health status
docker inspect openclaw-gateway --format '{{.State.Health.Status}}'

# Full health snapshot (requires gateway token)
docker compose exec openclaw-gateway node dist/index.js health --token "$OPENCLAW_GATEWAY_TOKEN"

# Verify Ollama connectivity via Docker DNS
docker compose exec openclaw-gateway wget -qO- http://ollama:11434/api/tags
```

## Persistent Storage

All state lives on RAID6 via bind mounts:

| Host path | Container path | Purpose |
|-----------|---------------|---------|
| `$OPENCLAW_DATA_DIR` | `/home/node/.openclaw` | Config (`openclaw.json`), credentials, session state |
| `$OPENCLAW_WORKSPACE_DIR` | `/home/node/.openclaw/workspace` | Agent skills, AGENTS.md, project files |
| `$OPENCLAW_LOG_DIR` | `/tmp/openclaw` | Rolling logs (redirected from ephemeral container path) |
| `$OPENCLAW_BACKUP_DIR` | *(host only)* | Backup tarballs from `scripts/backup.sh` |

### File ownership

The official OpenClaw image runs as `node` (uid 1000, gid 1000). All RAID6
directories must be owned by `1000:1000`:

```bash
chown -R 1000:1000 /home/skey/raid6/openclaw
```

## LLM Configuration

OpenClaw is configured via `openclaw.json` inside the data directory. On first
run, the onboarding process generates this file. To pre-configure it for
Ollama, create `$OPENCLAW_DATA_DIR/openclaw.json`:

```json
{
  "provider": {
    "type": "openai",
    "base_url": "http://ollama:11434/v1",
    "api_key": "not-needed",
    "default_model": "qwen3.5:27b"
  }
}
```

> **Note**: The exact JSON schema depends on your OpenClaw version. Check the
> official docs at https://docs.openclaw.ai/config for the current format.

### Switching models

Edit `openclaw.json` and restart:

```bash
docker compose restart openclaw-gateway
```

After training a LoRA persona model and creating it in Ollama, change
`default_model` to `persona:latest`.

## Backup

```bash
# Full backup (config + workspace + logs)
./scripts/backup.sh

# Data only (skip logs)
./scripts/backup.sh --data-only
```

Backups are timestamped tarballs in `$OPENCLAW_BACKUP_DIR`. The script
automatically cleans up backups older than 30 days.

### What to back up

| Data | Priority | Notes |
|------|----------|-------|
| `$OPENCLAW_DATA_DIR` | **High** | Config, credentials, session state |
| `$OPENCLAW_WORKSPACE_DIR` | **High** | Agent skills and project files |
| `$OPENCLAW_LOG_DIR` | Low | Rolling logs, useful for debugging |

## Update

```bash
# Pull configured image and restart
./scripts/update.sh

# Override with a specific tag
./scripts/update.sh ghcr.io/openclaw/openclaw:2026.3.15
```

The update script pulls the image, recreates the container, waits for the
health check to pass, and prunes old images.

### Image pinning strategy

The `.env` pins OpenClaw to a dated release tag (e.g., `2026.2.26`) rather
than `:latest`. Before upgrading:

1. Check the [release notes](https://github.com/openclaw/openclaw/releases)
2. Back up first: `./scripts/backup.sh`
3. Update: `./scripts/update.sh ghcr.io/openclaw/openclaw:NEW_TAG`
4. Verify: `curl -sf http://127.0.0.1:18789/healthz`

## Log Management

OpenClaw writes rolling logs to `/tmp/openclaw/` inside the container. This
path is bind-mounted to `$OPENCLAW_LOG_DIR` on RAID6 for persistence.

**Warning**: Logs can grow unbounded. Set up rotation:

```bash
# Manual cleanup: delete logs older than 30 days
find /home/skey/raid6/openclaw/logs -type f -mtime +30 -delete
```

Or add a cron job:

```bash
# /etc/cron.daily/openclaw-log-cleanup
find /home/skey/raid6/openclaw/logs -type f -mtime +30 -delete
```

If Promtail is configured to ship all Docker container logs to Loki, OpenClaw
container logs are also available in Grafana — filter by
`container_name="openclaw-gateway"`.

## Discord Integration (Future)

When ready to enable Discord:

1. Create a Discord bot at https://discord.com/developers/applications
2. Enable the **Message Content Intent** in Bot settings
3. Add the bot token to `.env`:
   ```
   OPENCLAW_DISCORD_TOKEN=your-bot-token-here
   ```
4. Configure `openclaw.json` with Discord channel/guild IDs
5. Restart: `docker compose restart openclaw-gateway`

> **Security note**: Keep the bot token in `.env`, never in committed config
> files or `openclaw.json` in version control.

## Security

- **Non-root**: Runs as `node` (1000:1000), not root
- **No new privileges**: `security_opt: [no-new-privileges:true]`
- **Capabilities dropped**: `cap_drop: [ALL]`
- **Localhost only**: Port bound to `127.0.0.1`, not reachable from LAN
- **No Docker socket**: Sandboxing not enabled in this deployment
- **Auth token**: Gateway requires `OPENCLAW_GATEWAY_TOKEN` for admin access

## Troubleshooting

### Gateway unreachable from host

If `curl http://127.0.0.1:18789/healthz` fails:

```bash
# Check container status
docker compose ps
docker logs openclaw-gateway --tail 50

# Verify bind mode is 'lan' (not 'loopback')
grep OPENCLAW_GATEWAY_BIND .env
```

With Docker bridge networking, `--bind loopback` makes the gateway unreachable
from the host. Use `--bind lan` and rely on the `127.0.0.1` port binding.

### Cannot reach Ollama

```bash
# Verify both networks are attached
docker inspect openclaw-gateway --format='{{json .NetworkSettings.Networks}}' | python3 -m json.tool

# Verify ai-stack network exists
docker network ls | grep ai-stack

# Test DNS resolution
docker compose exec openclaw-gateway wget -qO- http://ollama:11434/ || echo "Ollama unreachable"
```

### Permission denied on RAID6 directories

```bash
# Check ownership
ls -la /home/skey/raid6/openclaw/

# Fix if needed
chown -R 1000:1000 /home/skey/raid6/openclaw
```

### OOM during startup

Set `NODE_OPTIONS=--max-old-space-size=2048` in `.env` (already configured by
default in the compose file). On hosts with <2 GB RAM for the container, this
prevents Node.js heap exhaustion.

## Disk Growth Hotspots

Watch these paths for unbounded growth:

| Path | Risk | Mitigation |
|------|------|------------|
| `$OPENCLAW_LOG_DIR` | Rolling logs | Cron cleanup or Promtail shipping |
| `$OPENCLAW_DATA_DIR/media/` | Session images/audio/video | Manual review |
| `$OPENCLAW_DATA_DIR/cron/runs/*.jsonl` | Cron execution history | Periodic cleanup |
