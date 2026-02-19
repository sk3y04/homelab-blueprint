# 🎮 Minecraft Server — Vanilla Survival

> [!NOTE]
> This document is an **example template**. All domain names, IP addresses, and service details are fictional and used for illustration purposes only. Replace them with your own values.

This Docker Compose configuration deploys a vanilla Minecraft server running the latest version.

---

## Table of Contents

- [Architecture](#architecture)
- [Step 1 — DNS Record (Optional)](#step-1--dns-record-optional)
- [Step 2 — Docker Compose](#step-2--docker-compose)
- [Step 3 — Configuration](#step-3--configuration)
- [Step 4 — Connecting](#step-4--connecting)

---

## Architecture

Run a dedicated Minecraft server (vanilla survival).

- **Type:** Vanilla (Survival)
- **Port:** 25565 (Default)

---

## Step 1 — DNS Record (Optional)

Add a DNS SRV record for the Minecraft server if you want to use a custom domain instead of IP:

**SRV Record:**
- **Service:** `_minecraft._tcp`
- **Target:** `mc.example.com`
- **Port:** 25565

---

## Step 2 — Docker Compose

See [services/minecraft-server/docker-compose.yml](../services/minecraft-server/docker-compose.yml).

Ensure you have a `.env` file with the necessary variables (`EULA`, `VERSION`).

---

## Step 3 — Configuration

The container maps `/data` to a host volume for persistence.

1. **Accept EULA:** Set `EULA=YES` in `.env` to start the server.
2. **Server Properties:** Edit `/config/projects/compose/services/minecraft-server/data/server.properties` to configure game rules, motd, etc.
3. **Whitelist:** Use `/whitelist add <playername>` in the console or edit `whitelist.json`.
4. **Ops:** Use `/op <playername>` in the console to grant admin privileges.

---

## Step 4 — Connecting

1. Open Minecraft Client.
2. Click **Multiplayer**.
3. **Add Server**.
4. **Server Address:** Your server IP (e.g., `192.168.1.100` or `mc.example.com`).
5. Click **Done** and join.
