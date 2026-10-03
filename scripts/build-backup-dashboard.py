#!/usr/bin/env python3
"""
Build the Grafana "Site Backup" dashboard for monitoring Proxmox Backup Server.

This dashboard watches the health of the safety net (backup), separate from
the "Site Server Overview" dashboard which watches application availability.

Why it is separate:
  - Backup can die while the application keeps running normally. If merged,
    the "application is healthy" state hides the fact that backup has been dead
    for days.
  - During an incident, the operator needs one screen that answers one
    question: "do I have a backup I can actually restore from?"

Metric source: pbs-backup-monitor.sh (a 5-minute systemd timer on pve2),
scraped by Prometheus via the site-node-exporter job, target 192.0.2.3:9100.

Output: grafana/dashboards/target-2-monitoring/target-2-backup.json

Run from the repo root:
    python3 scripts/build-backup-dashboard.py
"""

import json
import os
import sys

# Datasources in this repo are defined by NAME only (no explicit uid), so
# Grafana generates a random UID. A dashboard must reference a datasource by
# NAME as a string ("Prometheus"), NOT via a {type, uid} object — a made-up uid
# object fails with "Datasource prometheus was not found". This is consistent
# with site-server-overview.json and vps-overview.json.
DS = "Prometheus"

OUT_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "grafana", "dashboards", "target-2-monitoring", "target-2-backup.json",
)

# Status colours, consistent with the site dashboards.
GREEN = "#73BF69"
RED = "#F2495C"
YELLOW = "#FF9830"
BLUE = "#5794F2"
PURPLE = "#B877D9"


def target(expr, legend, ref="A", instant=False):
    """Build a Prometheus target."""
    t = {
        "datasource": DS,
        "expr": expr,
        "legendFormat": legend,
        "refId": ref,
    }
    if instant:
        t["instant"] = True
    return t


def stat_panel(pid, title, expr, unit, x, y, w, h, thresholds, decimals=None,
               description="", color_mode="value"):
    """Panel of type 'stat' — for a single number that must be read at a glance."""
    field = {
        "unit": unit,
        "thresholds": {"mode": "absolute", "steps": thresholds},
        "color": {"mode": "thresholds"},
    }
    if decimals is not None:
        field["decimals"] = decimals
    return {
        "id": pid,
        "type": "stat",
        "title": title,
        "description": description,
        "datasource": DS,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "targets": [target(expr, "", instant=True)],
        "options": {
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "colorMode": color_mode,
            "graphMode": "none",
            "textMode": "auto",
            "orientation": "auto",
        },
        "fieldConfig": {"defaults": field, "overrides": []},
    }


def timeseries_panel(pid, title, targets, unit, x, y, w, h, description="",
                     thresholds=None, fill=10, stack=False):
    """Panel of type 'timeseries' — for viewing trends."""
    field = {"unit": unit, "custom": {"fillOpacity": fill, "lineWidth": 2}}
    if thresholds:
        field["thresholds"] = {"mode": "absolute", "steps": thresholds}
    return {
        "id": pid,
        "type": "timeseries",
        "title": title,
        "description": description,
        "datasource": DS,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "targets": targets,
        "fieldConfig": {"defaults": field, "overrides": []},
        "options": {
            "legend": {"displayMode": "table", "placement": "bottom",
                       "calcs": ["lastNotNull", "max"]},
            "tooltip": {"mode": "multi", "sort": "desc"},
        },
    }


def row_panel(pid, title, y):
    return {
        "id": pid,
        "type": "row",
        "title": title,
        "collapsed": False,
        "gridPos": {"x": 0, "y": y, "w": 24, "h": 1},
    }


