#!/usr/bin/env python3
# ==========================================================================
# NVIDIA GPU Prometheus Exporter
# ==========================================================================
# Reads NVIDIA GPU metrics from nvidia-smi and exposes them in Prometheus
# text exposition format. Zero external Python dependencies — stdlib only.
#
# Tested target: NVIDIA RTX 3090 (Ampere / GA102).
#
# Environment variables:
#   EXPORTER_PORT   Port this exporter listens on          (default: 9835)
#   NVIDIA_SMI_BIN  Path to the nvidia-smi binary         (default: nvidia-smi)
# ==========================================================================

import csv
import io
import os
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

EXPORTER_PORT = int(os.environ.get("EXPORTER_PORT", "9835"))
NVIDIA_SMI_BIN = os.environ.get("NVIDIA_SMI_BIN", "nvidia-smi")

# ---------------------------------------------------------------------------
# Fields passed to --query-gpu. Order MUST match QUERY_FIELDS exactly — the
# CSV output is positional. Add new fields at the END to keep existing
# label/metric mappings stable.
# ---------------------------------------------------------------------------
QUERY_FIELDS = [
    # Identification
    "index",
    "uuid",
    "name",
    "pci.bus_id",
    # Core utilisation
    "utilization.gpu",
    "utilization.memory",
    # VRAM
    "memory.total",
    "memory.used",
    # Thermal / power
    "temperature.gpu",
    "power.draw",
    "power.limit",
    # Cooling
    "fan.speed",
    # Clocks
    "clocks.current.graphics",
    "clocks.current.memory",
    # Performance state (P0 = maximum performance, P8 = minimum)
    "pstate",
    # Throttle reasons (RTX 3090 Ampere; returned as "Active" / "Not Active")
    "clocks_throttle_reasons.hw_slowdown",
    "clocks_throttle_reasons.hw_thermal_slowdown",
    "clocks_throttle_reasons.hw_power_brake_slowdown",
    "clocks_throttle_reasons.sw_thermal_slowdown",
    "clocks_throttle_reasons.sw_power_cap",
    # Active NVENC encoder sessions (useful alongside Jellyfin hardware transcoding).
    # Note: decoder.stats.sessionCount was removed in driver 5xx — not a valid field.
    "encoder.stats.sessionCount",
    # ECC — Ampere consumer cards support ECC but it is disabled by default;
    # the exporter emits 0 and skips N/A gracefully.
    "ecc.errors.corrected.volatile.total",
    "ecc.errors.uncorrected.volatile.total",
]

# ---------------------------------------------------------------------------
# Numeric metric specs: (prom_name, type, help, field_name, scale_factor)
# ---------------------------------------------------------------------------
METRIC_SPECS = [
    ("nvidia_gpu_utilization_percent",  "gauge", "Current GPU core utilization percentage (0-100)",        "utilization.gpu",       1.0),
    ("nvidia_mem_utilization_percent",  "gauge", "Current GPU memory bus utilization percentage (0-100)",  "utilization.memory",    1.0),
    ("nvidia_vram_total_bytes",         "gauge", "Total VRAM capacity in bytes",                           "memory.total",          1024.0 * 1024.0),
    ("nvidia_vram_used_bytes",          "gauge", "Currently used VRAM in bytes",                           "memory.used",           1024.0 * 1024.0),
    ("nvidia_temperature_celsius",      "gauge", "GPU die temperature in degrees Celsius",                 "temperature.gpu",       1.0),
    ("nvidia_power_draw_watts",         "gauge", "Current GPU power draw in watts",                        "power.draw",            1.0),
    ("nvidia_power_limit_watts",        "gauge", "Configured GPU TDP power limit in watts",                "power.limit",           1.0),
    ("nvidia_fan_speed_percent",        "gauge", "GPU fan speed percentage (0-100)",                       "fan.speed",             1.0),
    ("nvidia_gpu_clock_hz",             "gauge", "Current GPU graphics clock in Hz",                       "clocks.current.graphics", 1_000_000.0),
    ("nvidia_mem_clock_hz",             "gauge", "Current GPU memory clock in Hz",                         "clocks.current.memory",   1_000_000.0),
    ("nvidia_encoder_sessions",         "gauge", "Number of active NVENC hardware-encoder sessions",       "encoder.stats.sessionCount", 1.0),
    ("nvidia_ecc_corrected_volatile",   "gauge", "ECC single-bit errors corrected since last driver load", "ecc.errors.corrected.volatile.total",   1.0),
    ("nvidia_ecc_uncorrected_volatile", "gauge", "ECC double-bit errors (uncorrected) since last driver load", "ecc.errors.uncorrected.volatile.total", 1.0),
]

