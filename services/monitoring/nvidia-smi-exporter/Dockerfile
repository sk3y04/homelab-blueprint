FROM python:3.12-slim

LABEL maintainer="homelab-blueprint"
LABEL description="Prometheus exporter for NVIDIA GPU metrics via nvidia-smi (RTX 3090 / Ampere)"

WORKDIR /app
COPY exporter.py .

EXPOSE 9835

# Health check: confirm the /health endpoint responds within 5 s.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:9835/health')"

# Do not run as nobody — NVIDIA device files injected by the Container
# Toolkit are owned by root:video and may not be accessible to unprivileged users.
ENTRYPOINT ["python3", "/app/exporter.py"]
