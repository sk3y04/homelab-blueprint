#!/usr/bin/env bash
# --------------------------------------------------------------------------
# AI Stack — Health Check
# --------------------------------------------------------------------------
# Checks the health of all AI stack services and the GPU.
# Exit code 0 = all healthy, 1 = at least one problem.
# --------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

FAIL=0
OLLAMA_PORT=${OLLAMA_PORT:-11434}
OPEN_WEBUI_PORT=${OPEN_WEBUI_PORT:-8080}
OPENCODE_PORT=${OPENCODE_PORT:-4096}
DCGM_EXPORTER_PORT=${DCGM_EXPORTER_PORT:-9400}
OPENCODE_USERNAME=${OPENCODE_SERVER_USERNAME:-opencode}
OPENCODE_PASSWORD=${OPENCODE_SERVER_PASSWORD:-}

echo "=== AI Stack Health Check ==="
echo ""

# ── Docker Compose services ──────────────────────────────────────────────
echo "── Container Status ──"
docker compose ps --format "table {{.Name}}\t{{.Status}}"
echo ""

# Check each service individually.
for svc in ollama open-webui opencode openclaw dcgm-exporter; do
  container="ai-${svc}"
  status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "not-found")
  case "$status" in
    healthy)   printf "  ✓ %-20s healthy\n" "$container" ;;
    unhealthy) printf "  ✗ %-20s UNHEALTHY\n" "$container"; FAIL=1 ;;
    starting)  printf "  … %-20s starting\n" "$container" ;;
    *)         printf "  ✗ %-20s %s\n" "$container" "$status"; FAIL=1 ;;
  esac
done
echo ""

# ── Ollama API ───────────────────────────────────────────────────────────
echo "── Ollama API ──"
if curl -sf "http://127.0.0.1:${OLLAMA_PORT}/" >/dev/null 2>&1; then
  echo "  ✓ Ollama API responding on :${OLLAMA_PORT}"
  echo "  Loaded models:"
  curl -sf "http://127.0.0.1:${OLLAMA_PORT}/api/tags" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('models', []):
    size_gb = m.get('size', 0) / (1024**3)
    print(f\"    - {m['name']}  ({size_gb:.1f} GB)\")
" 2>/dev/null || echo "    (could not parse model list)"
else
  echo "  ✗ Ollama API not responding"; FAIL=1
fi
echo ""

# ── Open WebUI ───────────────────────────────────────────────────────────
echo "── Open WebUI ──"
if curl -sf "http://127.0.0.1:${OPEN_WEBUI_PORT}/health" >/dev/null 2>&1; then
  echo "  ✓ Open WebUI healthy on :${OPEN_WEBUI_PORT}"
else
  echo "  ✗ Open WebUI not responding"; FAIL=1
fi
echo ""

# ── OpenCode ─────────────────────────────────────────────────────────────
echo "── OpenCode ──"
if curl -sf -u "$OPENCODE_USERNAME:$OPENCODE_PASSWORD" "http://127.0.0.1:${OPENCODE_PORT}/global/health" >/dev/null 2>&1; then
  echo "  ✓ OpenCode healthy on :${OPENCODE_PORT}"
else
  echo "  ✗ OpenCode not responding"; FAIL=1
fi
echo ""

# ── GPU Status ───────────────────────────────────────────────────────────
echo "── GPU Status ──"
if command -v nvidia-smi &>/dev/null; then
  nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw,power.limit \
    --format=csv,noheader,nounits | while IFS=, read -r name temp util mem_used mem_total power power_limit; do
    printf "  GPU:   %s\n" "$(echo "$name" | xargs)"
    printf "  Temp:  %s °C\n" "$(echo "$temp" | xargs)"
    printf "  Util:  %s %%\n" "$(echo "$util" | xargs)"
    printf "  VRAM:  %s / %s MiB\n" "$(echo "$mem_used" | xargs)" "$(echo "$mem_total" | xargs)"
    printf "  Power: %s / %s W\n" "$(echo "$power" | xargs)" "$(echo "$power_limit" | xargs)"
  done
else
  echo "  ✗ nvidia-smi not found on host"; FAIL=1
fi
echo ""

# ── DCGM Exporter ────────────────────────────────────────────────────────
echo "── DCGM Exporter ──"
if curl -sf "http://127.0.0.1:${DCGM_EXPORTER_PORT}/metrics" >/dev/null 2>&1; then
  metric_count=$(curl -sf "http://127.0.0.1:${DCGM_EXPORTER_PORT}/metrics" | grep -c "^DCGM_" || true)
  echo "  ✓ DCGM exporter healthy on :${DCGM_EXPORTER_PORT} ($metric_count metrics)"
else
  echo "  ✗ DCGM exporter not responding on :${DCGM_EXPORTER_PORT}"; FAIL=1
fi
echo ""

echo "================================"
if [ $FAIL -eq 0 ]; then
  echo "All checks passed."
else
  echo "Some checks FAILED — review output above."
fi
exit $FAIL
