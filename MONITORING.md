# Monitoring Stack — Documentation

Complete documentation for the monitoring stack (a VPS host plus the
remote site servers). Written chronologically, in the order the work was done.

## Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Components](#2-components)
3. [Setup Steps (Chronological)](#3-setup-steps-chronological)
4. [Dashboard Stages 1–8](#4-dashboard-stages-18)
5. [Alert Rules (20 Total)](#5-alert-rules-20-total)
6. [Site Infrastructure (NAT + Textfile Collector)](#6-site-infrastructure-nat--textfile-collector)
7. [CI/CD Workflow](#7-cicd-workflow)
8. [Troubleshooting](#8-troubleshooting)
9. [Repository File Structure](#9-repository-file-structure)

> **Wazuh SIEM is not covered in this document.** Wazuh has its own compose
> stack (`wazuh/docker-compose.yml`) and its own documentation in
> **README.md** — including agent setup, enrollment, agent IPs, and the
> Alertmanager integration. MONITORING.md focuses on the Prometheus + Grafana
> + Loki + Alertmanager stack.

---

## 1. Architecture Overview

```
┌─────────────────────────── VPS HOST (VPS_IP) ─────────────────────────────┐
│                                                                                │
│   ┌─ docker-compose stack ────────────────────────────────────────────────┐     │
│   │  Prometheus ──► Alertmanager ──► Telegram (push to phone)             │     │
│   │       │                                                               │     │
│   │       ├─ node-exporter        (VPS host metrics)                      │     │
│   │       ├─ docker-stats-exporter (VPS container metrics via textfile)   │     │
│   │       ├─ site-node-exporter   (192.0.2.2/.7/.8 via WireGuard)      │     │
│   │       └─ site-pve-exporter    (Proxmox API 192.0.2.2:9221)         │     │
│   │                                                                       │     │
│   │  Grafana ──► dashboards (VPS Monitoring + Site Monitoring)          │     │
│   │       │                                                               │     │
│   │       └─ LokiSite datasource ──► 192.0.2.2:3100 (NAT'd via pve)    │     │
│   │                                                                       │     │
│   │  Loki ◄──── Promtail (VPS container logs)                             │     │
│   │  Uptime Kuma (application endpoint monitoring)                        │     │
│   └───────────────────────────────────────────────────────────────────────┘     │
│                                                                                │
└────────────────────────────────────────────────────────────────────────────────┘
                                       │
                                       │ WireGuard (NAT 192.0.2.2:3100 → 10.200.200.1:3100)
                                       ▼
┌────────────────────────── SITE INFRASTRUCTURE (192.0.2.0/24) ───────────────┐
│                                                                                │
│   pve (192.0.2.2)                                                           │
│   ├─ pve-exporter (:9221)          → scraped by VPS Prometheus                 │
│   ├─ node-exporter (:9100)         → scraped by VPS Prometheus                 │
│   ├─ Promtail (pushes to 192.0.2.2:3100) → NAT'd → VPS Loki                 │
│   └─ iptables NAT rule (persistent via iptables-persistent)                    │
│                                                                                │
│   target-1 (192.0.2.8) — application VM                                     │
│   ├─ node-exporter + textfile collector (docker-textfile.sh via systemd timer) │
│   └─ Promtail                                                                  │
│                                                                                │
│   target-2 (192.0.2.7) — application VM                                     │
│   ├─ node-exporter + textfile collector (docker-textfile.sh via systemd timer) │
│   └─ Promtail                                                                  │
│                                                                                │
└────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Components

### VPS stack (docker-compose)

| Service | Role | Port |
|---|---|---|
| **prometheus** | Metric storage, alert-rule evaluation (20 rules, 15-day retention) | `127.0.0.1:9090` |
| **alertmanager** | Routes alerts to Telegram (2 receivers) | `127.0.0.1:9093` |
| **grafana** | Dashboards (VPS + remote site) | `127.0.0.1:3030` (HTTPS via grafana.example.net) |
| **loki** | Log aggregation, 14-day retention | internal (10.200.200.1:3100) |
| **promtail** | Scrapes VPS container logs → Loki | (sidecar) |
| **node-exporter** | VPS host metrics (CPU/RAM/disk/network) | `127.0.0.1:9100` |
| **docker-stats-exporter** | VPS container metrics via textfile (CPU/RAM/net/last_seen) | textfile dir |
| **uptime-kuma** | Application endpoint monitoring | `127.0.0.1:3033` (HTTPS via status.example.net) |

### Site servers (3 hosts)

| Host | IP | Installed |
|---|---|---|
| **pve** (Proxmox) | 192.0.2.2 | node-exporter, pve-exporter, Promtail, iptables NAT |
| **target-1** (VM) | 192.0.2.8 | node-exporter + textfile collector, Promtail |
| **target-2** (VM) | 192.0.2.7 | node-exporter + textfile collector, Promtail |

---

## 3. Setup Steps (Chronological)

### Phase 1: Initial stack (pre-existing)

- **Starting point:** a Docker Compose stack already running on the VPS with
  Prometheus, Grafana, Loki, Alertmanager, node-exporter, Promtail, Uptime
  Kuma, and cAdvisor.
- **Issue found:** cAdvisor could not read container metrics because the VPS
  Docker Engine uses the **containerd snapshotter** (not overlay2). Error:
  `failed to identify the read-write layer ID...`.

### Phase 2: Custom docker-stats-exporter (replacing cAdvisor)

- **Solution:** a Python service
  `docker-stats-exporter/docker_stats_exporter.py` that reads directly from
  the Docker Stats API over `docker.sock` and writes to a textfile that
  node_exporter scrapes.
- **Metric names:** `docker_container_cpu_usage_seconds_total`,
  `docker_container_memory_usage_bytes`, `docker_container_memory_limit_bytes`,
  `docker_container_network_*`, `docker_container_last_seen_timestamp_seconds`.

### Phase 3: Site monitoring setup

- **WireGuard** on the VPS with a peer that routes to `192.0.2.0/24`.
- **Promtail** on each site server, pushing to
  `http://192.0.2.2:3100/loki/api/v1/push`.
- **Manual NAT rule** on pve:
  `iptables -t nat -A PREROUTING -i wg0 -p tcp --dport 3100 -d 192.0.2.2 -j DNAT --to-destination 10.200.200.1:3100`
  so traffic to `192.0.2.2:3100` (what site Promtail uses) ends up at the
  VPS Loki (`10.200.200.1:3100`).
- **Scrape config** in `prometheus/prometheus.yml`:
  - `site-node-exporter` job: 192.0.2.2/.7/.8:9100 with label `location="site"`
  - `site-pve-exporter` job: 192.0.2.2 via pve-exporter

### Phase 4: Dashboard stages 1–8 (iterative improvement)

See [section 4](#4-dashboard-stages-18). Result: a 35-panel "Site Server
Overview" dashboard in the "Site Monitoring" folder.

### Phase 5: Alert rules + Alertmanager routing

See [section 5](#5-alert-rules-20-total). Result: 20 alerts in 5 groups,
routed by scope to one Telegram channel.

### Phase 6: Infrastructure persistence (NAT + textfile)

See [section 6](#6-site-infrastructure-nat--textfile-collector). Result:
persistent NAT via iptables-persistent, textfile collector via a systemd timer
(60s).

---

## 4. Dashboard Stages 1–8

Dashboard: **"Site Server Overview"** (uid `site-overview`) in the "Site
Monitoring" folder.
URL: `https://grafana.example.net/d/site-overview/site-server-overview`

Source: `scripts/build-target-2-dashboard.py` (a Python builder that generates
the dashboard JSON).

### 35-panel layout

```
y=0   [🖥️ Node Overview header — HTML with blue tint]
y=1   [KPI strip: Hosts UP | VMs Run | Alerts | Avg CPU⚪ | Avg Mem⚪ | Top CPU⚪ | Top Mem⚪ | Net RX]
y=5   [🏥 Host Health table — Status, CPU%, Mem%, Disk%, Uptime — all 3 hosts]
y=13  [CPU Usage %] [Memory Usage %] (timeseries with threshold lines)
y=21  [Disk / bargauge] [Network Traffic] (timeseries)
y=27  [CPU Steal + IOWait] [Load Avg 1/5/15] (timeseries)
y=34  [🏗️ Proxmox VE header — HTML with purple tint]
y=35  [🏗️ VM Status table — Status, CPU%, Mem%, RX, TX]
y=43  [🐳 Docker Container Health table — Status, Restarts, Health]
y=51  [CPU Usage per VM] [Memory Usage per VM] (Proxmox view)
y=59  [Disk I/O per VM] [Network I/O per VM] (Proxmox view)
y=66  [Storage Usage Proxmox — bargauge (local & LVM)]
y=72  [⚠️ Hypervisor abuse / steal detection header — HTML with red tint]
y=73  [🚨 Sustained CPU >85%] [CPU Steal Time] (with vector threshold lines)
y=81  [Disk I/O Anomaly] [Outbound Network Anomaly]
y=88  [📅 Recent Incidents — state-timeline (host/VM/container/alert state)]
y=96  [📋 Logs header — HTML with blue tint]
y=97  [Auth Log — login/SSH/sudo anomalies] (uses |~ regex, NOT |= literal)
y=107 [Journal — site applications]
y=117 [Docker Logs — site applications (error/warn/fail only)]
y=127 [💾 Mountpoint Disk Usage — every mountpoint, every host]
```

### Stage summary

| Stage | Panel IDs | Description |
|---|---|---|
| 1. KPI strip | 30, 31, 32, 37 | 8 panels: 4 stat + 4 gauge (speedometer style) |
| 2. Status tables | 50, 51 | Host Health + VM Status tables |
| 3. Docker Container Health | 52 | Requires docker-textfile collector on the VMs |
| 4. Threshold lines | 2, 3, 9, 10 | `thresholdsStyle.mode = "line+area"` (yellow/red at 70%/85%) |
| 5. Mountpoint Disk Usage | 53 | Per-mountpoint, excludes /run /sys /proc |
| 6. Section header HTML | 100, 200, 300, 400 | Colored background per section (blue/purple/red/blue) |
| 7. Recent Incidents timeline | 54 | State-timeline panel (host/VM/container/alert) |
| 8. Consistent color coding | 2, 3, 4, 9, 10, 13 | CPU 70/85%, Mem 75/90%, Disk 70/85% |

### Critical bugs fixed during development

| Bug | Cause | Fix |
|---|---|---|
| Tables error "cannot unmarshal number" | `"format": 1` (integer) in the table panel query | `"format": "table"` (string — Grafana 11 is strict) |
| Auth Log + Docker Logs panels empty | `\|=` literal match with a regex pattern `(...)` | `\|~ "(?i)(...)"` regex match |
| 16 VpsContainerDown false positives | 60s threshold too tight for docker-stats-exporter (16 containers → 30–60s latency) | Raised to 180s + moved `now = time.time()` to the end of collect() |

---

## 5. Alert Rules (20 Total)

File: `prometheus/alert.rules.yml`. Reload with
`curl -X POST http://127.0.0.1:9090/-/reload`.

### 5 groups

| Group | Rules | Job filter |
|---|---|---|
| `vps-host-alerts` (4) | VpsHostDown (critical), VpsHostHighCpu/Memory/LowDisk (warning/critical) | `job="node-exporter"` |
| `vps-container-alerts` (3) | VpsContainerDown (critical, 180s threshold), VpsContainerHighCpu/Memory (warning) | `job="node-exporter"` + docker-stats metrics |
| `site-host-alerts` (6) | SiteHostDown (critical), HighCpu/StealHigh/HighMemory/OutboundHigh (warning), LowDisk (critical, multi-mountpoint) | `job="site-node-exporter"` |
| `site-container-alerts` (3) | SiteContainerDown (critical), SiteContainerRestartDetected (warning), SiteContainerUnhealthy (critical) | `job="site-node-exporter"` + textfile metrics |
| `site-proxmox-alerts` (4) | SitePveExporterDown, SiteVMNotRunning (critical), SiteVMHighCpu, SiteStorageHigh (warning) | `job="site-pve-exporter"` |

### Severity routing

Alertmanager template: `alertmanager/alertmanager.yml.template` → rendered to
`alertmanager.generated.yml` by `deploy.sh` (envsubst).

- **Critical** (`severity=critical`): immediate (group_wait=0s), repeat 1h →
  receiver `telegram-critical`
- **Warning**: batched (group_wait=10s), repeat 6h → receiver
  `telegram-default`

Both receivers use the same Telegram channel (from the `TELEGRAM_CHAT_ID`
CI/CD variable). The message format includes the `scope` label so alerts can
be filtered by VPS vs. site.

### Inhibit rules

- VpsHostDown → suppresses VPS host resource alerts (avoids noise while a host
  is down)
- SiteHostDown → suppresses site host resource alerts (same logic)
- SiteVMNotRunning → suppresses site VM resource alerts
- SiteContainerDown → suppresses site container resource alerts

### Threshold values and rationale

- **CPU >85% for 5m** — a typical warning threshold; sustained means real load.
- **Memory >90% for 15m** (raised from 5m, 2026-09-16) — `wazuh-manager`
  routinely spikes above 90% whenever `wazuh-modulesd` updates the
  vulnerability feed (measured every 10–30 minutes, the spike lasts >5
  minutes). At 5m the alert was recurring noise, even though memory is
  otherwise stable around 30%. 15m separates a normal spike from a real leak:
  a genuine leak stays above 90% far longer and is still caught. The threshold
  was left at 90% so nothing is hidden.
- **Disk <15% for 10m** — critical, near full.
- **Container down >180s** — accounts for docker-stats-exporter latency
  (~30–60s across 16 containers).
- **Host steal sustained for 10m** — an indicator of an abusive neighbor VM.
- **Outbound >50Mbps for 10m** — exfiltration / DDoS detection.

---

## 6. Site Infrastructure (NAT + Textfile Collector)

Folder: `ansible/`, with:
- `inventory.ini` — host definitions (pve, target-1, target-2)
- `playbook.yml` — Ansible playbook (Linux/Mac/WSL controller)
- `setup-monitoring.sh` — bash equivalent (Windows git-bash)
- `README.md` — usage guide
- `files/docker-textfile.sh` — script template

### pve: NAT redirect (Loki only)

Three NAT rules added via iptables and saved to `/etc/iptables/rules.v4`:

```
PREROUTING -i wg0   -d 192.0.2.2 -p tcp --dport 3100 -j DNAT --to-destination 10.200.200.1:3100
PREROUTING -i vmbr0 -d 192.0.2.2 -p tcp --dport 3100 -j DNAT --to-destination 10.200.200.1:3100
OUTPUT               -d 192.0.2.2 -p tcp --dport 3100 -j DNAT --to-destination 10.200.200.1:3100
```

Persistent via the `iptables-persistent` package — restored automatically when
pve reboots.

> **This NAT is specific to Loki port 3100.** A NAT rule for Wazuh (ports
> 1514/1515) was installed once (2026-09-16) and then **removed**, because it
> broke agent IP visibility: the manager saw all connections coming from pve,
> so every site agent appeared as `10.200.200.2` and re-enrollment failed with
> `Duplicate IP`. The replacement is a direct route
> `10.200.200.0/24 via 192.0.2.2` on each VM (see README). The
> `setup_pve_wazuh_nat` function was removed from `setup-monitoring.sh`.

### target-1 & target-2: route to the VPS + docker-textfile collector

**Route (required by the Wazuh agent):**

```
10.200.200.0/24 via 192.0.2.2 dev ens18   # via NetworkManager, persistent
```

Applied with:

```bash
nmcli con mod "Wired connection 1" +ipv4.routes "10.200.200.0/24 192.0.2.2"
nmcli con up "Wired connection 1"
```

Or via script: `bash ansible/setup-monitoring.sh vm-route-wazuh <vm>`.

The VMs use **NetworkManager**, not netplan (`/etc/netplan/` is empty). The
default gateway stays on the site router (192.0.2.1) — this route only adds
a path to the WireGuard network; VM internet access is unaffected.

**Docker-textfile collector:**

What gets set up:
- `/var/lib/node_exporter/textfile_collector/` directory (owned by node_exporter)
- `/usr/local/bin/docker-textfile.sh` script (copied from the repo)
- `/etc/systemd/system/docker-textfile.service` + `.timer` (60s cycle)
- node_exporter flag `--collector.textfile.directory=/var/lib/node_exporter/textfile_collector`

Script output (every 60s):

```
docker_container_up{host="Target-1", container="target-1-app", image="..."} 1
docker_container_restart_count{host="Target-1", container="target-1-app", image="..."} 0
docker_container_health_status{host="Target-1", container="target-1-app", image="..."} 0
```

Current state:
- target-1: 2 containers (target-1-app, target-1-db), restart_count=0
- target-2: 4 containers (mongo-db, target-2-app [healthy], openspeedtest, redis-db), restart_count=0

### How to run the setup

```bash
# Linux/Mac/WSL — preferred (real Ansible)
ansible-playbook -i ansible/inventory.ini ansible/playbook.yml

# Windows git-bash — bash equivalent
bash ansible/setup-monitoring.sh all
# or target-specific:
bash ansible/setup-monitoring.sh pve         # NAT only
bash ansible/setup-monitoring.sh target-1    # textfile only
bash ansible/setup-monitoring.sh target-2    # textfile only
```

Idempotent — safe to re-run; a no-op when state is already correct.

---

## 7. CI/CD Workflow

```
Local code
    │
    │ git add -A && git commit -m "..." && git push
    ▼
GitHub (example-org/observability-security-stack)
    │
    │ GitHub Actions mirror workflow (.github/workflows/mirror.yml)
    │ → git push --mirror to GitLab
    ▼
GitLab (mirror repo)
    │
    │ GitLab CI/CD pipeline (.gitlab-ci.yml)
    │ → SSH to the VPS, scp files, run deploy.sh
    ▼
VPS production (VPS_IP)
    │
    │ deploy.sh:
    │  1. envsubst alertmanager.yml.template → alertmanager.generated.yml
    │  2. docker compose pull
    │  3. docker compose up -d
    │  4. Grafana auto-provisions new dashboards ("Site Monitoring" folder)
    │  5. Prometheus auto-loads new alert rules (~30s)
    ▼
Live (https://grafana.example.net)
```

### Strict workflow rules

1. **No direct VPS state changes** — every change goes through local code + push.
2. **Exception:** Ansible/bash scripts may SSH-run (code-driven infrastructure
   orchestration).
3. **The VPS is read-only for debugging** — error checking, log inspection,
   state verification.

---

## 8. Troubleshooting

### Dashboard error: "cannot unmarshal number into PromQueryFormat"

**Cause:** Table panel queries using `"format": 1` (integer).
**Fix:** Change to `"format": "table"` (string). Grafana 11 strict typing.
**Location:** `scripts/build-target-2-dashboard.py` (TBL definition).

### Log panels empty (Auth Log / Docker Logs)

**Cause:** The filter used `|=` (literal match) with a regex pattern
`(Failed password|Accepted|...)` — literal match does not match parentheses.
**Fix:** Change to `|~ "(?i)(...)"` (regex match, case-insensitive).
**Location:** `scripts/build-target-2-dashboard.py` (panels 19 and 21).

### Loki HTTP not reachable

**Cause:** Loki binds to `10.200.200.1`, not `127.0.0.1` (see `docker ps` ports).
**Fix:** Test against the correct IP/hostname, or use the NAT'd path
`192.0.2.2:3100` (site) or `10.200.200.1:3100` (VPS-local).

### NAT rule disappears after a pve reboot (legacy issue)

**Status:** FIXED. `iptables-persistent` is installed by the ansible setup and
rules are restored on boot.
**Verify:** `ssh root@192.0.2.2 'grep 3100 /etc/iptables/rules.v4'`

### Alert not firing even though the condition is true

1. Check rules are loaded: `http://127.0.0.1:9090/rules`
2. Check active alerts: `http://127.0.0.1:9090/alerts`
3. Check Alertmanager: `http://127.0.0.1:9093/alerts`
4. Check Telegram delivery
5. Test the query directly in Prometheus

### docker-stats-exporter stale data (>60s)

**Cause:** With 16+ containers, a single `collect()` loop takes 30–60s to
query the Docker API per container.
**Fix:** The `VpsContainerDown` threshold was raised to 180s (was 60s). The
`now = time.time()` bug was moved from the start of the loop to just before
the file write.
**Verify:** `docker logs docker-stats-exporter | tail -5` (should show no errors).

### Prometheus reload stuck (500 error)

**Cause:** YAML syntax error in alert.rules.yml (e.g. an invalid Go template).
**Fix:** Check `docker logs prometheus | grep -i error` and fix the template.
**Recover:** `docker compose restart prometheus` (full restart if reload fails).

---

## 9. Repository File Structure

```
observability-security-stack/
├── README.md                              ← main docs
├── MONITORING.md                          ← this file (monitoring-specific)
├── LICENSE                                ← MIT
├── .gitignore
├── docker-compose.yml                     ← VPS stack definition
├── deploy.sh                              ← deploy script (envsubst + compose)
│
├── ansible/                               ← infrastructure provisioning (code-driven)
│   ├── README.md
│   ├── inventory.ini                      ← host groups (pve, target-1, target-2)
│   ├── playbook.yml                       ← Ansible playbook
│   ├── setup-monitoring.sh                ← bash equivalent
│   └── files/
│       └── docker-textfile.sh             ← script template
│
├── prometheus/
│   ├── prometheus.yml                     ← scrape config
│   └── alert.rules.yml                    ← 20 rules (5 groups)
│
├── alertmanager/
│   ├── alertmanager.yml.template          ← templated config (envsubst)
│   └── alertmanager.generated.yml         ← GITIGNORED (generated)
│
├── grafana/
│   ├── provisioning/
│   │   ├── datasources/datasource.yml     ← Prometheus + LokiSite
│   │   └── dashboards/dashboard.yml       ← provider config (recursive scan)
│   └── dashboards/
│       ├── vps/
│       │   └── vps-overview.json
│       └── target-2/
│           ├── server-overview.json
│           ├── backup-status.json
│           └── target-1-http-security.json
│
├── scripts/
│   ├── build-backup-dashboard.py          ← dashboard builder
│   └── build-target-2-dashboard.py        ← dashboard builder
│
├── docker-stats-exporter/
│   └── docker_stats_exporter.py           ← container metrics via Docker API
│
├── promtail/
│   ├── promtail-config.yml                ← VPS log scrape config
│   └── promtail-config-target-1.yml       ← site log scrape config
│
├── nginx/
│   ├── nginx.conf                         ← host nginx reference
│   └── sites/                             ← vhost reference configs
│
└── wazuh/                                 ← SIEM stack (separate compose)
```

---

## Quick Reference

### Verify the monitoring stack is healthy (run on the VPS)

```bash
# Containers
docker ps --format 'table {{.Names}}\t{{.Status}}'

# Prometheus rules
curl -sS http://127.0.0.1:9090/api/v1/rules | python3 -c "import json,sys; print(sum(len(g['rules']) for g in json.load(sys.stdin)['data']['groups']))"

# Scrape targets
curl -sS http://127.0.0.1:9090/api/v1/targets | python3 -c "
import json, sys
r = json.load(sys.stdin)
for t in r['data']['activeTargets']:
    print(f\"{t['labels']['job']:25s} {t['labels'].get('instance','?'):30s} {t['health']}\")
"

# Active alerts
curl -sS http://127.0.0.1:9090/api/v1/alerts | python3 -c "import json,sys; print(len(json.load(sys.stdin)['data']['alerts']))"

# Loki
curl -sS http://10.200.200.1:3100/ready

# NAT redirect
ssh root@192.0.2.2 'curl -m 5 -sf http://192.0.2.2:3100/ready'

# Textfile collectors
ssh root@192.0.2.8 'systemctl is-active docker-textfile.timer && curl -s http://127.0.0.1:9100/metrics | grep -c ^docker_container_'
ssh root@192.0.2.7 'systemctl is-active docker-textfile.timer && curl -s http://127.0.0.1:9100/metrics | grep -c ^docker_container_'
```

### Common operations

```bash
# Reload Prometheus rules (after editing alert.rules.yml)
curl -X POST http://127.0.0.1:9090/-/reload

# Reload Alertmanager (after editing alertmanager.yml.template)
curl -X POST http://127.0.0.1:9093/-/reload

# Restart docker-stats-exporter (after editing the script)
docker restart docker-stats-exporter

# Verify deployment after a push
ls -la /opt/vps-monitoring/grafana/dashboards/target-2/server-overview.json
md5sum /opt/vps-monitoring/grafana/dashboards/target-2/server-overview.json
```

---

**Last updated:** 2026-09-16
**Status:** All systems operational
