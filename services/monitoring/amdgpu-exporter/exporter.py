#!/usr/bin/env python3
# ==========================================================================
# AMD GPU Prometheus Exporter
# ==========================================================================
# Reads AMD Radeon GPU metrics from the amdgpu sysfs interface and exposes
# them in Prometheus text exposition format.  Zero external dependencies —
# stdlib only.
#
# Tested with:  AMD Radeon RX 570 (amdgpu kernel driver)
#
# Sysfs paths read (relative to the card's device directory):
#   gpu_busy_percent          — GPU core utilization (0–100 %)
#   mem_busy_percent          — memory controller utilization (0–100 %)
#   mem_info_vram_total/used  — VRAM in bytes
#   mem_info_vis_vram_*       — CPU-visible VRAM in bytes
#   mem_info_gtt_total/used   — GTT (system) memory in bytes
#   hwmon/hwmon*/temp1_input  — die temperature in milli-°C
#   hwmon/hwmon*/power1_*     — power draw / cap in micro-W
#   hwmon/hwmon*/fan1_input   — fan speed in RPM
#   hwmon/hwmon*/freq1_input  — GPU shader clock in Hz
#   hwmon/hwmon*/freq2_input  — memory clock in Hz
#
# Environment variables:
#   SYSFS_ROOT     Root of the sysfs tree mounted inside the container
#                  (default: /sys — override to /host/sys when using Docker)
#   AMDGPU_CARD    Force a specific card, e.g. "card0"  (default: auto-detect)
#   EXPORTER_PORT  Port this exporter listens on        (default: 9835)
# ==========================================================================

import glob
import os
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler

SYSFS_ROOT    = os.environ.get("SYSFS_ROOT", "/sys")
AMDGPU_CARD   = os.environ.get("AMDGPU_CARD", "").strip()
EXPORTER_PORT = int(os.environ.get("EXPORTER_PORT", "9835"))


# ── sysfs helpers ─────────────────────────────────────────────────────────

def _read(path, default=None):
    """Return stripped text content of *path*, or *default* on any error."""
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def _read_int(path, default=0):
    val = _read(path)
    try:
        return int(val)
    except (TypeError, ValueError):
        return default


# ── card / hwmon discovery ────────────────────────────────────────────────

def find_amdgpu_card():
    """Return the sysfs device path for the first (or configured) amdgpu card."""
    if AMDGPU_CARD:
        return os.path.join(SYSFS_ROOT, "class", "drm", AMDGPU_CARD, "device")

    pattern = os.path.join(SYSFS_ROOT, "class", "drm", "card*", "device")
    for dev_path in sorted(glob.glob(pattern)):
        driver_link = os.path.join(dev_path, "driver")
        try:
            driver = os.path.basename(os.readlink(driver_link))
        except OSError:
            continue
        if driver == "amdgpu":
            return dev_path
    return None


def find_hwmon(dev_path):
    """Return the hwmon directory under *dev_path*, or None if absent."""
    pattern = os.path.join(dev_path, "hwmon", "hwmon*")
    dirs = sorted(glob.glob(pattern))
    return dirs[0] if dirs else None


# ── Prometheus text formatter ─────────────────────────────────────────────

def _metric(lines, name, mtype, helptext, value, labels=None):
    """Append a single metric block (HELP + TYPE + sample) to *lines*."""
    lines.append(f"# HELP {name} {helptext}")
    lines.append(f"# TYPE {name} {mtype}")
    if labels:
        lbl = ",".join(f'{k}="{v}"' for k, v in labels.items())
        lines.append(f"{name}{{{lbl}}} {value}")
    else:
        lines.append(f"{name} {value}")


# ── metric collection ─────────────────────────────────────────────────────

