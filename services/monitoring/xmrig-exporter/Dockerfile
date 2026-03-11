FROM python:3.12-alpine

LABEL maintainer="homelab-blueprint"
LABEL description="Prometheus exporter for XMRig mining — translates JSON API to Prometheus text format"

WORKDIR /app
COPY exporter.py .

EXPOSE 9189

USER nobody
ENTRYPOINT ["python", "exporter.py"]
