# 📡 Matrix Synapse — Federated Messaging

> [!NOTE]
> This document is an **example template**. All domain names, IP addresses, and service details are fictional and used for illustration purposes only. Replace them with your own values.

Matrix Synapse is a homeserver implementation of the Matrix standard, allowing you to self-host real-time communication.

---

## Table of Contents

- [Architecture](#architecture)
- [Step 1 — DNS Records](#step-1--dns-records)
- [Step 2 — Docker Compose](#step-2--docker-compose)
- [Step 3 — Initial Setup](#step-3--initial-setup)
- [Step 4 — VPS Nginx Configuration](#step-4--vps-nginx-configuration)
- [Step 5 — Federation Configuration](#step-5--federation-configuration)

---

## Architecture

Run Matrix Synapse with a PostgreSQL database and Element Web client.

- **Synapse:** Port `8008` (HTTP) - Federation & Client API.
- **Element Web:** Port `80` (HTTP) - Browser client.
- **PostgreSQL:** Port `5432` (Internal).

---

## Step 1 — DNS Records

Add DNS records for the Matrix homeserver and Element client:

| Subdomain | Points to |
|---|---|
| `matrix.example.com` | VPS public IP |
| `element.example.com` | VPS public IP |
| `_matrix._tcp.example.com` | SRV: `0 10 443 matrix.example.com` |

If you want user IDs like `@user:example.com` (base domain), configure `.well-known` delegation (see below).

---

## Step 2 — Docker Compose

See [services/matrix-synapse/docker-compose.yml](../services/matrix-synapse/docker-compose.yml).

Ensure you have a `.env` file with the necessary variables (`SYNAPSE_POSTGRES_PASSWORD`, `ELEMENT_HTTP_PORT`).

---

## Step 3 — Initial Setup

1. **Wait for Start:** The container might take a few minutes to generate keys and config.
2. **First User:** Create an admin user via command line:
   ```bash
   docker exec -it synapse register_new_matrix_user -c /data/homeserver.yaml http://localhost:8008
   ```
   Follow the prompts to create an admin user.

3. **Element Config:** Edit `element-config.json` to point `default_server_name` to your domain.

---

## Step 4 — VPS Nginx Configuration

To access Matrix and Element securely:

**Upstreams** (add to `services.conf`):

```nginx
upstream synapse_upstream {
    server 10.8.0.2:8008; 
}
upstream element_upstream {
    server 10.8.0.2:80;
}
```

**Synapse Server Block** (Client/Federation API):

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name matrix.example.com;

    # ... SSL certificates ...
    
    # Increase upload size limit for media
    client_max_body_size 50M;

    location / {
        proxy_pass http://synapse_upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto https;
    }
}
```

**Element Web Server Block:**

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name element.example.com;

    # ... SSL certificates ...

    location / {
        # Optional: Add Authelia protection for the client UI
        # auth_request /authelia;
        
        proxy_pass http://element_upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
```

---

## Step 5 — Federation Configuration

To ensure federation works correctly (other servers can talk to yours), serve `.well-known` files on your **base domain** (`example.com`).

Create a file `matrix.json` (or configure Nginx to return JSON directly):

```json
{
  "m.server": "matrix.example.com:443"
}
```

Serve this at `https://example.com/.well-known/matrix/server`.

Create a file `client.json`:

```json
{
  "m.homeserver": {
    "base_url": "https://matrix.example.com"
  },
  "m.identity_server": {
    "base_url": "https://vector.im"
  }
}
```

Serve this at `https://example.com/.well-known/matrix/client`.