def gauge_panel(pid, title, expr, x, y, w, h, description="", decimals=1,
                unit="percent", min_val=0, max_val=100):
    """Panel of type 'gauge' — for percentages (CPU/RAM/disk).

    Why gauge, not timeseries, for host resources:
      - A percentage has clear bounds (0-100), and a gauge shows the position
        relative to those bounds visually.
      - The colour follows the thresholds, so the operator knows the state at
        a glance — without reading a number.
      - For 2 hosts x 3 metrics, gauges lay out neatly and save space.
    Trends remain available on the "Site Server Overview" dashboard if needed.
    """
    return {
        "id": pid,
        "type": "gauge",
        "title": title,
        "description": description,
        "datasource": DS,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "targets": [target(expr, "", instant=True)],
        "options": {
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "showThresholdLabels": False,
            "showThresholdMarkers": True,
        },
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "min": min_val,
                "max": max_val,
                "decimals": decimals,
                "color": {"mode": "thresholds"},
                "thresholds": {
                    "mode": "absolute",
                    "steps": [
                        {"color": GREEN, "value": None},
                        {"color": YELLOW, "value": 70},
                        {"color": RED, "value": 85},
                    ],
                },
            },
            "overrides": [],
        },
    }


panels = []

# ============================================================
# ROW 1: Status summary — 4 numbers visible immediately
# ============================================================
panels.append(row_panel(100, "Backup Status Summary", 0))

# Age of the last backup. This is the most important metric: if it is large,
# every other backup metric means nothing.
panels.append(stat_panel(
    101,
    "Last Backup Age",
    'time() - pbs_backup_last_success_timestamp{job="site-node-exporter"}',
    "s",
    0, 1, 6, 5,
    [
        {"color": RED, "value": None},
        {"color": GREEN, "value": 0},
        {"color": YELLOW, "value": 86400},   # 24h: approaching the threshold
        {"color": RED, "value": 93600},      # 26h: past the schedule
    ],
    description="Seconds since the last successful backup. "
                "Green < 24h, yellow > 24h, red > 26h (the daily "
                "23:00 schedule should already have run).",
))

panels.append(stat_panel(
    102,
    "Monitoring Status",
    'pbs_monitor_up{job="site-node-exporter"}',
    "none",
    6, 1, 4, 5,
    [
        {"color": RED, "value": None},
        {"color": RED, "value": 0},
        {"color": GREEN, "value": 1},
    ],
    decimals=0,
    description="1 = the monitoring script successfully queried the PBS API. "
                "0 = query failed (invalid token / PBS down / network cut) — "
                "every other metric is untrustworthy.",
))

panels.append(stat_panel(
    103,
    "Snapshot Count",
    'pbs_backup_snapshot_count{job="site-node-exporter"}',
    "none",
    10, 1, 4, 5,
    [
        {"color": RED, "value": None},
        {"color": RED, "value": 0},
        {"color": GREEN, "value": 2},
    ],
    decimals=0,
    description="Total snapshots stored in the datastore. With VM 100 + 101 "
                "and 7 daily retention, a healthy value is around 14-30. "
                "0 = no backup has ever been taken.",
))

panels.append(stat_panel(
    104,
    "Datastore Used Capacity",
    '(pbs_datastore_used_bytes{job="site-node-exporter"} / '
    'pbs_datastore_size_bytes{job="site-node-exporter"}) * 100',
    "percent",
    14, 1, 5, 5,
    [
        {"color": GREEN, "value": None},
        {"color": YELLOW, "value": 70},
        {"color": RED, "value": 85},
    ],
    decimals=1,
    description="Percentage of the PBS datastore used. Alert warning > 85%, "
                "critical > 95%. Backup will fail once it is full.",
))

panels.append(stat_panel(
    105,
    "Free Capacity",
    'pbs_datastore_avail_bytes{job="site-node-exporter"}',
    "bytes",
    19, 1, 5, 5,
    [
        {"color": RED, "value": None},
        {"color": RED, "value": 0},
        {"color": YELLOW, "value": 50 * 1024 ** 3},
        {"color": GREEN, "value": 100 * 1024 ** 3},
    ],
    description="Free space in the PBS datastore. Yellow < 50 GB, "
                "green > 100 GB.",
))

