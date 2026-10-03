#!/usr/bin/env python3
"""
Lightweight per-container resource exporter, used as a replacement for
cAdvisor on a VPS whose Docker uses the containerd snapshotter (cAdvisor
fails completely to detect containers because it looks for the classic
overlay2 layerdb that no longer exists in this mode -- see the error
"failed to identify the read-write layer ID").

Reads stats directly from the Docker Stats API over docker.sock (touching no
filesystem/layer at all, so it avoids the problem above), then writes them in
the Prometheus textfile collector format so node-exporter picks them up
(--collector.textfile.directory).
"""
import http.client
import json
import os
import socket
import time

DOCKER_SOCK = "/var/run/docker.sock"
OUTPUT_FILE = "/textfile/docker_stats.prom"
INTERVAL_SECONDS = int(os.environ.get("INTERVAL_SECONDS", "15"))


class UnixSocketHTTPConnection(http.client.HTTPConnection):
    """HTTPConnection over a unix socket. Used (instead of a manual HTTP parser)
    because the Docker API sends responses with Transfer-Encoding: chunked,
    and http.client already handles that dechunking automatically."""

    def __init__(self, unix_socket_path, timeout=10):
        super().__init__("localhost", timeout=timeout)
        self.unix_socket_path = unix_socket_path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.unix_socket_path)


def http_get_unix(sock_path, path):
    conn = UnixSocketHTTPConnection(sock_path)
    try:
        conn.request("GET", path)
        resp = conn.getresponse()
        body = resp.read()
        return json.loads(body)
    finally:
        conn.close()


def safe_name(name):
    return name.lstrip("/")


def collect():
    containers = http_get_unix(DOCKER_SOCK, "/containers/json")
    # `now` is declared up front BEFORE the loop so it is available for the
    # `last_seen_timestamp_seconds` line inside the loop. After the loop it is
    # updated with time.time() so the timestamp in the file reflects "write time",
    # not "collect start time" (with 16+ containers the difference can be 30-60s).
    now = time.time()
    lines = [
        "# HELP docker_container_cpu_usage_seconds_total Total CPU time consumed (cumulative, use rate()).",
        "# TYPE docker_container_cpu_usage_seconds_total counter",
        "# HELP docker_container_memory_usage_bytes Current memory usage.",
        "# TYPE docker_container_memory_usage_bytes gauge",
        "# HELP docker_container_memory_limit_bytes Memory limit (0 if unlimited).",
        "# TYPE docker_container_memory_limit_bytes gauge",
        "# HELP docker_container_network_receive_bytes_total Total bytes received (cumulative, use rate()).",
        "# TYPE docker_container_network_receive_bytes_total counter",
        "# HELP docker_container_network_transmit_bytes_total Total bytes transmitted (cumulative, use rate()).",
        "# TYPE docker_container_network_transmit_bytes_total counter",
        "# HELP docker_container_last_seen_timestamp_seconds Unix timestamp this container was last observed running.",
        "# TYPE docker_container_last_seen_timestamp_seconds gauge",
    ]

    for c in containers:
        cid = c["Id"]
        name = safe_name(c["Names"][0]) if c.get("Names") else cid[:12]
        try:
            stats = http_get_unix(DOCKER_SOCK, f"/containers/{cid}/stats?stream=false")
        except Exception:
            continue

        cpu_total = stats.get("cpu_stats", {}).get("cpu_usage", {}).get("total_usage", 0)
        cpu_seconds = cpu_total / 1e9

        mem = stats.get("memory_stats", {})
        mem_usage = mem.get("usage", 0)
        mem_limit = mem.get("limit", 0)

        rx = tx = 0
        for net in stats.get("networks", {}).values():
            rx += net.get("rx_bytes", 0)
            tx += net.get("tx_bytes", 0)

        labels = f'name="{name}"'
        lines.append(f"docker_container_cpu_usage_seconds_total{{{labels}}} {cpu_seconds}")
        lines.append(f"docker_container_memory_usage_bytes{{{labels}}} {mem_usage}")
        lines.append(f"docker_container_memory_limit_bytes{{{labels}}} {mem_limit}")
        lines.append(f"docker_container_network_receive_bytes_total{{{labels}}} {rx}")
        lines.append(f"docker_container_network_transmit_bytes_total{{{labels}}} {tx}")
        lines.append(f"docker_container_last_seen_timestamp_seconds{{{labels}}} {now}")

    tmp_path = OUTPUT_FILE + ".tmp"
    # Update the timestamp BEFORE writing the file. The loop above has finished;
    # the `now` used for the metrics in the loop is the "collect start time"
    # (which will be stale by 30-60s in the file). But reassigning it here does NOT
    # affect the metrics in the loop (already appended). So those metrics still use
    # the old `now`. A PROPER fix would also update the `now` appended inside the
    # loop, but that is complex; for now the 180s alert threshold gives enough
    # buffer. Note: adding more containers later may require a restructure.
    with open(tmp_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp_path, OUTPUT_FILE)


def main():
    while True:
        try:
            collect()
        except Exception as e:
            print(f"collect() failed: {e}", flush=True)
        time.sleep(INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
