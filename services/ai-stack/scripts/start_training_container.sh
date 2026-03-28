#!/usr/bin/env bash
set -euo pipefail

TARGET_TRANSFORMERS_VERSION="${AI_TRAINING_TRANSFORMERS_VERSION:-5.2.0}"
AUTO_FIX_TRANSFORMERS="${AI_TRAINING_AUTO_FIX_TRANSFORMERS:-true}"

if [ "$AUTO_FIX_TRANSFORMERS" = "true" ]; then
  CURRENT_TRANSFORMERS_VERSION="$({ python - <<'PY'
import importlib.metadata as m

try:
    print(m.version("transformers"))
except Exception:
    print("")
PY
  } | tr -d '\r')"

  if [ "$CURRENT_TRANSFORMERS_VERSION" != "$TARGET_TRANSFORMERS_VERSION" ]; then
    echo "Normalizing transformers for Qwen3.5 training: ${CURRENT_TRANSFORMERS_VERSION:-missing} -> $TARGET_TRANSFORMERS_VERSION"
    pip uninstall -y transformers >/dev/null 2>&1 || true
    pip install --no-cache-dir "transformers==$TARGET_TRANSFORMERS_VERSION"
  fi
fi

exec bash