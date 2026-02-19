# 📡 Nextcloud — Personal Cloud & Collaboration

> [!NOTE]
> This document is an **example template**. All domain names, IP addresses, and service details are fictional and used for illustration purposes only. Replace them with your own values.

Nextcloud provides file storage, synchronization, and collaboration features similar to Drobox/Google Drive but self-hosted.

---

## Table of Contents

- [Architecture](#architecture)
- [Step 1 — DNS Record](#step-1--dns-record)
- [Step 2 — Docker Compose](#step-2--docker-compose)
- [Step 3 — Initial Setup](#step-3--initial-setup)
- [Step 4 — VPS Nginx Configuration](#step-4--vps-nginx-configuration)
- [Step 5 — Recommended Apps](#step-5--recommended-apps)

---

## Architecture

Run Nextcloud with a database (MariaDB) and Redis cache for performance.

- **Web UI:** Port `80` (HTTP) - Use HTTPS behind a reverse proxy.
- **Database:** MariaDB (Port 3306)
- **Cache:** Redis (Port 6379)

---

## Step 1 — DNS Record

Add a DNS record for the Nextcloud installation:

| Subdomain | Points to |
|---|---|
| `cloud.example.com` | VPS public IP |

---

## Step 2 — Docker Compose

See [services/nextcloud/docker-compose.yml](../services/nextcloud/docker-compose.yml).

Ensure you have a `.env` file with the necessary variables (`MYSQL_PASSWORD`, `REDIS_PASSWORD`, paths).

---

## Step 3 — Initial Setup

1. **Wait for Start:** The container might take a few minutes to initialize the database schema.
2. **Access Web UI:** Open `http://<HOME_SERVER_IP>:80` in your browser.
3. **Database Setup:**
   - **Database user:** `nextcloud` (or your env var)
   - **Database password:** `your-secret-password`
   - **Database name:** `nextcloud`
   - **Host:** `db`

4. **Install:** Click **Finish setup**.
5. **Add Admin User:** Create your admin account.

---

## Step 4 — VPS Nginx Configuration

To access Nextcloud securely via `cloud.example.com`:

**Upstream** (add to `services.conf`):

```nginx
upstream nextcloud_upstream {
    server 10.8.0.2:80; # Your VPN IP and port
}
```

**Server Block** (add to `services.conf`):

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name cloud.example.com;

    # ... SSL certificates ...
    
    # Increase upload size limit
    client_main_body_size 10G; 

    location / {
        proxy_pass http://nextcloud_upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        
        # Nextcloud header requirements
        add_header Strict-Transport-Security "max-age=15552000; includeSubDomains" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header X-Robots-Tag "none" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
    }
}
```

---

## Step 5 — Recommended Apps

- **Calendar & Contacts:** Sync with CalDAV/CardDAV.
- **Collabora Online:** Office suite integration (requires separate container).
- **Video Player:** Play videos directly in the browser.
- **Two-Factor Authentication:** Enable for extra security (Authelia is also supported).
