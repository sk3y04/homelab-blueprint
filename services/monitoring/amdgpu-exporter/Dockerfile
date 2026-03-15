FROM python:3.12-alpine

LABEL maintainer="homelab-blueprint"
LABEL description="Prometheus exporter for AMD GPU metrics — reads amdgpu sysfs interface (RX 570)"

WORKDIR /app
COPY exporter.py .

EXPOSE 9835

USER nobody
ENTRYPOINT ["python", "exporter.py"]