# ---------------------------------------------------------------------------
# Throttle-reason fields: "Active" → 1, anything else → 0.
# ---------------------------------------------------------------------------
THROTTLE_SPECS = [
    ("nvidia_throttle_hw_slowdown",         "Hardware slowdown active (thermal or power limiter)",          "clocks_throttle_reasons.hw_slowdown"),
    ("nvidia_throttle_hw_thermal_slowdown", "Hardware thermal slowdown active (GPU over temperature limit)", "clocks_throttle_reasons.hw_thermal_slowdown"),
    ("nvidia_throttle_hw_power_brake",      "Hardware power-brake slowdown active (power-supply signal)",   "clocks_throttle_reasons.hw_power_brake_slowdown"),
    ("nvidia_throttle_sw_thermal_slowdown", "Software thermal slowdown active",                             "clocks_throttle_reasons.sw_thermal_slowdown"),
    ("nvidia_throttle_sw_power_cap",        "Software power-cap slowdown active (TDP limit reached)",       "clocks_throttle_reasons.sw_power_cap"),
]


def _escape_label(value):
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def _parse_number(value):
    """Return float for numeric nvidia-smi values; None for N/A / Not Supported."""
    raw = value.strip()
    if not raw or raw in {"N/A", "[N/A]", "Not Supported", "[Not Supported]"}:
        return None
    return float(raw)


def _parse_active_flag(value):
    """Convert 'Active' → 1, 'Not Active' / N/A → 0."""
    raw = value.strip()
    if raw == "Active":
        return 1
    return 0


def _parse_pstate(value):
    """Convert 'P0' … 'P12' → integer, or None on N/A."""
    raw = value.strip()
    m = re.match(r"^P(\d+)$", raw)
    if not m:
        return None
    return int(m.group(1))


def _format_value(value):
    if float(value).is_integer():
        return str(int(value))
    return f"{value:.4f}".rstrip("0").rstrip(".")


def collect_gpu_rows():
    command = [
        NVIDIA_SMI_BIN,
        f"--query-gpu={','.join(QUERY_FIELDS)}",
        "--format=csv,noheader,nounits",
    ]
    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    if result.returncode != 0:
        detail = (result.stderr.strip() or result.stdout.strip() or "(no output)")
        raise RuntimeError(f"nvidia-smi exited {result.returncode}: {detail}")

    reader = csv.reader(io.StringIO(result.stdout))
    rows = []
    for csv_row in reader:
        if not csv_row:
            continue
        values = [item.strip() for item in csv_row]
        if len(values) != len(QUERY_FIELDS):
            raise RuntimeError(f"Unexpected nvidia-smi column count: {len(values)}")
        row = dict(zip(QUERY_FIELDS, values))
        rows.append(row)
    return rows


