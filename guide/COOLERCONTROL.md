# 🐧  CoolerControl — Hardware Fan & Cooling Monitoring

> [!NOTE]
> This document is an **example template**. All domain names, IP addresses, and service details are fictional and used for illustration purposes only. Replace them with your own values.

CoolerControl provides a web UI for monitoring and controlling fans, pumps, and thermal sensors on your Linux system. It requires elevated privileges to access hardware sensors directly.

---

## Table of Contents

- [Architecture](#architecture)
- [Step 1 — Docker Compose](#step-1--docker-compose)
- [Step 2 — Web Access](#step-2--web-access)
- [Step 3 — Configuration](#step-3--configuration)

---

## Architecture

CoolerControl runs directly on the host machine to monitor and control hardware.

- **Web UI:** Port `11987` (default)

---

## Step 1 — Docker Compose

See [services/coolercontrol/docker-compose.yml](../services/coolercontrol/docker-compose.yml).

Ensure you have a `.env` file with the necessary variables (ports, paths).

---

## Step 2 — Web Access

Open `http://localhost:11987` or `http://<HOME_SERVER_IP>:11987` in your browser.

---

## Step 3 — Configuration

1. **Dashboard:** Overview of temperatures and fan speeds.
2. **Sensors:** Map available hardware sensors to names (e.g., `cpu_temp`, `gpu_temp`).
3. **Control:** Create profiles and curves to adjust fan speeds based on temperature.

Example configuration for a fan:
- **Profile:** Balanced
- **Curve:** Custom (Speed vs Temperature)
- **Sensor:** CPU Package Temp

Save and apply the profile.
