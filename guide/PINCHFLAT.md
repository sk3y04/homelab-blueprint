# 📺 Pinchflat — YouTube Media Manager

> [!NOTE]
> This document is an **example template**. All domain names, IP addresses, and service details are fictional and used for illustration purposes only. Replace them with your own values.

Pinchflat is a self-hosted YouTube media manager built around `yt-dlp`. It is best suited for recurring downloads from channels and playlists, with output written directly to disk for consumption by Jellyfin, podcast apps, VLC, or archive workflows.

---

## Table of Contents

- [Architecture](#architecture)
- [Step 1 — DNS Record](#step-1--dns-record)
- [Step 2 — Docker Compose](#step-2--docker-compose)
- [Step 3 — Access and Configuration](#step-3--access-and-configuration)
- [Recommended Jellyfin Layout](#recommended-jellyfin-layout)
- [Step 4 — VPS Nginx Configuration](#step-4--vps-nginx-configuration)
- [Step 5 — Optional Monitoring](#step-5--optional-monitoring)

---

## Architecture

Pinchflat runs as a single container with an embedded SQLite database stored under `/config` and downloaded media written under `/downloads`.

- **Web UI:** Port `8945` (HTTP) — Use HTTPS behind a reverse proxy.
- **Storage:** Two host-mounted paths: config/state and downloaded media.
- **Auth:** Prefer Pinchflat's built-in HTTP Basic Auth when exposing the app externally.
- **Realtime UI:** Reverse proxies must support WebSocket upgrades.

> [!IMPORTANT]
> Ensure both mounted host directories are writable by the UID/GID you assign to the container. Pinchflat explicitly checks file permissions at startup and will refuse to boot when mounts are not writable.

---

## Step 1 — DNS Record

Add a DNS record for Pinchflat:

| Subdomain | Points to |
|---|---|
| `pinchflat.example.com` | VPS public IP |

---

## Step 2 — Docker Compose

See [services/pinchflat/docker-compose.yml](../services/pinchflat/docker-compose.yml).

Ensure you have a `.env` file with the necessary variables:

- `PUID`, `PGID`, `TZ`
- `PINCHFLAT_HTTP_PORT`
- `PINCHFLAT_CONFIG_DIR`
- `PINCHFLAT_DOWNLOADS_DIR`

Optional but recommended:

- `BASIC_AUTH_USERNAME`, `BASIC_AUTH_PASSWORD`
- `EXPOSE_FEED_ENDPOINTS` for podcast/RSS consumers
- `ENABLE_PROMETHEUS` for metrics scraping

For a clean Jellyfin integration, set `PINCHFLAT_DOWNLOADS_DIR` to a dedicated YouTube root such as `/srv/media/youtube` or `/mnt/external/raid6/media/youtube` on the host. Pinchflat's Media Center preset will then create a `shows/` subtree beneath that root.

Example host result:

```text
/srv/media/youtube/
└── shows/
    └── My Channel Name/
        └── Season 2025/
            ├── s2025e031200 - Example Video Title.mp4
            ├── s2025e031200 - Example Video Title.nfo
            └── season-poster.jpg
```

---

## Step 3 — Access and Configuration

1. **Start the container:**

   ```bash
   cd services/pinchflat/
   docker compose up -d
   ```

2. **Access Web UI:** Open `http://<HOME_SERVER_IP>:8945` in your browser.

3. **First-run setup:**
    - Create a media profile and select the `Media Center` preset.
   - Add one or more YouTube channels or playlists as sources.
    - Keep the preset output template unchanged unless you only need to rename the top-level parent directory.
   - Test one source manually before importing a large library.

4. **If exposing it publicly:**
   - Set `BASIC_AUTH_USERNAME` and `BASIC_AUTH_PASSWORD` in `.env`.
   - Only set `EXPOSE_FEED_ENDPOINTS` if you actually need podcast / RSS clients to fetch feeds or stream media without interactive auth.

> [!TIP]
> Pinchflat is optimized for ongoing synchronization, not one-off video grabs. For best results, organize downloads around channel or playlist sources and let it re-index on its own schedule.

---

## Recommended Jellyfin Layout

The cleanest layout is to keep YouTube content separate from your normal TV libraries.

1. Set `PINCHFLAT_DOWNLOADS_DIR` to a dedicated host path such as `/srv/media/youtube`.
2. In Pinchflat, create a Media Profile using the `Media Center` preset.
3. Leave the preset output template as-is:

    ```text
    /shows/{{ source_custom_name }}/{{ season_by_year__episode_by_date_and_index }} - {{ title }}.{{ ext }}
    ```

4. In Jellyfin, add a separate TV or Home Videos library that points at:

    ```text
    <PINCHFLAT_DOWNLOADS_DIR>/shows
    ```

5. Keep this library separate from your normal series library so YouTube metadata and season structure do not interfere with regular TV scraping.

Notes:

- The upstream Pinchflat docs recommend keeping the Media Center preset intact for Plex, Jellyfin, and Kodi compatibility.
- The preset is designed to emit season/episode-style filenames that Jellyfin can recognize.
- If you change the template, only change the parent path portion unless you have a specific reason and understand the media-center implications.
- Channels work best with this layout. Playlists can work too, but season/episode naming is more naturally aligned with channel archives.

---

## Step 4 — VPS Nginx Configuration

To access Pinchflat securely via `pinchflat.example.com`:

**Upstream** (add to `services.conf`):

```nginx
upstream pinchflat_upstream {
    server 10.8.0.2:8945; # Your VPN IP and port
}
```

**Server Block** (add to `services.conf`):

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name pinchflat.example.com;

    # ... SSL certificates ...

    location / {
        proxy_pass http://pinchflat_upstream;

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
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;

        proxy_buffering off;
    }
}
```

> [!IMPORTANT]
> Avoid putting Pinchflat behind reverse-proxy auth unless you also explicitly exempt its RSS/media feed endpoints. The simpler and safer option is to use Pinchflat's own HTTP Basic Auth settings and let nginx only handle TLS and proxying.

---

## Step 5 — Optional Monitoring

Pinchflat can expose Prometheus metrics on `/metrics` when `ENABLE_PROMETHEUS` is set to a non-empty value.

This repository's monitoring stack already includes a `pinchflat` scrape job pointed at the host-bound service port. After enabling metrics:

1. Restart Pinchflat.
2. Restart or reload Prometheus if needed.
3. Verify the target in Grafana / Prometheus.

The exported metrics are mainly runtime and performance telemetry from Phoenix, Ecto, Oban, and the Erlang VM rather than library-specific media statistics.