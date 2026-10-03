# Ansible Playbook — Site Monitoring Infrastructure

This playbook provisions the infrastructure that was **not already in code**, so
it becomes reproducible:

| Component | Host | What it sets up |
|---|---|---|
| NAT redirect for LokiSite | `pve` | iptables NAT rule + iptables-persistent so it survives a reboot |
| Docker textfile collector | `target-1`, `target-2` | script + systemd timer + directory + node_exporter flag |

## Two ways to run it

### Option 1: Ansible playbook (recommended, Linux/Mac/WSL)

Requires a Linux controller. Install Ubuntu WSL on Windows, or run from a
Linux/Mac box.

```bash
cd ansible/
ansible-playbook -i inventory.ini playbook.yml
```

### Option 2: Bash script (Windows git-bash alternative)

For Windows users without WSL. Equivalent logic to the Ansible playbook,
idempotent.

```bash
cd ansible/
bash setup-monitoring.sh all      # set up pve + target-1 + target-2
bash setup-monitoring.sh pve      # NAT redirect only
bash setup-monitoring.sh target-1 # textfile collector only
bash setup-monitoring.sh target-2 # textfile collector only
```

Pick whichever matches your environment. **Do not run both at the same time** —
they apply the same state; a conflict is not expected but the work is redundant.

## Quick start (Ansible)

```bash
cd ansible/

# Install Ansible (if needed)
pip install ansible-core

# Set inventory & private key paths in inventory.ini
# (defaults already use ~/.ssh/id_ed25519_*)

# Dry run (show which tasks would change, without executing)
ansible-playbook -i inventory.ini playbook.yml --check

# Execute
ansible-playbook -i inventory.ini playbook.yml

# Run a subset (e.g. only the pve NAT)
ansible-playbook -i inventory.ini playbook.yml --tags nat

# Run a subset (e.g. only docker-textfile on the site VMs)
ansible-playbook -i inventory.ini playbook.yml --tags textfile --limit site
```

## Inventory

See `inventory.ini`. SSH keys are assumed to be under `~/.ssh/id_ed25519_*`
(Windows: `C:\Users\<user>\.ssh\id_ed25519_*`).

## Tags

- `nat` — NAT setup on pve only
- `textfile` — set up the docker-textfile collector (script + directory)
- `nodeexp` — enable the textfile-collector flag in node_exporter
- (no tag) — run everything

## Files

- `inventory.ini` — host definitions
- `playbook.yml` — main playbook
- `files/docker-textfile.sh` — the script written to `/usr/local/bin/`

## Idempotency

Tasks are written to be idempotent (safe to re-run):

- `ansible.builtin.iptables` — Ansible detects whether the rule already exists
  via comment match, so a re-run only adds new rules
- `ansible.builtin.file` with `state: directory` — no-op if it already exists
- `ansible.builtin.copy` — detects changes by checksum, no-op if unchanged
- `ansible.builtin.lineinfile` with `regexp` — replaces a matching line, no-op
  if already correct
- `ansible.builtin.systemd` — detects service state, no-op if already
  enabled and started

## Why iptables-persistent

Without `iptables-persistent`, the NAT rule is **lost when pve reboots**.
Without the NAT, Grafana on the VPS cannot reach the site Loki push endpoint —
pve has nothing listening on that port, so the traffic is rejected.

`iptables-persistent` installs:

- `/etc/iptables/rules.v4` — the rule file restored at boot
- On Proxmox 7+ the iptables → nftables migration may require the `iptables-nft`
  package, but `iptables-persistent` still works in legacy mode

## Manual verification after a run

```bash
# pve: NAT rules are persistent
ssh root@192.0.2.2 'iptables -t nat -L PREROUTING -n -v && iptables -t nat -L OUTPUT -n -v'
ssh root@192.0.2.2 'grep 3100 /etc/iptables/rules.v4'

# pve: test the loopback NAT
ssh root@192.0.2.2 'curl -m 5 http://192.0.2.2:3100/ready'   # should return "ready"

# target-1/target-2: docker-textfile is running
ssh root@192.0.2.8 'systemctl status docker-textfile.timer'
ssh root@192.0.2.8 'cat /var/lib/node_exporter/textfile_collector/docker.prom'

# target-1/target-2: node_exporter exposes the docker metrics
ssh root@192.0.2.8 'curl -s http://127.0.0.1:9100/metrics | grep "^docker_container" | head'
```

## Not covered by this playbook

- VPS Grafana provisioning — already code-driven via `grafana/provisioning/`
  in the repo, deployed automatically by CI/CD
- Promtail Docker scrape config — already code-driven via `promtail/` in the repo
- Dashboard JSON — generated via `scripts/build-target-2-dashboard.py` in the repo
