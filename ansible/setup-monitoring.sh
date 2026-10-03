#!/bin/bash
# Set up the site monitoring infrastructure — bash equivalent of
# ansible/playbook.yml. For Windows users without WSL Linux.
#
# Idempotent: safe to re-run. Tasks that are already correct are skipped or
# return no-op.
#
# Usage:
#   bash ansible/setup-monitoring.sh pve
#   bash ansible/setup-monitoring.sh target-1
#   bash ansible/setup-monitoring.sh target-2
#   bash ansible/setup-monitoring.sh wazuh-agent pve   # install Wazuh agent di pve
#   bash ansible/setup-monitoring.sh wazuh-agent target-1
#   bash ansible/setup-monitoring.sh wazuh-agent target-2
#   bash ansible/setup-monitoring.sh all    # run for all
#
# Requires: SSH keys at ~/.ssh/id_ed25519_proxmox / _target-1 / _target-2
# Targets reached via WireGuard (192.0.2.0/24) from the Windows host.

set -euo pipefail

PVE_KEY="$HOME/.ssh/id_ed25519_proxmox"
PVE2_KEY="$HOME/.ssh/id_ed25519_proxmox2"
PBS_KEY="$HOME/.ssh/id_ed25519_proxmox2_pbs"
Target-1_KEY="$HOME/.ssh/id_ed25519_target-1"
TARGET2_KEY="$HOME/.ssh/id_ed25519_target-2"
PVE_HOST="192.0.2.2"
PVE2_HOST="192.0.2.3"
PBS_HOST="192.0.2.4"
Target-1_HOST="192.0.2.8"
TARGET2_HOST="192.0.2.7"
# Wazuh Manager IP on the VPS (WireGuard interface). Site agents connect here.
WAZUH_MANAGER_IP="10.200.200.1"
WAZUH_VERSION="${WAZUH_VERSION:-4.x.y}"   # pin to the exact Wazuh release you deploy

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEXTFILE_SCRIPT_SRC="$SCRIPT_DIR/files/docker-textfile.sh"
PBS_MONITOR_SCRIPT_SRC="$SCRIPT_DIR/files/pbs-backup-monitor.sh"
WAZUH_AGENT_SCRIPT_SRC="$SCRIPT_DIR/files/install-wazuh-agent.sh"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

run_remote() {
    local host="$1" key="$2" cmd="$3"
    ssh "${SSH_OPTS[@]}" -i "$key" "root@$host" "$cmd"
}