def render_metrics(rows):
    lines = [
        "# HELP nvidia_up Whether nvidia-smi returned GPU metrics successfully (1=up, 0=down)",
        "# TYPE nvidia_up gauge",
        "nvidia_up 1",
        "# HELP nvidia_gpu_info Static information about visible NVIDIA GPUs",
        "# TYPE nvidia_gpu_info gauge",
    ]

    for row in rows:
        labels = {
            "index":      row["index"],
            "uuid":       row["uuid"],
            "name":       row["name"],
            "pci_bus_id": row["pci.bus_id"],
        }
        label_text = ",".join(f'{key}="{_escape_label(value)}"' for key, value in labels.items())
        lines.append(f"nvidia_gpu_info{{{label_text}}} 1")

    # ── Performance state (P0 = full performance, higher = lower power) ──
    lines.append("# HELP nvidia_pstate GPU performance state (0=P0 max, 8=P8 idle)")
    lines.append("# TYPE nvidia_pstate gauge")
    for row in rows:
        pstate = _parse_pstate(row["pstate"])
        if pstate is None:
            continue
        labels = {
            "index":      row["index"],
            "uuid":       row["uuid"],
            "name":       row["name"],
            "pci_bus_id": row["pci.bus_id"],
        }
        label_text = ",".join(f'{key}="{_escape_label(v)}"' for key, v in labels.items())
        lines.append(f"nvidia_pstate{{{label_text}}} {pstate}")

    # ── Throttle reasons ─────────────────────────────────────────────────
    for metric_name, help_text, field_name in THROTTLE_SPECS:
        lines.append(f"# HELP {metric_name} {help_text}")
        lines.append(f"# TYPE {metric_name} gauge")
        for row in rows:
            val = _parse_active_flag(row[field_name])
            labels = {
                "index":      row["index"],
                "uuid":       row["uuid"],
                "name":       row["name"],
                "pci_bus_id": row["pci.bus_id"],
            }
            label_text = ",".join(f'{key}="{_escape_label(v)}"' for key, v in labels.items())
            lines.append(f"{metric_name}{{{label_text}}} {val}")

    # ── Numeric metrics ──────────────────────────────────────────────────
    for metric_name, metric_type, help_text, field_name, scale in METRIC_SPECS:
        lines.append(f"# HELP {metric_name} {help_text}")
        lines.append(f"# TYPE {metric_name} {metric_type}")
        for row in rows:
            value = _parse_number(row[field_name])
            if value is None:
                continue
            labels = {
                "index":      row["index"],
                "uuid":       row["uuid"],
                "name":       row["name"],
                "pci_bus_id": row["pci.bus_id"],
            }
            label_text = ",".join(f'{key}="{_escape_label(label)}"' for key, label in labels.items())
            lines.append(f"{metric_name}{{{label_text}}} {_format_value(value * scale)}")

    return "\n".join(lines) + "\n"


class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            self._serve_metrics()
        elif self.path == "/health":
            self._respond(200, "ok\n")
        else:
            self._respond(404, "Not Found\n")

    def _serve_metrics(self):
        try:
            body = render_metrics(collect_gpu_rows())
            self._respond(200, body, content_type="text/plain; version=0.0.4; charset=utf-8")
        except Exception as exc:
            body = (
                "# HELP nvidia_up Whether nvidia-smi returned GPU metrics successfully (1=up, 0=down)\n"
                "# TYPE nvidia_up gauge\n"
                "nvidia_up 0\n"
            )
            self._respond(200, body, content_type="text/plain; version=0.0.4; charset=utf-8")
            print(f"[WARN] Failed to collect NVIDIA GPU metrics: {exc}", file=sys.stderr)

    def _respond(self, status, body, content_type="text/plain"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, fmt, *args):
        pass


def main():
    try:
        rows = collect_gpu_rows()
        if rows:
            visible = ", ".join(f"GPU {row['index']}: {row['name']}" for row in rows)
            print(f"nvidia-smi-exporter: discovered {visible}", flush=True)
        else:
            print("[WARN] nvidia-smi returned no visible GPUs", flush=True)
    except Exception as exc:
        print(f"[WARN] Initial NVIDIA GPU probe failed: {exc}", flush=True)

    print(f"nvidia-smi-exporter listening on :{EXPORTER_PORT}", flush=True)
    server = HTTPServer(("0.0.0.0", EXPORTER_PORT), MetricsHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()
    print("nvidia-smi-exporter stopped.", flush=True)


if __name__ == "__main__":
    main()