# ============================================================
# ROW 2: Status per VM
# ============================================================
panels.append(row_panel(200, "Backup per VM", 6))

panels.append(stat_panel(
    201,
    "VM 100 (Target-1) — Backup Age",
    'time() - pbs_backup_vm_last_timestamp{job="site-node-exporter", vmid="100"}',
    "s",
    0, 7, 6, 5,
    [
        {"color": RED, "value": None},
        {"color": GREEN, "value": 0},
        {"color": YELLOW, "value": 86400},
        {"color": RED, "value": 93600},
    ],
    description="Age of the last backup of VM 100 (Target-1). "
                "If this is red, the application is running without backup protection.",
))

panels.append(stat_panel(
    202,
    "VM 101 (Target-2) — Backup Age",
    'time() - pbs_backup_vm_last_timestamp{job="site-node-exporter", vmid="101"}',
    "s",
    6, 7, 6, 5,
    [
        {"color": RED, "value": None},
        {"color": GREEN, "value": 0},
        {"color": YELLOW, "value": 86400},
        {"color": RED, "value": 93600},
    ],
    description="Age of the last backup of VM 101 (Target-2). "
                "If this is red, the application is running without backup protection.",
))

panels.append(timeseries_panel(
    203,
    "Snapshot Count per VM",
    [target(
        'pbs_backup_vm_snapshot_count{job="site-node-exporter"}',
        "{{vmid}} ({{type}})",
    )],
    "none",
    12, 7, 12, 5,
    description="Snapshots stored per VM. A rising curve = retention is working. "
                "A flat line that then drops = a snapshot was pruned (normal). "
                "A disappearing line = the VM fell off the backup list.",
    fill=20,
))

# ============================================================
# ROW 3: Trends and capacity
# ============================================================
panels.append(row_panel(300, "Trend & Capacity", 12))

panels.append(timeseries_panel(
    301,
    "PBS Datastore Usage",
    [
        target('pbs_datastore_used_bytes{job="site-node-exporter"}',
               "Used", "A"),
        target('pbs_datastore_avail_bytes{job="site-node-exporter"}',
               "Available", "B"),
    ],
    "bytes",
    0, 13, 12, 7,
    description="Datastore growth over time. If the 'used' line keeps rising "
                "without dropping, retention (prune) is not "
                "running and the disk will fill.",
    fill=10,
))

panels.append(timeseries_panel(
    302,
    "Last Backup Duration",
    [target('pbs_backup_last_duration_seconds{job="site-node-exporter"}',
            "{{datastore}}")],
    "s",
    12, 13, 6, 7,
    description="How long the last backup ran. A sudden increase "
                "can mean a VM grew larger or PBS slowed down (I/O).",
    fill=10,
))

panels.append(timeseries_panel(
    303,
    "Last Backup Size",
    [target('pbs_backup_last_size_bytes{job="site-node-exporter"}',
            "{{datastore}}")],
    "bytes",
    18, 13, 6, 7,
    description="Total size of the last backup file. If it drops sharply, "
                "suspect an incomplete backup (VM skipped / disk failure).",
    fill=10,
))

# ============================================================
# ROW 4: PBS and pve2 host status (resources)
# ============================================================
# Gauges are used (not timeseries) because the operator's question here is
# "how full is it right now", not "what is the trend". A gauge answers that
# with colour + needle position. Trends remain visible on the
# "Site Server Overview" dashboard.
panels.append(row_panel(400, "PBS & pve2 Host Resources", 20))

# --- CPU: one gauge per host (pve2 left, pbs right) ---
panels.append(gauge_panel(
    401,
    "pve2 CPU",
    '100 - (avg by (instance) (rate(node_cpu_seconds_total{job="site-node-exporter", '
    'instance="192.0.2.3:9100", mode="idle"}[5m])) * 100)',
    0, 21, 6, 6,
    description="pve2 CPU usage (5-minute average). pve2 runs the PBS VM "
                "(2 vCPU) — a rise during backup is normal. "
                "Green <70%, yellow 70-85%, red >85%.",
))