def collect_metrics(dev_path, hwmon_path):
    """Read all available amdgpu sysfs metrics and return Prometheus text."""
    lines = []

    # ── GPU / memory controller utilization ───────────────────────────
    gpu_busy = _read_int(os.path.join(dev_path, "gpu_busy_percent"))
    _metric(lines, "amdgpu_gpu_utilization_percent", "gauge",
            "GPU core utilization percentage (0–100)", gpu_busy)

    mem_busy = _read(os.path.join(dev_path, "mem_busy_percent"))
    if mem_busy is not None:
        _metric(lines, "amdgpu_mem_utilization_percent", "gauge",
                "GPU memory controller utilization percentage (0–100)", int(mem_busy))

    # ── VRAM ──────────────────────────────────────────────────────────
    vram_total = _read_int(os.path.join(dev_path, "mem_info_vram_total"))
    vram_used  = _read_int(os.path.join(dev_path, "mem_info_vram_used"))
    _metric(lines, "amdgpu_vram_total_bytes", "gauge",
            "Total VRAM size in bytes", vram_total)
    _metric(lines, "amdgpu_vram_used_bytes", "gauge",
            "Currently used VRAM in bytes", vram_used)

    vis_total = _read(os.path.join(dev_path, "mem_info_vis_vram_total"))
    vis_used  = _read(os.path.join(dev_path, "mem_info_vis_vram_used"))
    if vis_total is not None:
        _metric(lines, "amdgpu_vis_vram_total_bytes", "gauge",
                "CPU-visible VRAM total in bytes", int(vis_total))
    if vis_used is not None:
        _metric(lines, "amdgpu_vis_vram_used_bytes", "gauge",
                "CPU-visible VRAM used in bytes", int(vis_used))

    gtt_total = _read(os.path.join(dev_path, "mem_info_gtt_total"))
    gtt_used  = _read(os.path.join(dev_path, "mem_info_gtt_used"))
    if gtt_total is not None:
        _metric(lines, "amdgpu_gtt_total_bytes", "gauge",
                "GTT (system-memory aperture) total in bytes", int(gtt_total))
    if gtt_used is not None:
        _metric(lines, "amdgpu_gtt_used_bytes", "gauge",
                "GTT memory currently used in bytes", int(gtt_used))

    # ── hwmon: temperature, power, fan, clocks ────────────────────────
    if hwmon_path:
        # Temperature — sysfs reports millidegrees C
        temp = _read(os.path.join(hwmon_path, "temp1_input"))
        if temp is not None:
            _metric(lines, "amdgpu_temperature_celsius", "gauge",
                    "GPU die temperature in degrees Celsius",
                    round(int(temp) / 1000, 1))

        temp_crit = _read(os.path.join(hwmon_path, "temp1_crit"))
        if temp_crit is not None:
            _metric(lines, "amdgpu_temperature_crit_celsius", "gauge",
                    "GPU critical (emergency shutdown) temperature in degrees Celsius",
                    round(int(temp_crit) / 1000, 1))

        # Power — sysfs reports microwatts
        power_avg = _read(os.path.join(hwmon_path, "power1_average"))
        if power_avg is not None:
            _metric(lines, "amdgpu_power_average_watts", "gauge",
                    "Average GPU power draw in watts",
                    round(int(power_avg) / 1_000_000, 2))

        power_cap = _read(os.path.join(hwmon_path, "power1_cap"))
        if power_cap is not None:
            _metric(lines, "amdgpu_power_cap_watts", "gauge",
                    "GPU power cap (TDP limit) in watts",
                    round(int(power_cap) / 1_000_000, 2))

        # Fan speed — RPM
        fan_rpm = _read(os.path.join(hwmon_path, "fan1_input"))
        if fan_rpm is not None:
            _metric(lines, "amdgpu_fan_speed_rpm", "gauge",
                    "GPU fan speed in RPM", int(fan_rpm))

        # Clocks — sysfs reports Hz
        gpu_clk = _read(os.path.join(hwmon_path, "freq1_input"))
        if gpu_clk is not None:
            _metric(lines, "amdgpu_gpu_clock_hz", "gauge",
                    "Current GPU shader clock frequency in Hz", int(gpu_clk))

        mem_clk = _read(os.path.join(hwmon_path, "freq2_input"))
        if mem_clk is not None:
            _metric(lines, "amdgpu_mem_clock_hz", "gauge",
                    "Current GPU memory clock frequency in Hz", int(mem_clk))

    return "\n".join(lines) + "\n"


# ── HTTP server ───────────────────────────────────────────────────────────

class MetricsHandler(BaseHTTPRequestHandler):
    """Serve /metrics (Prometheus scrape) and /health (liveness probe)."""

    _UP_HEADER = (
        "# HELP amdgpu_up Whether the amdgpu sysfs interface is readable (1=up, 0=down)\n"
        "# TYPE amdgpu_up gauge\n"
    )

    def do_GET(self):
        if self.path == "/metrics":
            self._serve_metrics()
        elif self.path == "/health":
            self._respond(200, "ok\n")
        else:
            self._respond(404, "Not Found\n")

    def _serve_metrics(self):
        try:
            dev_path = find_amdgpu_card()
            if dev_path is None:
                raise RuntimeError("No amdgpu card found in sysfs")
            hwmon_path = find_hwmon(dev_path)
            body = self._UP_HEADER + "amdgpu_up 1\n" + collect_metrics(dev_path, hwmon_path)
            self._respond(200, body, content_type="text/plain; version=0.0.4; charset=utf-8")
        except Exception as exc:
            body = self._UP_HEADER + "amdgpu_up 0\n"
            self._respond(200, body, content_type="text/plain; version=0.0.4; charset=utf-8")
            print(f"[WARN] Failed to collect amdgpu metrics: {exc}", file=sys.stderr)

    def _respond(self, status, body, content_type="text/plain"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, fmt, *args):
        # Suppress per-request access logs; errors still reach stderr.
        pass


# ── entrypoint ────────────────────────────────────────────────────────────

def main():
    dev_path = find_amdgpu_card()
    if dev_path:
        hwmon = find_hwmon(dev_path)
        print(f"amdgpu-exporter: found card at {dev_path}", flush=True)
        if hwmon:
            print(f"amdgpu-exporter: found hwmon at {hwmon}", flush=True)
        else:
            print("[WARN] No hwmon directory found — temperature/power/fan/clocks unavailable",
                  flush=True)
    else:
        print("[WARN] No amdgpu card found in sysfs — metrics will report amdgpu_up 0",
              flush=True)

    print(f"amdgpu-exporter listening on :{EXPORTER_PORT}  (SYSFS_ROOT={SYSFS_ROOT})",
          flush=True)
    server = HTTPServer(("0.0.0.0", EXPORTER_PORT), MetricsHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()
    print("amdgpu-exporter stopped.", flush=True)


if __name__ == "__main__":
    main()