copy_to_remote() {
    local host="$1" key="$2" src="$3" dst="$4" mode="${5:-0755}"
    local tmpfile
    tmpfile="$(mktemp)"
    if [[ "$src" == /* ]]; then
        cp "$src" "$tmpfile"
    else
        cp "$SCRIPT_DIR/$src" "$tmpfile"
    fi
    chmod "$mode" "$tmpfile"
    scp "${SSH_OPTS[@]}" -i "$key" "$tmpfile" "root@$host:/tmp/$(basename "$dst")"
    run_remote "$host" "$key" "mv /tmp/$(basename "$dst") $dst && chmod $mode $dst"
    rm -f "$tmpfile"
}

setup_pve_nat() {
    local host="$PVE_HOST" key="$PVE_KEY"
    echo ">>> [pve] Set up NAT redirect for LokiSite"

    echo "    Install iptables-persistent..."
    run_remote "$host" "$key" "DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent"

    echo "    Apply PREROUTING rule (wg0 → VPS Loki)..."
    run_remote "$host" "$key" "iptables -t nat -C PREROUTING -i wg0 -p tcp --dport 3100 -d 192.0.2.2 -j DNAT --to-destination 10.200.200.1:3100 2>/dev/null || iptables -t nat -I PREROUTING 1 -i wg0 -p tcp --dport 3100 -d 192.0.2.2 -j DNAT --to-destination 10.200.200.1:3100 -m comment --comment 'site-monitoring: VPS Loki push via WireGuard'"

    echo "    Apply PREROUTING rule (vmbr0 → VPS Loki)..."
    run_remote "$host" "$key" "iptables -t nat -C PREROUTING -i vmbr0 -p tcp --dport 3100 -d 192.0.2.2 -j DNAT --to-destination 10.200.200.1:3100 2>/dev/null || iptables -t nat -I PREROUTING 1 -i vmbr0 -p tcp --dport 3100 -d 192.0.2.2 -j DNAT --to-destination 10.200.200.1:3100 -m comment --comment 'site-monitoring: site-local Loki push'"

    echo "    Apply OUTPUT rule (pve loopback → VPS Loki)..."
    run_remote "$host" "$key" "iptables -t nat -C OUTPUT -p tcp --dport 3100 -d 192.0.2.2 -j DNAT --to-destination 10.200.200.1:3100 2>/dev/null || iptables -t nat -I OUTPUT 1 -p tcp --dport 3100 -d 192.0.2.2 -j DNAT --to-destination 10.200.200.1:3100 -m comment --comment 'site-monitoring: pve-local Loki push'"

    echo "    Save iptables rules..."
    run_remote "$host" "$key" "iptables-save > /etc/iptables/rules.v4"

    echo "    Verify rules..."
    run_remote "$host" "$key" "iptables -t nat -L PREROUTING -n -v | grep -E '3100' && iptables -t nat -L OUTPUT -n -v | grep -E '3100'"

    echo "    Test loopback NAT..."
    if run_remote "$host" "$key" "curl -m 5 -sf http://192.0.2.2:3100/ready" 2>&1 | grep -q "ready"; then
        echo "    ✓ NAT redirect works (Loki responded 'ready')"
    else
        echo "    ⚠ NAT test inconclusive (Loki may not be ready) — verify manually if needed"
    fi
}

setup_vm_textfile() {
    local host="$1" key="$2" hostname="$3"

    echo ">>> [$hostname] Setup docker-textfile collector"

    echo "    Create textfile collector directory..."
    run_remote "$host" "$key" "mkdir -p /var/lib/node_exporter/textfile_collector && chown node_exporter:node_exporter /var/lib/node_exporter/textfile_collector && chmod 0755 /var/lib/node_exporter/textfile_collector"

    echo "    Copy docker-textfile.sh script..."
    copy_to_remote "$host" "$key" "$TEXTFILE_SCRIPT_SRC" "/usr/local/bin/docker-textfile.sh" "0755"

    echo "    Install systemd service..."
    local svc_content="[Unit]
Description=Generate Docker container metrics for the node_exporter textfile collector

[Service]
Type=oneshot
ExecStart=/usr/local/bin/docker-textfile.sh
User=root
"
    run_remote "$host" "$key" "cat > /etc/systemd/system/docker-textfile.service" <<< "$svc_content"
    run_remote "$host" "$key" "chmod 0644 /etc/systemd/system/docker-textfile.service"

    echo "    Install systemd timer..."
    local timer_content="[Unit]
Description=Run docker-textfile.sh every 60 seconds

[Timer]
OnBootSec=10s
OnUnitActiveSec=60s

[Install]
WantedBy=timers.target
"
    run_remote "$host" "$key" "cat > /etc/systemd/system/docker-textfile.timer" <<< "$timer_content"
    run_remote "$host" "$key" "chmod 0644 /etc/systemd/system/docker-textfile.timer"

    echo "    Enable & start timer..."
    run_remote "$host" "$key" "systemctl daemon-reload && systemctl enable docker-textfile.timer && systemctl restart docker-textfile.timer"

    echo "    Enable textfile collector in node_exporter..."
    # Idempotent: only modify if --collector.textfile.directory is not present
    if ! run_remote "$host" "$key" "grep -q 'collector.textfile.directory' /etc/systemd/system/node_exporter.service"; then
        run_remote "$host" "$key" "sed -i 's|^ExecStart=/usr/local/bin/node_exporter\\b|ExecStart=/usr/local/bin/node_exporter --collector.textfile.directory=/var/lib/node_exporter/textfile_collector|' /etc/systemd/system/node_exporter.service"
        run_remote "$host" "$key" "systemctl daemon-reload && systemctl restart node_exporter"
        echo "    ✓ node_exporter restarted with textfile collector"
    else
        echo "    ✓ node_exporter already has textfile collector flag"
    fi

    echo "    Verify textfile output..."
    sleep 3
    run_remote "$host" "$key" "systemctl status docker-textfile.timer --no-pager | grep -E 'Active:|Trigger:' && echo '---' && cat /var/lib/node_exporter/textfile_collector/docker.prom 2>/dev/null | head -3"
}

setup_wazuh_agent() {
    local host="$1" key="$2" agent_name="$3" manager_ip="${4:-$WAZUH_MANAGER_IP}"

    echo ">>> [$agent_name] Install Wazuh agent (manager: ${manager_ip})"

    echo "    Copy install script..."
    copy_to_remote "$host" "$key" "$WAZUH_AGENT_SCRIPT_SRC" "/usr/local/bin/install-wazuh-agent.sh" "0755"

    echo "    Run install (idempotent)..."
    run_remote "$host" "$key" "AGENT_NAME='${agent_name}' MANAGER_IP='${manager_ip}' WAZUH_VERSION='${WAZUH_VERSION}' bash /usr/local/bin/install-wazuh-agent.sh"

    echo "    Verify wazuh-agent service..."
    run_remote "$host" "$key" "systemctl is-active wazuh-agent && systemctl is-enabled wazuh-agent"
}

setup_vm_wazuh_route() {
    local host="$1" key="$2" name="$3"

    # Add a route to 10.200.200.0/24 (the VPS WireGuard network) via pve.
    #
    # WHY: a site VM's default gateway is the site router (192.0.2.1), not pve.
    # Without this route, packets to the VPS leave to the router and vanish.
    # Only pve has the WireGuard interface (wg0).
    #
    # WHY a route and not DNAT: with DNAT on pve, the manager sees the connection
    # coming from pve, so the agent shows "IP: any" on the dashboard. A direct
    # route lets the manager record the VM's real IP (192.0.2.7/.8) — which is what
    # monitoring needs.
    #
    # NetworkManager is used (not netplan) — /etc/netplan is empty on these VMs.
    # `+ipv4.routes` adds without removing other routes; `con up` applies it.
    echo ">>> [$name] Add route to 10.200.200.0/24 via pve (${PVE_HOST})"

    local conn="Wired connection 1"
    run_remote "$host" "$key" "
        if ip route | grep -q '10.200.200.0/24'; then
            echo '  ✓ route already present, skip'
        else
            echo '  Adding route via nmcli...'
            nmcli con mod '$conn' +ipv4.routes '10.200.200.0/24 ${PVE_HOST}' &&
            nmcli con up '$conn' >/dev/null 2>&1
            echo '  ✓ route added and applied'
        fi
        echo '  --- verify ---'
        ip route | grep '10.200.200.0/24' || { echo '  ✗ ROUTE MISSING'; exit 1; }
        ping -c 2 -W 2 10.200.200.1 >/dev/null 2>&1 && echo '  ✓ manager 10.200.200.1 reachable' || { echo '  ✗ manager unreachable'; exit 1; }
        ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1 && echo '  ✓ internet still works' || echo '  ⚠ internet problem'
    "
}

setup_host_wazuh_route() {
    local host="$1" key="$2" name="$3" iface="$4"

    # Route to 10.200.200.0/24 (the VPS WireGuard network) via pve1.
    #
    # WHY it is needed: only pve1 has the wg0 interface. The other hosts
    # (pve2, pbs, target-1, target-2) have the site router as default gateway
    # (192.0.2.1), so packets to the VPS leave to the router and vanish.
    #
    # Two host categories, two different configuration methods:
    #   - pve2 / pbs: Debian + ifupdown (/etc/network/interfaces).
    #     No NetworkManager — uses `up ip route add`.
    #   - target-1 / target-2: NetworkManager (nmcli) — see setup_vm_wazuh_route.
    #
    # `up`/`down` are placed in the iface block so the route is installed at
    # boot too, and `|| true` prevents a boot failure if the route already exists.
    echo ">>> [$name] Add route to 10.200.200.0/24 via pve (${PVE_HOST})"

    local bak
    bak="/etc/network/interfaces.bak.$(date +%Y%m%d-%H%M%S)"

    run_remote "$host" "$key" "
        if grep -q '10.200.200.0/24' /etc/network/interfaces; then
            echo '  ✓ route already in config, skip'
        else
            cp /etc/network/interfaces '$bak'
            awk '/^iface ${iface} inet static/{f=1} f && /^\tgateway/{print; print \"\tup ip route add 10.200.200.0/24 via ${PVE_HOST} || true\"; print \"\tdown ip route del 10.200.200.0/24 via ${PVE_HOST} || true\"; f=2; next} {print}' /etc/network/interfaces > /tmp/interfaces.new
            cp /tmp/interfaces.new /etc/network/interfaces
            echo '  ✓ config updated (backup: $bak)'
        fi

        # Apply it now too, without ifdown/up — avoids dropping the SSH connection.
        ip route add 10.200.200.0/24 via ${PVE_HOST} 2>/dev/null || true

        echo '  --- verify ---'
        ip route | grep '10.200.200.0/24' || { echo '  ✗ ROUTE MISSING'; exit 1; }
        ping -c 2 -W 3 10.200.200.1 >/dev/null 2>&1 && echo '  ✓ manager 10.200.200.1 reachable' || { echo '  ✗ manager unreachable'; exit 1; }
        timeout 5 bash -c 'echo > /dev/tcp/10.200.200.1/1514' 2>/dev/null && echo '  ✓ port 1514 (agent) open' || echo '  ⚠ port 1514 closed'
    "
}

setup_pbs_backup_monitor() {
    local host="$PVE2_HOST" key="$PVE2_KEY"

    echo ">>> [pve2] Set up pbs-backup-monitor (PBS backup status metrics)"

    echo "    Ensure the textfile collector directory exists..."
    run_remote "$host" "$key" "mkdir -p /var/lib/node_exporter/textfile_collector && chown node_exporter:node_exporter /var/lib/node_exporter/textfile_collector && chmod 0755 /var/lib/node_exporter/textfile_collector"

    echo "    Copy pbs-backup-monitor.sh..."
    copy_to_remote "$host" "$key" "$PBS_MONITOR_SCRIPT_SRC" "/usr/local/bin/pbs-backup-monitor.sh" "0755"

    echo "    Ensure /etc/pbs-monitor.env exists (mode 600)..."
    run_remote "$host" "$key" "touch /etc/pbs-monitor.env && chmod 600 /etc/pbs-monitor.env && chown root:root /etc/pbs-monitor.env"
    # Warn if the token is not filled in yet — the script will fail to query PBS.
    if ! run_remote "$host" "$key" "grep -q PBS_TOKEN_SECRET /etc/pbs-monitor.env"; then
        echo "    ⚠ /etc/pbs-monitor.env does not contain PBS_TOKEN_ID/PBS_TOKEN_SECRET yet."
        echo "      Fill it in manually before the script can read data from PBS:"
        echo "        ssh -i $key root@$host 'cat > /etc/pbs-monitor.env << EOF"
        echo "        PBS_TOKEN_ID=\"monitoring@pbs!pve2\""
        echo "        PBS_TOKEN_SECRET=\"<token>\""
        echo "        EOF'"
    fi

    echo "    Install systemd service..."
    local svc_content="[Unit]
Description=Monitor PBS backup status for the node_exporter textfile collector
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pbs-backup-monitor.sh
User=root
"
    run_remote "$host" "$key" "cat > /etc/systemd/system/pbs-backup-monitor.service" <<< "$svc_content"
    run_remote "$host" "$key" "chmod 0644 /etc/systemd/system/pbs-backup-monitor.service"

    echo "    Install systemd timer (5 minutes)..."
    local timer_content="[Unit]
Description=Run pbs-backup-monitor.sh every 5 minutes

[Timer]
OnBootSec=60s
OnUnitActiveSec=300s

[Install]
WantedBy=timers.target
"
    run_remote "$host" "$key" "cat > /etc/systemd/system/pbs-backup-monitor.timer" <<< "$timer_content"
    run_remote "$host" "$key" "chmod 0644 /etc/systemd/system/pbs-backup-monitor.timer"

    echo "    Enable & start timer..."
    run_remote "$host" "$key" "systemctl daemon-reload && systemctl enable pbs-backup-monitor.timer && systemctl restart pbs-backup-monitor.timer"

    echo "    Ensure the textfile collector is active in node_exporter on pve2..."
    if ! run_remote "$host" "$key" "grep -q 'collector.textfile.directory' /etc/systemd/system/node_exporter.service"; then
        run_remote "$host" "$key" "sed -i 's|^ExecStart=/usr/local/bin/node_exporter\\b|ExecStart=/usr/local/bin/node_exporter --collector.textfile.directory=/var/lib/node_exporter/textfile_collector|' /etc/systemd/system/node_exporter.service"
        run_remote "$host" "$key" "systemctl daemon-reload && systemctl restart node_exporter"
        echo "    ✓ node_exporter restarted with the textfile collector"
    else
        echo "    ✓ node_exporter already has the textfile collector flag"
    fi

    echo "    Run once & verify the output..."
    run_remote "$host" "$key" "systemctl start pbs-backup-monitor.service; sleep 2; cat /var/lib/node_exporter/textfile_collector/pbs_backup.prom 2>/dev/null | grep -E '^pbs_monitor_up|^pbs_datastore_size' || echo '    ⚠ no output yet — check the PBS token'"
}

usage() {
    echo "Usage: $0 {pve|pve2|vm-route-wazuh {target-1|target-2}|host-route-wazuh {pve2|pbs}|target-1|target-2|wazuh-agent {pve|pve2|pbs|target-1|target-2}|all}"
    echo ""
    echo "Targets:"
    echo "  pve              — set up NAT redirect on 192.0.2.2 (Loki 3100)"
    echo "  pve2             — set up pbs-backup-monitor on 192.0.2.3 (PBS backup metrics)"
    echo "  vm-route-wazuh X — add route 10.200.200.0/24 via pve on VM X (nmcli)"
    echo "  host-route-wazuh X — add route 10.200.200.0/24 via pve on host X"
    echo "                     (pve2|pbs, using /etc/network/interfaces)"
    echo "  target-1              — set up docker-textfile on 192.0.2.8"
    echo "  target-2          — set up docker-textfile on 192.0.2.7"
    echo "  wazuh-agent X    — install the Wazuh agent on X, enroll to the VPS"
    echo "  all              — run all targets (textfile + route + wazuh-agent)"
    echo ""
    echo "Correct order for a VM (target-1/target-2):"
    echo "  1. bash ansible/setup-monitoring.sh vm-route-wazuh <vm>"
    echo "  2. bash ansible/setup-monitoring.sh wazuh-agent <vm>"
    echo ""
    echo "Correct order for a host (pve2/pbs):"
    echo "  1. bash ansible/setup-monitoring.sh host-route-wazuh <host>"
    echo "  2. bash ansible/setup-monitoring.sh wazuh-agent <host>"
    echo ""
    echo "SSH keys (must exist):"
    echo "  $PVE_KEY"
    echo "  $PVE2_KEY"
    echo "  $PBS_KEY"
    echo "  $Target-1_KEY"
    echo "  $TARGET2_KEY"
    exit 1
}

[[ $# -eq 0 ]] && usage

TARGET="$1"
case "$TARGET" in
    pve)
        setup_pve_nat
        ;;
    pve2|pbs-monitor)
        setup_pbs_backup_monitor
        ;;
    vm-route-wazuh)
        [[ $# -lt 2 ]] && { echo "Usage: $0 vm-route-wazuh {target-1|target-2}"; exit 1; }
        case "$2" in
            target-1)     setup_vm_wazuh_route "$Target-1_HOST"     "$Target-1_KEY"     "target-1" ;;
            target-2) setup_vm_wazuh_route "$TARGET2_HOST" "$TARGET2_KEY" "target-2" ;;
            *)       echo "Unknown vm-route-wazuh target: $2"; usage ;;
        esac
        ;;
    host-route-wazuh)
        [[ $# -lt 2 ]] && { echo "Usage: $0 host-route-wazuh {pve2|pbs}"; exit 1; }
        case "$2" in
            pve2) setup_host_wazuh_route "$PVE2_HOST" "$PVE2_KEY" "pve2" "vmbr0" ;;
            pbs)  setup_host_wazuh_route "$PBS_HOST"  "$PBS_KEY"  "pbs"  "nic0"  ;;
            *)    echo "Unknown host-route-wazuh target: $2"; usage ;;
        esac
        ;;
    target-1)
        setup_vm_textfile "$Target-1_HOST" "$Target-1_KEY" "target-1"
        ;;
    target-2)
        setup_vm_textfile "$TARGET2_HOST" "$TARGET2_KEY" "target-2"
        ;;
    wazuh-agent)
        [[ $# -lt 2 ]] && { echo "Usage: $0 wazuh-agent {pve|target-1|target-2}"; exit 1; }
        case "$2" in
            # All hosts use the REAL manager IP (10.200.200.1).
            #
            # target-1/target-2 previously went through DNAT on pve
            # (MANAGER_IP=192.0.2.2), but that made the manager see the connection
            # coming from pve — so the agent showed "IP: any" on the dashboard and
            # the VM's real IP was not visible.
            #
            # Now each VM has a direct route to 10.200.200.0/24 via pve
            # (installed by the `vm-route-wazuh` step), so the agent connects
            # directly and the manager records the VM's real IP. The Wazuh DNAT on
            # pve is no longer needed.
            pve)     setup_wazuh_agent "$PVE_HOST"     "$PVE_KEY"     "pve"     "$WAZUH_MANAGER_IP" ;;
            pve2)    setup_wazuh_agent "$PVE2_HOST"    "$PVE2_KEY"    "pve2"    "$WAZUH_MANAGER_IP" ;;
            pbs)     setup_wazuh_agent "$PBS_HOST"     "$PBS_KEY"     "pbs"     "$WAZUH_MANAGER_IP" ;;
            target-1)     setup_wazuh_agent "$Target-1_HOST"     "$Target-1_KEY"     "target-1"     "$WAZUH_MANAGER_IP" ;;
            target-2) setup_wazuh_agent "$TARGET2_HOST" "$TARGET2_KEY" "target-2" "$WAZUH_MANAGER_IP" ;;
            *)       echo "Unknown wazuh-agent target: $2"; usage ;;
        esac
        ;;
    all)
        setup_pve_nat
        setup_pbs_backup_monitor
        setup_vm_textfile "$Target-1_HOST" "$Target-1_KEY" "target-1"
        setup_vm_textfile "$TARGET2_HOST" "$TARGET2_KEY" "target-2"
        setup_vm_wazuh_route "$Target-1_HOST"     "$Target-1_KEY"     "target-1"
        setup_vm_wazuh_route "$TARGET2_HOST" "$TARGET2_KEY" "target-2"
        setup_host_wazuh_route "$PVE2_HOST" "$PVE2_KEY" "pve2" "vmbr0"
        setup_host_wazuh_route "$PBS_HOST"  "$PBS_KEY"  "pbs"  "nic0"
        setup_wazuh_agent "$PVE_HOST"     "$PVE_KEY"     "pve"     "$WAZUH_MANAGER_IP"
        setup_wazuh_agent "$PVE2_HOST"    "$PVE2_KEY"    "pve2"    "$WAZUH_MANAGER_IP"
        setup_wazuh_agent "$PBS_HOST"     "$PBS_KEY"     "pbs"     "$WAZUH_MANAGER_IP"
        setup_wazuh_agent "$Target-1_HOST"     "$Target-1_KEY"     "target-1"     "$WAZUH_MANAGER_IP"
        setup_wazuh_agent "$TARGET2_HOST" "$TARGET2_KEY" "target-2" "$WAZUH_MANAGER_IP"
        ;;
    *)
        usage
        ;;
esac

echo ""
echo "✓ Done. Verify:"
echo "  - NAT rule on pve: ssh root@192.0.2.2 'iptables -t nat -L PREROUTING -n'"
echo "  - Textfile on target-1: ssh root@192.0.2.8 'cat /var/lib/node_exporter/textfile_collector/docker.prom'"
echo "  - Textfile on target-2: ssh root@192.0.2.7 'cat /var/lib/node_exporter/textfile_collector/docker.prom'"
echo "  - Wazuh agent site: ssh root@192.0.2.X 'systemctl status wazuh-agent'"
echo "    Dashboard Wazuh: https://siem.example.net → Agents"