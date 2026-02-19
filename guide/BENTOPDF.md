# 📄 BentoPDF — Privacy-First PDF Toolkit

> [!NOTE]
> This document is an **example template**. All domain names, IP addresses, and service details are fictional and used for illustration purposes only. Replace them with your own values.

BentoPDF is a privacy-first PDF toolkit that processes all files locally in the browser using WebAssembly. No files are ever uploaded to a server — merge, split, compress, convert, and more, all client-side.

---

## Table of Contents

- [Architecture](#architecture)
- [Step 1 — DNS Record](#step-1--dns-record)
- [Step 2 — Docker Compose](#step-2--docker-compose)
- [Step 3 — Access and Configuration](#step-3--access-and-configuration)
- [Step 4 — VPS Nginx Configuration](#step-4--vps-nginx-configuration)

---

## Architecture

BentoPDF is a static web application served by nginx inside the container. All PDF processing is performed in the user's browser via WASM modules (PyMuPDF, Ghostscript, CoherentPDF, LibreOffice).

- **Web UI:** Port `8084` (HTTP) — Use HTTPS behind a reverse proxy.
- **Processing:** Entirely client-side; the server only serves static assets.

---

## Step 1 — DNS Record

Add a DNS record for BentoPDF:

| Subdomain | Points to |
|---|---|
| `pdf.example.com` | VPS public IP |

---

## Step 2 — Docker Compose

See [services/bentopdf/docker-compose.yml](../services/bentopdf/docker-compose.yml).

Ensure you have a `.env` file with the necessary variables (`BENTOPDF_HTTP_PORT`, `PUID`, `PGID`).

---

## Step 3 — Access and Configuration

1. **Start the container:**

   ```bash
   cd services/bentopdf/
   docker compose up -d
   ```

2. **Access Web UI:** Open `http://<HOME_SERVER_IP>:8084` in your browser.

3. **Usage:** All PDF tools are available immediately — no account or setup required. Upload files, process them, and download results. Everything stays in your browser.

> [!TIP]
> BentoPDF works fully offline once the page and WASM modules are loaded. For air-gapped environments, see the [BentoPDF self-hosting docs](https://github.com/alam00000/bentopdf/blob/main/docs/self-hosting/index.md).

---

## Step 4 — VPS Nginx Configuration

To access BentoPDF securely via `pdf.example.com`:

**Upstream** (add to `services.conf`):

```nginx
upstream bentopdf_upstream {
    server 10.8.0.2:8084; # Your VPN IP and port
}
```

**Server Block** (add to `services.conf`):

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name pdf.example.com;

    # ... SSL certificates ...

    location / {
        # Optional: Add Authelia protection to restrict access
        # auth_request /authelia;

        proxy_pass http://bentopdf_upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        # Required headers for SharedArrayBuffer (LibreOffice WASM tools)
        # These enable Word/Excel/PowerPoint to PDF conversion.
        proxy_hide_header Cross-Origin-Opener-Policy;
        proxy_hide_header Cross-Origin-Embedder-Policy;
        add_header Cross-Origin-Opener-Policy "same-origin" always;
        add_header Cross-Origin-Embedder-Policy "require-corp" always;
    }
}
```

> [!IMPORTANT]
> The `Cross-Origin-Opener-Policy` and `Cross-Origin-Embedder-Policy` headers are **required** for LibreOffice-based tools (Word, Excel, PowerPoint conversion). The BentoPDF container already sets these headers, but if your reverse proxy strips or overrides them, you must re-add them as shown above.
