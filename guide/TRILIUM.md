# 📝 TriliumNext Notes — Personal Knowledge Base

> [!NOTE]
> This document is an **example template**. All domain names, IP addresses, and service details are fictional and used for illustration purposes only. Replace them with your own values.

TriliumNext Notes is a hierarchical note-taking application built for building large personal knowledge bases. It features rich WYSIWYG editing, code blocks with syntax highlighting, Markdown support, note relations/links, full-text search, scripting, and end-to-end encrypted sync between server and desktop clients.

---

## Table of Contents

- [Architecture](#architecture)
- [Step 1 — DNS Record](#step-1--dns-record)
- [Step 2 — Docker Compose](#step-2--docker-compose)
- [Step 3 — Access and Configuration](#step-3--access-and-configuration)
- [Step 4 — VPS Nginx Configuration](#step-4--vps-nginx-configuration)
- [Sync with Desktop Client](#sync-with-desktop-client)
- [Backups](#backups)

---

## Architecture

TriliumNext runs as a single Node.js application with an embedded SQLite database. No external database service is required.

- **Web UI:** Port `8085` (HTTP) — Use HTTPS behind a reverse proxy.
- **Sync API:** Same port — desktop clients connect here for bi-directional sync.
- **Data:** All notes, attachments, revision history, and configuration are stored in a single directory (`trilium-data`).

---

## Step 1 — DNS Record

Add a DNS record for TriliumNext:

| Subdomain | Points to |
|---|---|
| `notes.example.com` | VPS public IP |

---

## Step 2 — Docker Compose

See [services/trilium/docker-compose.yml](../services/trilium/docker-compose.yml).

Ensure you have a `.env` file with the necessary variables (`TRILIUM_HTTP_PORT`, `TRILIUM_DATA_DIR`, `TZ`).

---

## Step 3 — Access and Configuration

1. **Start the container:**

   ```bash
   cd services/trilium/
   docker compose up -d
   ```

2. **Initial setup:** Open `http://<HOME_SERVER_IP>:8085` in your browser. On the first run, TriliumNext will present a setup wizard where you:
   - Choose between a **new document** or **sync from server**.
   - Set your **password** — this protects your notes and is used for encryption.

3. **Usage:** After setup, log in with your password. You can immediately start creating notes, organizing them in the tree hierarchy, and using features like:
   - Rich text / Markdown / code note types
   - Note cloning (same note in multiple places)
   - Relation maps and link maps
   - Custom scripting (JavaScript)
   - Full-text search across all notes

> [!IMPORTANT]
> **Remember your password.** TriliumNext uses it to derive encryption keys. There is no password recovery mechanism — if you lose it, your encrypted sync data cannot be decrypted.

---

## Step 4 — VPS Nginx Configuration

To access TriliumNext securely via `notes.example.com`:

**Upstream** (add to `services.conf`):

```nginx
upstream trilium_upstream {
    server 10.8.0.2:8085; # Your VPN IP and port
}
```

**Server Block** (add to `services.conf`):

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name notes.example.com;

    # ... SSL certificates ...

    location / {
        # Recommended: Add Authelia protection for security
        auth_request /authelia;

        proxy_pass http://trilium_upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        # WebSocket support — required for sync and live updates.
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

> [!TIP]
> If you use the TriliumNext desktop client to sync with the server, the Authelia gate will require you to authenticate in the desktop client's browser. Alternatively, you can configure Authelia to bypass the sync API path (`/api/sync/*`) and rely on TriliumNext's built-in password authentication for sync.

---

## Sync with Desktop Client

TriliumNext supports real-time sync between the server instance and one or more desktop clients:

1. **Download** the [TriliumNext desktop app](https://github.com/TriliumNext/Notes/releases).
2. On first launch, select **"I have a server instance already, and I want to set up sync with it"**.
3. Enter the server address: `https://notes.example.com`
4. Enter your password.
5. The desktop client will pull all notes from the server and keep them synchronized.

> [!NOTE]
> Sync is bi-directional — changes on the server or any client are propagated automatically. Conflicts are handled by keeping both versions.

---

## Backups

TriliumNext automatically creates daily backups of the database inside the `trilium-data/backup` directory. You can also:

- **Manual backup:** Use the built-in backup function from the TriliumNext menu (`Menu → Export → Backup database`).
- **External backup:** Simply back up the entire `trilium-data` directory (the path set in `TRILIUM_DATA_DIR`). The SQLite database file (`document.db`) contains all notes and attachments.

> [!TIP]
> For a consistent backup, stop the container first or use SQLite's `.backup` command to avoid copying a database mid-write.
