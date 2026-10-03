# Observability & Security Stack

A self-hosted monitoring and SIEM platform for a small fleet of production
servers: self-hosted VPS infrastructure plus two Proxmox nodes and their
guest VMs on a separate site. Everything is code — no clicking through a UI to set it up,
no manual configuration drift.

The stack answers three questions continuously:

1. **Is everything up?** — uptime, host resources, container health.
2. **Are we under attack?** — intrusion detection, brute-force blocking, log
   correlation (Wazuh SIEM).
3. **Can we prove it?** — dashboards, alert history, and incident records that
   quote evidence rather than intentions.

> Built and operated as a real deployment. Identifiers in this repository
> (hostnames, addresses, domains, ports) are generic placeholders, and some
> operational specifics are generalized. The architecture and engineering
> decisions reflect how the stack is actually run.

## Architecture

```
                    ┌──────────────────────── VPS host ────────────────────────────┐
                    │  Monitoring stack (docker-compose)                           │
                    │                                                              │
                    │  Prometheus ──► Alertmanager ──► Telegram                    │
                    │      │                                                       │
                    │      ├── node-exporter            (VPS host metrics)         │
                    │      ├── docker-stats-exporter    (per-container, custom)    │
                    │      ├── site-node-exporter       (remote hosts, over VPN)   │
                    │      └── site-pve-exporter        (Proxmox API)              │
                    │                                                              │
                    │  Grafana ──► VPS + remote-site dashboards                         │
                    │  Loki    ◄── Promtail (container logs)                       │
                    │  Uptime Kuma (endpoint availability)                         │
                    │                                                              │
                    │  Wazuh SIEM (separate compose stack)                         │
                    │    manager + indexer + dashboard                             │
                    │    manager ──► custom integrator ──► Alertmanager ──► Telegram│
                    └──────────────────────────────┬───────────────────────────────┘
                                                   │ WireGuard
                    ┌──────────────────────────────┴───────────────────────────────┐
                    │  Remote site: 2x Proxmox hosts + PBS + 2 application VMs     │
                    │  node-exporter + Promtail on every host                      │
                    │  Wazuh agents reporting back to the manager                  │
                    └──────────────────────────────────────────────────────────────┘
```

Two deliberately separate concerns:

- **Monitoring** (metrics, dashboards, uptime) lives in `docker-compose.yml`.
- **SIEM** (security events, file integrity, intrusion detection) lives in
  `wazuh/docker-compose.yml`.

