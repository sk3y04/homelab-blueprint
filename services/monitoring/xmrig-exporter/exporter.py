#!/usr/bin/env python3
# ==========================================================================
# XMRig Prometheus Exporter
# ==========================================================================
# Translates XMRig's HTTP API JSON (/1/summary) into Prometheus text
# exposition format.  Zero external dependencies — stdlib only.
#
# Environment variables:
#   XMRIG_URL        Base URL of the XMRig HTTP API  (default: http://172.17.0.1:18088)
#   EXPORTER_PORT    Port this exporter listens on    (default: 9189)
#   SCRAPE_TIMEOUT   Timeout in seconds for XMRig API (default: 5)
# ==========================================================================

import json
import os
import sys
import time
import urllib.request
import urllib.error
from http.server import HTTPServer, BaseHTTPRequestHandler

XMRIG_URL = os.environ.get("XMRIG_URL", "http://172.17.0.1:18088")
EXPORTER_PORT = int(os.environ.get("EXPORTER_PORT", "9189"))
SCRAPE_TIMEOUT = int(os.environ.get("SCRAPE_TIMEOUT", "5"))


# ── XMRig API Client ─────────────────────────────────────────────────────

def fetch_summary():
    """Fetch /1/summary from the XMRig HTTP API."""
    url = f"{XMRIG_URL}/1/summary"
    req = urllib.request.Request(url)
    token = os.environ.get("XMRIG_ACCESS_TOKEN", "")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=SCRAPE_TIMEOUT) as resp:
        return json.loads(resp.read().decode())


# ── Prometheus Text Formatter ─────────────────────────────────────────────

def _metric(lines, name, mtype, helptext, value, labels=None):
    """Append a single metric (HELP + TYPE + sample) to *lines*."""
    lines.append(f"# HELP {name} {helptext}")
    lines.append(f"# TYPE {name} {mtype}")
    if labels:
        lbl = ",".join(f'{k}="{v}"' for k, v in labels.items())
        lines.append(f"{name}{{{lbl}}} {value}")
    else:
        lines.append(f"{name} {value}")


def _safe(val, default=0):
    """Return *val* if it is a finite number, otherwise *default*."""
    return val if val is not None else default


