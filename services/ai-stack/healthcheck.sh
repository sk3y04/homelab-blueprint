#!/usr/bin/env bash
# --------------------------------------------------------------------------
# AI Stack — Health Check
# --------------------------------------------------------------------------
# Checks the health of all AI stack services and the GPU.
# Exit code 0 = all healthy, 1 = at least one problem.
# --------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

FAIL=0

echo "=== AI Stack Health Check ==="
echo ""

# ── Docker Compose services ──────────────────────────────────────────────
echo "── Container Status ──"
docker compose ps --format "table {{.Name}}\t{{.Status}}"
echo ""

# Check each service individually.
for svc in ollama open-webui openclaw dcgm-exporter; do
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
if curl -sf http://127.0.0.1:11434/ >/dev/null 2>&1; then
  echo "  ✓ Ollama API responding on :11434"
  echo "  Loaded models:"
  curl -sf http://127.0.0.1:11434/api/tags | python3 -c "
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
if curl -sf http://127.0.0.1:8080/health >/dev/null 2>&1; then
  echo "  ✓ Open WebUI healthy on :8080"
else
  echo "  ✗ Open WebUI not responding"; FAIL=1
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
if curl -sf http://127.0.0.1:9400/metrics >/dev/null 2>&1; then
  metric_count=$(curl -sf http://127.0.0.1:9400/metrics | grep -c "^DCGM_" || true)
  echo "  ✓ DCGM exporter healthy on :9400 ($metric_count metrics)"
else
  echo "  ✗ DCGM exporter not responding on :9400"; FAIL=1
fi
echo ""

echo "================================"
if [ $FAIL -eq 0 ]; then
  echo "All checks passed."
else
  echo "Some checks FAILED — review output above."
fi
exit $FAIL