panels.append(gauge_panel(
    402,
    "PBS CPU",
    '100 - (avg by (instance) (rate(node_cpu_seconds_total{job="site-node-exporter", '
    'instance="192.0.2.4:9100", mode="idle"}[5m])) * 100)',
    6, 21, 6, 6,
    description="CPU usage inside the PBS VM (5-minute average). High during "
                "backup/dedup is expected. If it stays high with no backup "
                "running, suspect another process.",
))

# --- Datastore capacity (the main info of this dashboard) next to CPU ---
# The byte version of "Free Capacity" already exists in the Summary row (id 105) —
# a percentage gauge is enough here, plus one slot for a quick link to restore.
panels.append(gauge_panel(
    403,
    "Datastore Capacity",
    '(pbs_datastore_used_bytes{job="site-node-exporter"} / '
    'pbs_datastore_size_bytes{job="site-node-exporter"}) * 100',
    12, 21, 6, 6,
    description="Percentage of the PBS datastore used. This is the most important metric on "
                "this dashboard — if it fills, backup fails. Alert warning >85%, "
                "critical >95%.",
))

panels.append(stat_panel(
    404,
    "Recent Snapshots",
    'pbs_backup_snapshot_count{job="site-node-exporter"}',
    "none",
    18, 21, 6, 6,
    [
        {"color": RED, "value": None},
        {"color": RED, "value": 0},
        {"color": GREEN, "value": 2},
    ],
    decimals=0,
    description="Total snapshots stored. With VM 100+101 and 7 daily retention, "
                "a healthy value is around 14-30. 0 = no backup has ever been taken.",
))

# --- Memory ---
panels.append(gauge_panel(
    405,
    "pve2 Memory",
    '(1 - (node_memory_MemAvailable_bytes{job="site-node-exporter", '
    'instance="192.0.2.3:9100"} / '
    'node_memory_MemTotal_bytes{job="site-node-exporter", '
    'instance="192.0.2.3:9100"})) * 100',
    0, 27, 6, 6,
    description="pve2 memory usage. IMPORTANT: pve2 has only 7 GB. In the "
                "DR scenario (production VM running on pve2), stop the PBS VM "
                "first to avoid overcommitment.",
))

panels.append(gauge_panel(
    406,
    "PBS Memory",
    '(1 - (node_memory_MemAvailable_bytes{job="site-node-exporter", '
    'instance="192.0.2.4:9100"} / '
    'node_memory_MemTotal_bytes{job="site-node-exporter", '
    'instance="192.0.2.4:9100"})) * 100',
    6, 27, 6, 6,
    description="PBS VM memory usage (3 GB allocated). PBS uses memory "
                "for chunk-store cache — high but stable usage is "
                "normal and helps dedup speed.",
))

# --- Disk root ---
panels.append(gauge_panel(
    407,
    "pve2 root disk",
    '(1 - (node_filesystem_avail_bytes{job="site-node-exporter", '
    'instance="192.0.2.3:9100", mountpoint="/"} / '
    'node_filesystem_size_bytes{job="site-node-exporter", '
    'instance="192.0.2.3:9100", mountpoint="/"})) * 100',
    12, 27, 6, 6,
    description="pve2 root disk usage (32 GB for the hypervisor OS). "
                "Note: the PBS datastore disk is a SEPARATE disk — "
                "see the 'Datastore Capacity' gauge.",
))

