# 🖼 Stirling Image — Self-Hosted Image Toolkit

> [!NOTE]
> This document is an **example template**. All domain names, IP addresses, and service details are fictional and used for illustration purposes only. Replace them with your own values.

Stirling Image is a single-container image processing platform with a browser UI and REST API. It bundles common image operations such as resize, crop, compress, convert, watermarking, OCR, background removal, and batch workflows into one self-hosted service.

---

## Table of Contents

- [Architecture](#architecture)
- [Step 1 — DNS Record](#step-1--dns-record)
- [Step 2 — Docker Compose](#step-2--docker-compose)
- [Step 3 — Access and Configuration](#step-3--access-and-configuration)
- [Step 4 — VPS Nginx Configuration](#step-4--vps-nginx-configuration)

---

## Architecture

Stirling Image runs as a single container that serves both the frontend UI and backend API.

- **Web UI / API:** Port `1349` (HTTP) — use HTTPS behind a reverse proxy.
- **Persistent storage:** `/data` stores the SQLite database, users, API keys, saved pipelines, and uploaded files.
- **Workspace:** `/tmp/workspace` holds temporary image-processing artifacts and can grow during larger jobs.
- **Auth:** The Docker image defaults to app-level authentication enabled. Initial admin credentials are seeded only on first run.

> [!IMPORTANT]
> Align your reverse proxy's `client_max_body_size` with `MAX_UPLOAD_SIZE_MB`. If nginx allows smaller requests than Stirling Image, uploads will fail before they ever reach the app.

---

## Step 1 — DNS Record

Add a DNS record for Stirling Image:

| Subdomain | Points to |
|---|---|
| `images.example.com` | VPS public IP |

---

## Step 2 — Docker Compose

See [services/stirling-image/docker-compose.yml](../services/stirling-image/docker-compose.yml).

Ensure you have a `.env` file with at least these variables:

- `STIRLING_IMAGE_HTTP_PORT`
- `STIRLING_IMAGE_DATA_DIR`
- `STIRLING_IMAGE_WORKSPACE_DIR`
- `AUTH_ENABLED`, `DEFAULT_USERNAME`, `DEFAULT_PASSWORD`

Recommended tuning variables:

- `MAX_UPLOAD_SIZE_MB`
- `MAX_BATCH_SIZE`
- `CONCURRENT_JOBS`
- `MAX_MEGAPIXELS`
- `RATE_LIMIT_PER_MIN`

---

## Step 3 — Access and Configuration

1. **Start the container:**

   ```bash
   cd services/stirling-image/
   docker compose up -d
   ```

2. **Access Web UI:** Open `http://<HOME_SERVER_IP>:1349` in your browser.

3. **First login:** Sign in with the values from `DEFAULT_USERNAME` and `DEFAULT_PASSWORD`.

4. **Immediate post-install tasks:**
   - Change the default admin password after the first login.
   - Verify that `STIRLING_IMAGE_DATA_DIR` is on persistent storage before creating users, API keys, or saved pipelines.
   - Test an upload near your configured `MAX_UPLOAD_SIZE_MB` so you can confirm nginx and the application limits match.

5. **Usage notes:**
   - All tools are also exposed through the REST API, so you can automate conversions or build small internal workflows around the service.
   - The container ships with OCR, ImageMagick, and several ML-assisted tools baked in, so it works offline once the image is pulled.

> [!TIP]
> If you expect large batch jobs or OCR-heavy work, place `STIRLING_IMAGE_WORKSPACE_DIR` on fast local storage and keep `CONCURRENT_JOBS` conservative until you have observed memory usage on your host.

---

## Step 4 — VPS Nginx Configuration

To access Stirling Image securely via `images.example.com`:

**Upstream** (add to `services.conf`):

```nginx
upstream stirling_image_upstream {
    server 10.8.0.2:1349; # Your VPN IP and port
}
```

**Server Block** (add to `services.conf`):

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name images.example.com;

    # ... SSL certificates ...

    client_max_body_size 100M;

    location / {
        proxy_pass http://stirling_image_upstream;

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Ssl on;

        proxy_connect_timeout 60s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }
}
```

> [!IMPORTANT]
> Prefer Stirling Image's own authentication instead of layering reverse-proxy auth in front of it. The application has its own users, sessions, and API keys; keeping login inside the app avoids awkward double-auth flows and makes API usage simpler.