def build_metrics(data):
    """Convert an XMRig /1/summary JSON dict into Prometheus text format."""
    lines = []

    # ── Hashrate ──────────────────────────────────────────────────────
    hr = data.get("hashrate", {})
    totals = hr.get("total", [0, 0, 0])

    lines.append("# HELP xmrig_hashrate_hashes_per_second Current hashrate in H/s by averaging window")
    lines.append("# TYPE xmrig_hashrate_hashes_per_second gauge")
    for i, window in enumerate(["10s", "60s", "15m"]):
        val = _safe(totals[i] if i < len(totals) else 0)
        lines.append(f'xmrig_hashrate_hashes_per_second{{window="{window}"}} {val}')

    _metric(lines, "xmrig_hashrate_highest_hashes_per_second", "gauge",
            "Highest recorded hashrate in H/s", _safe(hr.get("highest")))

    # Per-thread hashrates (optional, can be noisy with 36 threads)
    threads = hr.get("threads", [])
    if threads:
        lines.append("# HELP xmrig_thread_hashrate_hashes_per_second Per-thread hashrate (10s) in H/s")
        lines.append("# TYPE xmrig_thread_hashrate_hashes_per_second gauge")
        for idx, th in enumerate(threads):
            val = _safe(th[0] if isinstance(th, list) and th else 0)
            lines.append(f'xmrig_thread_hashrate_hashes_per_second{{thread="{idx}"}} {val}')

    # ── Shares / Results ──────────────────────────────────────────────
    res = data.get("results", {})

    _metric(lines, "xmrig_shares_good_total", "counter",
            "Total good (accepted) shares submitted", _safe(res.get("shares_good")))
    _metric(lines, "xmrig_shares_total", "counter",
            "Total shares submitted (good + bad)", _safe(res.get("shares_total")))
    _metric(lines, "xmrig_shares_avg_time_seconds", "gauge",
            "Average time between shares in seconds", _safe(res.get("avg_time")))
    _metric(lines, "xmrig_hashes_total", "counter",
            "Total hashes computed since start", _safe(res.get("hashes_total")))
    _metric(lines, "xmrig_difficulty_current", "gauge",
            "Current mining difficulty", _safe(res.get("diff_current")))

    # ── Connection ────────────────────────────────────────────────────
    conn = data.get("connection", {})

    _metric(lines, "xmrig_connection_uptime_seconds", "gauge",
            "Current pool connection uptime in seconds", _safe(conn.get("uptime")))
    _metric(lines, "xmrig_connection_ping_ms", "gauge",
            "Pool round-trip ping in milliseconds", _safe(conn.get("ping")))
    _metric(lines, "xmrig_connection_failures_total", "counter",
            "Total pool connection failures", _safe(conn.get("failures")))
    _metric(lines, "xmrig_connection_accepted_total", "counter",
            "Shares accepted by the pool", _safe(conn.get("accepted")))
    _metric(lines, "xmrig_connection_rejected_total", "counter",
            "Shares rejected by the pool", _safe(conn.get("rejected")))

    # ── Miner State ───────────────────────────────────────────────────
    _metric(lines, "xmrig_uptime_seconds", "gauge",
            "Miner process uptime in seconds", _safe(data.get("uptime")))
    _metric(lines, "xmrig_paused", "gauge",
            "Whether the miner is paused (1=paused, 0=running)",
            int(data.get("paused", False)))
    _metric(lines, "xmrig_donate_level", "gauge",
            "Donation level percentage", _safe(data.get("donate_level")))

    # ── Hugepages ─────────────────────────────────────────────────────
    hp = data.get("hugepages", [0, 0])
    if isinstance(hp, list) and len(hp) >= 2:
        _metric(lines, "xmrig_hugepages_allocated", "gauge",
                "Number of hugepages successfully allocated", hp[0])
        _metric(lines, "xmrig_hugepages_requested", "gauge",
                "Number of hugepages requested", hp[1])

    # ── Resources ─────────────────────────────────────────────────────
    resources = data.get("resources", {})
    mem = resources.get("memory", {})
    if mem:
        _metric(lines, "xmrig_memory_resident_bytes", "gauge",
                "Resident set size (RSS) in bytes", _safe(mem.get("resident_set_memory")))
        _metric(lines, "xmrig_memory_free_bytes", "gauge",
                "Free system memory in bytes", _safe(mem.get("free")))
        _metric(lines, "xmrig_memory_total_bytes", "gauge",
                "Total system memory in bytes", _safe(mem.get("total")))
    load = resources.get("load_average", [])
    if load and len(load) >= 3:
        lines.append("# HELP xmrig_load_average System load average reported by XMRig")
        lines.append("# TYPE xmrig_load_average gauge")
        for i, window in enumerate(["1m", "5m", "15m"]):
            lines.append(f'xmrig_load_average{{window="{window}"}} {_safe(load[i])}')

    # ── Info (labels-only metric) ─────────────────────────────────────
    _metric(lines, "xmrig_info", "gauge",
            "XMRig build and runtime metadata (constant 1, labels carry data)", 1,
            labels={
                "version": data.get("version", ""),
                "algo": data.get("algo", ""),
                "worker_id": data.get("worker_id", ""),
                "pool": conn.get("pool", ""),
                "tls": str(conn.get("tls") or "none"),
            })

    return "\n".join(lines) + "\n"


# ── HTTP Server ───────────────────────────────────────────────────────────

class MetricsHandler(BaseHTTPRequestHandler):
    """Serve /metrics (Prometheus scrape) and /health (liveness)."""

    def do_GET(self):
        if self.path == "/metrics":
            self._serve_metrics()
        elif self.path == "/health":
            self._respond(200, "ok\n")
        else:
            self._respond(404, "Not Found\n")

    def _serve_metrics(self):
        try:
            data = fetch_summary()
            body = build_metrics(data)
            # Prepend an up=1 metric
            body = "# HELP xmrig_up Whether the XMRig API is reachable (1=up, 0=down)\n" \
                   "# TYPE xmrig_up gauge\nxmrig_up 1\n" + body
            self._respond(200, body, content_type="text/plain; version=0.0.4; charset=utf-8")
        except Exception as exc:
            # XMRig unreachable — return up=0 so Prometheus still gets a scrape
            body = "# HELP xmrig_up Whether the XMRig API is reachable (1=up, 0=down)\n" \
                   "# TYPE xmrig_up gauge\nxmrig_up 0\n"
            self._respond(200, body, content_type="text/plain; version=0.0.4; charset=utf-8")
            print(f"[WARN] Failed to scrape XMRig API at {XMRIG_URL}: {exc}", file=sys.stderr)

    def _respond(self, status, body, content_type="text/plain"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, fmt, *args):
        # Suppress per-request access logs to keep journal clean; errors still go to stderr.
        pass


# ── Entrypoint ────────────────────────────────────────────────────────────

def main():
    print(f"xmrig-exporter listening on :{EXPORTER_PORT}  →  {XMRIG_URL}", flush=True)
    server = HTTPServer(("0.0.0.0", EXPORTER_PORT), MetricsHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()
    print("xmrig-exporter stopped.", flush=True)


if __name__ == "__main__":
    main()