panels.append(gauge_panel(
    408,
    "PBS root disk",
    '(1 - (node_filesystem_avail_bytes{job="site-node-exporter", '
    'instance="192.0.2.4:9100", mountpoint="/"} / '
    'node_filesystem_size_bytes{job="site-node-exporter", '
    'instance="192.0.2.4:9100", mountpoint="/"})) * 100',
    18, 27, 6, 6,
    description="PBS root disk usage (28 GB for the OS). Backup data "
                "is stored on /mnt/datastore (a separate 400 GB disk) — "
                "see the 'Datastore Capacity' gauge.",
))

# --- Timeseries complementing the gauges ---
# The focus of this row: what a gauge CANNOT answer — the direction of change
# and the pattern over time. Datastore capacity already has a trend panel in
# the "Trend & Capacity" row (id 301), so it is not repeated here.
panels.append(row_panel(500, "Host Resource Trend", 33))

panels.append(timeseries_panel(
    501,
    "pve2 & PBS memory (trend)",
    [target(
        '(1 - (node_memory_MemAvailable_bytes{job="site-node-exporter", '
        'instance=~"192.0.2.[34]:9100"} / '
        'node_memory_MemTotal_bytes{job="site-node-exporter", '
        'instance=~"192.0.2.[34]:9100"})) * 100',
        "{{instance}}",
    )],
    "percent",
    0, 34, 12, 7,
    description="pve2 and PBS memory trend. Useful to confirm usage is "
                "stable rather than creeping up (a sign of a memory leak). "
                "The gauges above are enough for current conditions.",
    thresholds=[
        {"color": GREEN, "value": None},
        {"color": YELLOW, "value": 85},
        {"color": RED, "value": 95},
    ],
    fill=10,
))

panels.append(timeseries_panel(
    502,
    "pve2 & PBS CPU (trend)",
    [target(
        '100 - (avg by (instance) (rate(node_cpu_seconds_total{job="site-node-exporter", '
        'instance=~"192.0.2.[34]:9100", mode="idle"}[5m])) * 100)',
        "{{instance}}",
    )],
    "percent",
    12, 34, 12, 7,
    description="CPU trend to see the pattern (e.g. a nightly spike during backup). "
                "The gauges above are enough for current conditions; this panel "
                "is for judging whether the numbers are reasonable over time.",
    thresholds=[
        {"color": GREEN, "value": None},
        {"color": YELLOW, "value": 80},
        {"color": RED, "value": 90},
    ],
    fill=10,
))

dashboard = {
    "annotations": {"list": []},
    "editable": True,
    "fiscalYearStartMonth": 0,
    "graphTooltip": 1,
    "id": None,
    "uid": "site-backup",
    "title": "Site Backup",
    "description": "Monitoring Proxmox Backup Server — status backup VM Target-1 "
                   "(100) dan Target-2 (101). Sumber metrik: "
                   "pbs-backup-monitor.sh di pve2, via textfile collector.",
    "tags": ["target-2", "backup", "pbs"],
    "timezone": "browser",
    "schemaVersion": 39,
    "version": 0,
    "refresh": "1m",
    "time": {"from": "now-7d", "to": "now"},
    "templating": {
        "list": [
            {
                "name": "instance",
                "label": "Host",
                "type": "query",
                "datasource": DS,
                "query": 'label_values(pbs_monitor_up{job="site-node-exporter"}, instance)',
                "refresh": 2,
                "includeAll": True,
                "multi": True,
                "allValue": ".+",
                "current": {},
            }
        ]
    },
    "panels": panels,
    "links": [
        {
            "title": "site Server Overview",
            "type": "link",
            "url": "/d/site-overview",
            "icon": "external link",
            "targetBlank": False,
        }
    ],
}

os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
with open(OUT_PATH, "w", encoding="utf-8") as f:
    json.dump(dashboard, f, indent=2, ensure_ascii=False)
    f.write("\n")

print("Dashboard ditulis: %s" % OUT_PATH)
print("Panel: %d (termasuk %d row)" % (
    len(panels), sum(1 for p in panels if p["type"] == "row")))
print("UID: %s" % dashboard["uid"])