They are separate compose projects on separate Docker networks. Exactly one
path is bridged: the Alertmanager joins the Wazuh network so the manager can
forward security alerts to Telegram. See
[§ Wazuh → Alertmanager integration](#wazuh-integration).

## What's in the stack

| Service | Role | Exposure (default) |
|---|---|---|
| `docker-stats-exporter` | Per-container CPU/RAM/network (custom Python, see below) | internal |
| `node-exporter` | VPS host CPU/RAM/disk/network | internal |
| `Prometheus` | Metric storage, alert-rule evaluation, 15-day retention | `127.0.0.1:9090` |
| `Alertmanager` | Alert routing → Telegram | `127.0.0.1:9093` |
| `Loki` | Log storage for all containers, 14-day retention | internal |
| `Promtail` | Ships container logs to Loki (incl. nginx access logs) | internal |
| `Grafana` | Combined metrics + logs + traffic dashboards | `127.0.0.1:3030` · `https://grafana.example.net` |
| `Uptime Kuma` | Endpoint availability checks + built-in Telegram alerts | `127.0.0.1:3033` · `https://status.example.net` |
| `Wazuh` | SIEM: manager + indexer + dashboard | `127.0.0.1:5601` · `https://siem.example.net` |

Every port binds to `127.0.0.1` on the VPS. Nothing is exposed directly to
the internet. Prometheus and Alertmanager (no built-in auth) are reachable
only through an SSH tunnel. Grafana, Uptime Kuma, and the Wazuh dashboard also
have HTTPS subdomains, because each ships its own login.

## Deploy

### 1. Prerequisites

- Docker Engine + Docker Compose plugin on the target host.
- `envsubst` (for Alertmanager config generation): `sudo apt-get install -y gettext-base`.
- A Telegram bot and chat ID for alert delivery.

  > **Bot token:** chat with `@BotFather` → `/newbot`.
  > **Chat ID:** message your bot once, then open
  > `https://api.telegram.org/bot<TOKEN>/getUpdates` and read `chat.id`.

### 2. Configure

```bash
cp .env.example .env
nano .env   # set GF_SECURITY_ADMIN_PASSWORD, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
```

### 3. Run

```bash
chmod +x deploy.sh
./deploy.sh
```

`deploy.sh` renders the Alertmanager config from the template and `.env`, then
runs `docker compose up -d`.

### 4. Verify

```bash
docker compose ps
```

### Accessing dashboards (SSH tunnel)

```bash
ssh -L 3030:127.0.0.1:3030 \
    -L 3033:127.0.0.1:3033 \
    -L 9090:127.0.0.1:9090 \
    -L 9093:127.0.0.1:9093 \
    monitoring-vps
```

Then open on the local machine:

- Grafana — http://localhost:3030 (credentials from `.env`)
- Uptime Kuma — http://localhost:3033 (create the admin account on first visit)
- Prometheus — http://localhost:9090
- Alertmanager — http://localhost:9093

## Domains & TLS

Grafana, Uptime Kuma, and the Wazuh dashboard have HTTPS subdomains because
each has its own authentication layer:

| URL | Service |
|---|---|
| `https://grafana.example.net` | Grafana |
| `https://status.example.net` | Uptime Kuma |
| `https://siem.example.net` | Wazuh Dashboard |

Terminated by **host-level nginx** on the VPS, not a container in this compose
file. The `nginx/sites/*.conf` files are **reference copies** of the live
configuration — CI/CD does **not** deploy them (host nginx is outside the
compose stack). To apply on a fresh VPS:

```bash
# 1. Point the DNS A record at the VPS IP
#    (e.g. grafana.example.net -> VPS_IP)

# 2. Install the vhost
sudo cp nginx/sites/monitoring.conf /etc/nginx/sites-available/monitoring
sudo ln -sf /etc/nginx/sites-available/monitoring /etc/nginx/sites-enabled/monitoring
sudo nginx -t && sudo systemctl reload nginx

# 3. Issue the certificate (certbot rewrites the vhost for HTTPS + redirect)
sudo certbot --nginx -d grafana.example.net --agree-tos -m <email> --redirect
```

**Pitfall — backup files.** Never leave `.bak` files inside
`sites-enabled/`. The `include sites-enabled/*` directive reads *every* file
there, and a backup containing `listen 80 default_server` makes `nginx -t`
fail with `a duplicate default server for 0.0.0.0:80`. Keep backups in
`/root/`.

## Why not cAdvisor for per-container metrics?

cAdvisor was deployed first and failed. This host's Docker Engine uses the
**containerd snapshotter** (`docker info` → `driver-type:
io.containerd.snapshotter.v1`). cAdvisor — tested up to v0.52.1 — cannot
detect containers in that mode:

```
Failed to create existing container: ... failed to identify the read-write
layer ID for container "...". - open
/rootfs/var/lib/docker/image/overlayfs/layerdb/mounts/.../mount-id:
no such file or directory
```

It still looks for the classic overlay2 `layerdb` layout, which no longer
exists under the containerd snapshotter (upstream issue, no fix at time of
writing). Every per-container panel rendered as "No data".

**Solution:** `docker-stats-exporter/docker_stats_exporter.py` — a small
Python service that reads stats straight from the Docker Stats API over
`docker.sock` (not the filesystem/layer path, so it is unaffected), then
writes Prometheus-format metrics into a textfile that `node-exporter` reads
via `--collector.textfile.directory`. It exposes:

```
docker_container_cpu_usage_seconds_total
docker_container_memory_usage_bytes
docker_container_memory_limit_bytes
docker_container_network_receive_bytes_total
docker_container_network_transmit_bytes_total
docker_container_last_seen_timestamp_seconds
```

all labelled by container `name`.

## Alert rules

`prometheus/alert.rules.yml` holds **20 rules in 5 groups**, split cleanly
between the VPS and the remote site:

| Group | Rules | Filter |
|---|---|---|
| `vps-host-alerts` | `VpsHostDown`, `VpsHostHighCpu`, `VpsHostHighMemory`, `VpsHostLowDisk` | `job="node-exporter"` |
| `vps-container-alerts` | `VpsContainerDown`, `VpsContainerHighCpu`, `VpsContainerHighMemory` | `job="node-exporter"` + docker-stats metrics |
| `site-host-alerts` | `SiteHostDown`, `SiteHostHighCpu`, `SiteHostStealHigh`, `SiteHostHighMemory`, `SiteHostLowDisk`, `SiteHostOutboundHigh` | `job="site-node-exporter"` |
| `site-container-alerts` | `SiteContainerDown`, `SiteContainerRestartDetected`, `SiteContainerUnhealthy` | `job="site-node-exporter"` + textfile metrics |
| `site-proxmox-alerts` | `SitePveExporterDown`, `SiteVMNotRunning`, `SiteVMHighCpu`, `SiteStorageHigh` | `job="site-pve-exporter"` |

Every rule carries a `scope=vps-*` or `scope=site-*` label. Alertmanager
routes by scope. Inhibit rules ensure a `HostDown` suppresses the downstream
resource alerts for the same scope, so one outage does not produce a storm.

`SiteHostStealHigh` is worth calling out: sustained CPU steal on a hypervisor
can indicate noisy or abusive neighbors (for example hypervisor abuse such as
cryptomining), so it is alerted on directly rather than waiting for the guest to
complain.

Reload after editing:

```bash
curl -X POST http://127.0.0.1:9090/-/reload
```

### Wazuh integration

Security alerts take a separate path:

```
wazuh-manager (integrations/custom-alertmanager, level >= 10)
  -> http://alertmanager:9093/api/v2/alerts
  -> alertmanager.yml.template route -> receiver telegram-default / telegram-critical
  -> Telegram
```

The level filter lives in `wazuh/config/wazuh.manager/ossec.conf`
(`<integration>` → `<level>10</level>`). The custom integrator is a small
Python script (`wazuh/config/wazuh.manager/integrations/custom-alertmanager.py`)
because the stock integration had no way to filter by level before forwarding.

> **Cross-network gotcha.** Wazuh manager lives on the `wazuh_wazuh` network,
> Alertmanager on the monitoring network. Docker DNS is per-network, so the
> manager cannot resolve `alertmanager` and integration fails with
> `Name or service not known`. The fix connects Alertmanager to the Wazuh
> network. It requires `external: true` — Compose validates the network
> *label*, not just the name, and without it deploy fails with
> `network wazuh_wazuh was found but has incorrect label`. Because of that,
> `deploy.sh` creates the network first if missing (idempotent).

## Rate limiting + fail2ban

Added in response to a flood of Wazuh rule **31151** alerts. That rule is not
from Grafana/Prometheus/Uptime Kuma — it reads `/var/log/nginx/access.log` and
fires when one IP produces repeated HTTP 4xx in a short window. The trigger was
internet scanners probing for exposed service endpoints through the router
vhost. Hundreds of alerts in a single day. Root cause: the VPS nginx had no
rate limiting and fail2ban only had an `sshd` jail.

Two layers:

1. **nginx rate limit.** Zone defined in `http {}` (`nginx/nginx.conf`), used
   per vhost: `limit_req zone=perip burst=40 nodelay;` + `limit_conn perconn 30;`
2. **fail2ban jail `nginx-ratelimit`.** Filter + jail in `fail2ban/`. Bans an
   IP that produces a burst of 400/404/429 responses within a short window. Uses
   **nftables** (this host's default), not iptables.

A regex location blocking sensitive-file probes
(`\.(php|env|bak|old|save)$`, `\.(git|htaccess)$` → 404) is applied to every
vhost.

**Deliberately no IP whitelist.** Dashboards are accessed from mobile networks
with rotating caller IPs, so a static whitelist would lock the operator out.
The domain + TLS setup exists precisely to allow access from anywhere.

```bash
# Re-apply on the VPS (manual — not via CI/CD):
sudo cp nginx/nginx.conf                       # merge the limit_req_zone block
sudo cp fail2ban/filter.d/nginx-ratelimit.conf /etc/fail2ban/filter.d/
sudo cp fail2ban/jail.local                    /etc/fail2ban/jail.local
sudo nginx -t && sudo systemctl reload nginx
sudo systemctl restart fail2ban
sudo fail2ban-client status                    # expect: nginx-ratelimit, sshd
```

**The easiest pitfall to hit:** `jail.d/defaults-debian.conf` on this host
sets `backend = systemd`, which cannot read log *files*. Without
`backend = auto` in `jail.local`, the `nginx-ratelimit` jail appears active
but never bans anyone. Full detail and rollback are in the comments of
`fail2ban/jail.local` and `nginx/nginx.conf`.

## Monitoring the remote site

Beyond the VPS itself, Prometheus scrapes a separate site:

| Job | Target | Metrics |
|---|---|---|
| `site-node-exporter` | `192.0.2.2/.7/.8:9100` | CPU, RAM, disk, network per host |
| `site-pve-exporter` | Proxmox API → `:9221/pve` | VM status, Proxmox CPU/RAM/storage |

### Log shipping: Promtail → Loki over the VPN

Promtail runs as a systemd service on every site host and pushes to the Loki
instance on the Proxmox host (closer than the VPS — one fewer VPN hop). An
iptables NAT rule on the Proxmox host transparently redirects that traffic
through WireGuard to the VPS Loki, so site logs and VPS logs land in the same
place, but Grafana is configured with **two datasources**:

- `Loki` → `http://loki:3100` — VPS container logs
- `LokiSite` → site Loki endpoint — systemd journal + Docker logs from the site

Dashboard provider config (`grafana/provisioning/dashboards/dashboard.yml`)
has one entry per datasource, loading into two Grafana folders: "VPS
Monitoring" and "Site Monitoring".

### Operational notes

- **The NAT rule is persistent.** `ansible/playbook.yml` installs
  `iptables-persistent` and saves rules to `/etc/iptables/rules.v4`, restored
  on boot. Without it, the rule vanishes on reboot and the `LokiSite`
  datasource breaks.
- **Docker textfile collector on the site.** Each application VM runs
  `docker-textfile.sh` via a systemd timer (60s), writing
  `docker_container_up`, `docker_container_restart_count`, and
  `docker_container_health_status` to the node-exporter textfile directory.
- **Hostname case matters.** LogQL queries must match the actual hostname
  casing (e.g. `host=~"Target-1|Target-2"`), not lowercase.

## Rebuilding site infrastructure

All site infra changes (the Proxmox NAT rule, the Docker textfile collector)
exist as **code** under `ansible/`. To re-apply after a VM rebuild:

```bash
# Linux/Mac/WSL — preferred (idempotent)
ansible-playbook -i ansible/inventory.ini ansible/playbook.yml

# Windows git-bash — equivalent bash script
bash ansible/setup-monitoring.sh all
```

Tags (`--tags nat`, `--tags textfile`, `--tags nodeexp`, `--tags wazuh-agent`)
let you run a single concern. See `ansible/README.md` for details.

### Prerequisites for site panels

- WireGuard up on the VPS with a peer routing to the site subnet. Without it,
  the `LokiSite` datasource cannot be queried from the Grafana container.
  Check `wg show`.
- Loki running on the site Proxmox host, listening on `:3100`.
- `node-exporter` on all three site hosts (`:9100`) and `pve-exporter` on the
  Proxmox host (`:9221`).

## Wazuh SIEM

Single-node Wazuh (Manager + Indexer + Dashboard) joins this repo as a
**second stack** with its own lifecycle:

- **VPS host** — SSH brute force, file-integrity changes, vulnerability scan,
  Docker events, nginx access-log anomalies.
- **Remote site** — intrusion detection, file integrity, compliance checks on
  the Proxmox hosts and application VMs.

### Components & resource budget

| Service | Image | Memory limit | Role |
|---|---|---|---|
| `wazuh-indexer` | `wazuh/wazuh-indexer:4.x` | 2g | OpenSearch backend — stores alerts and structured logs |
| `wazuh-manager` | `wazuh/wazuh-manager:4.x` | 1g | Rule analysis, event correlation, agent comms |
| `wazuh-dashboard` | `wazuh/wazuh-dashboard:4.x` | 1g | Web UI |

About 4g added on top of the existing ~2.5g stack — roughly 6.5g total. Tight
on an 8GB VPS. If it OOMs, raise VPS RAM before enabling Wazuh, not after.

### Prerequisites (on the VPS host, once)

```bash
# OpenSearch needs a higher mmap count
sudo sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf
```

`deploy.sh` applies this automatically on first run.

### Secrets

`wazuh/.env.example` is a **template only** — do not copy it to `wazuh/.env`
locally. The recommended workflow:

1. Read `wazuh/.env.example` for the required variables.
2. Generate strong passwords: `openssl rand -base64 24`.
3. Paste the values straight into a **GitLab File-type CI/CD variable** —
   never keep `wazuh/.env` on disk locally.

The VPS file is created by CI/CD from that variable on each deploy.
`wazuh/.env` is in `.gitignore`.

> **GitLab variable type matters.** Use **File**, not Variable —
> Variable only supports a single line, so a multi-line env file gets
> truncated to its first line. After saving, the variable should show a file
> icon, not a variable icon.

### Certificates (once)

```bash
bash wazuh/setup-certs.sh
```

Downloads the official `wazuh-certs-tool.sh` from `packages.wazuh.com`,
generates certificates for indexer/manager/dashboard, renames them to the
paths the images expect, and places them in `wazuh/certs/`. Idempotent.

### Reverse proxy pitfall — the login loop

The Wazuh dashboard was briefly behind HTTP basic auth and it broke login.
Basic auth at the edge sends an `Authorization` header upstream, and OpenSearch
Dashboards uses that same header for its own authentication. The dashboard
swallowed the nginx credentials and **ignored the real login form**, producing
an endless login loop.

Basic auth was removed. If it is ever re-added, the proxy **must** strip the
header:

```nginx
proxy_set_header Authorization "";
```

Other pitfalls from bringing this up:

1. **`proxy_pass` must be `https://`.** The dashboard only serves HTTPS
   (`server.ssl.enabled: true`). Forcing `http://` yields
   `upstream sent no valid HTTP/1.0 header` and HTTP 000 to the caller.
2. **The UI is at `/`, not `/dashboard`.** `/dashboard` is an internal
   endpoint that returns 401.
3. **To tell a 401 apart** — nginx sends `WWW-Authenticate: Basic realm=...`,
   the dashboard sends `osd-name: wazuh.dashboard`. If `osd-name` is present,
   basic auth already passed and the 401 is the dashboard's normal response to
   a request without a session cookie.

### An agent on the VPS itself

The VPS that runs the SIEM is also monitored by it — otherwise the most
critical host is the only unprotected one. `deploy.sh` installs the agent
automatically after the manager is up and the API is verified (idempotent).

```bash
docker exec wazuh-manager /var/ossec/bin/agent_control -l
# Expect: Name: vps-host, IP: <wireguard-ip>, Status: Active
```

> `MANAGER_IP` must be the WireGuard address, not `127.0.0.1` — the agent
> connects over the VPN interface, not loopback.

## CI/CD: GitHub → GitLab → VPS

```
push to GitHub (main)
  -> GitHub Actions ".github/workflows/mirror.yml" (git push --mirror to GitLab)
  -> GitLab receives push -> pipeline ".gitlab-ci.yml" runs
       deploy: scp docker-compose.yml + configs + .env to the VPS,
               then SSH and run deploy.sh
```

GitLab Free has no automatic pull-mirroring from GitHub, so the direction is
reversed: GitHub Actions pushes to GitLab.

### Setup

1. Create an empty GitLab project (**no** README/gitignore, to avoid a
   conflict on the first mirror push).
2. Create a GitLab access token with `write_repository` scope.
3. In the GitHub repo → **Settings → Secrets and variables → Actions**, add:
   - `GITLAB_TOKEN` — the token from step 2
   - `GITLAB_REPO` — e.g. `gitlab.com/example-org/observability-security-stack.git`

### GitLab CI/CD variables

| Variable | Type | Purpose |
|---|---|---|
| `SSH_PRIVATE_KEY` | Variable | Deploy private key. **Do not** mask it (contains newlines). Mark protected. |
| `VPS_HOST` | Variable | VPS IP or hostname |
| `VPS_USER` | Variable | SSH user on the VPS (needs `docker` permission) |
| `VPS_PROJECT_DIR` | Variable | Project directory on the VPS (created by the pipeline) |
| `PROD_ENV_FILE` | **File** | The filled-in `.env` with production values |
| `PROD_WAZUH_ENV_FILE` | **File** | The filled-in `wazuh/.env` with production values |

> Both env files **must** be GitLab **File**-type variables. Variable-type
> values are single-line only and will silently truncate a multi-line env file.

## Repository layout

```
.
├── docker-compose.yml              # monitoring stack
├── deploy.sh                       # render config, bring stack up
├── .env.example                    # required variables
├── alertmanager/                   # alert routing template
├── ansible/                        # site infra as code (NAT, textfile, agents)
├── docker-stats-exporter/          # custom per-container metrics exporter
├── fail2ban/                       # filters + jails
├── grafana/
│   ├── dashboards/                 # provisioned dashboard JSON
│   └── provisioning/               # datasources + dashboard providers
├── nginx/                          # host-nginx vhost reference configs
├── prometheus/                     # scrape config + 20 alert rules
├── promtail/                       # log shipping config
├── wazuh/                          # SIEM stack (separate compose)
├── docs/                           # incident and hardening records
├── MONITORING.md                   # deep-dive operational documentation
└── README.md
```

## Documentation

- `MONITORING.md` — full operator documentation: setup chronology, dashboard
  stages, all 20 alert rules, troubleshooting.
- `docs/` — dated incident and hardening records. Each quotes verification
  evidence, not plans.

## License

MIT — see [LICENSE](LICENSE).
