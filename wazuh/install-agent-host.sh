#!/usr/bin/env bash
#
# Install the Wazuh agent on the VPS HOST itself (not in a container).
#
# Called by deploy.sh after the Wazuh stack is up. Purpose: monitor the VPS
# host (SSH brute force, critical file changes, suspicious processes, etc.) so
# that the VPS running the SIEM is watched too — not just the site servers.
#
# DIFFERENT from ansible/files/install-wazuh-agent.sh (for the site):
#   - That script is used via Ansible from outside; this one runs locally on the VPS.
#   - This script needs sudo (installs packages + systemctl).
#
# IMPORTANT about MANAGER_IP:
#   Port 1515 (enrollment) and 1514 (agent comm) are bound to 10.200.200.1
#   (the VPS WireGuard IP), NOT 127.0.0.1. Measured: 127.0.0.1:1515 refused,
#   10.200.200.1:1515 OK. Because the VPS host itself has a wg0 interface with
#   that IP, the host agent uses 10.200.200.1 — no need to change the binding.
#
# Usage:
#   sudo AGENT_NAME="vps-host" MANAGER_IP="10.200.200.1" \
#     bash wazuh/install-agent-host.sh
#
# Idempotent: safe to re-run, no duplicate install/enroll.

set -euo pipefail

WAZUH_VERSION="${WAZUH_VERSION:-4.x.y}"   # pin to the exact Wazuh release you deploy
AGENT_NAME="${AGENT_NAME:-vps-host}"
MANAGER_IP="${MANAGER_IP:-10.200.200.1}"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: this script needs root. Run it with sudo." >&2
  exit 1
fi

echo "=== Wazuh agent for the VPS host ==="
echo "    agent name : ${AGENT_NAME}"
echo "    manager    : ${MANAGER_IP}"
echo "    version    : ${WAZUH_VERSION}"
echo

# --- 0. Check the manager is reachable (fail fast, clear message) ---
if ! timeout 5 bash -c "echo > /dev/tcp/${MANAGER_IP}/1515" 2>/dev/null; then
  echo "ERROR: ${MANAGER_IP}:1515 is not reachable." >&2
  echo "Make sure:" >&2
  echo "  - Wazuh stack is up : docker ps | grep wazuh-manager" >&2
  echo "  - wg0 interface up  : ip -brief addr show wg0" >&2
  echo "  - port listen      : sudo ss -tlnp | grep 1515" >&2
  exit 1
fi
echo "✓ Manager ${MANAGER_IP}:1515 reachable."

# --- 1. Install the package (skip if already present) ---
# Check the package via dpkg/rpm, NOT via /var/ossec/bin/wazuh-agent — that file
# does not exist in Wazuh (the binary is wazuh-agentd). Checking the wrong path
# makes the script always think the agent is not installed.
AGENT_INSTALLED=0
if dpkg -l 2>/dev/null | grep -q "^ii *wazuh-agent "; then
  AGENT_INSTALLED=1
elif rpm -q wazuh-agent >/dev/null 2>&1; then
  AGENT_INSTALLED=1
fi

if [ "${AGENT_INSTALLED}" -eq 1 ]; then
  echo "✓ Wazuh agent already installed, skipping."
else
  echo "Downloading + installing wazuh-agent ${WAZUH_VERSION}..."
  if command -v apt-get >/dev/null 2>&1; then
    DEB_URL="https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_${WAZUH_VERSION}-1_amd64.deb"
    curl -sSL -o /tmp/wazuh-agent.deb "${DEB_URL}"
    WAZUH_MANAGER="${MANAGER_IP}" apt-get install -y /tmp/wazuh-agent.deb
    rm -f /tmp/wazuh-agent.deb
  elif command -v yum >/dev/null 2>&1; then
    RPM_URL="https://packages.wazuh.com/4.x/yum/wazuh-agent-${WAZUH_VERSION}-1.x86_64.rpm"
    curl -sSL -o /tmp/wazuh-agent.rpm "${RPM_URL}"
    WAZUH_MANAGER="${MANAGER_IP}" yum install -y /tmp/wazuh-agent.rpm
    rm -f /tmp/wazuh-agent.rpm
  else
    echo "ERROR: unrecognized package manager (apt or yum required)." >&2
    exit 1
  fi
  echo "✓ Package installed."
fi

# --- 2. Set the manager address in ossec.conf (idempotent) ---
OSSEC_CONF="/var/ossec/etc/ossec.conf"
if grep -q "<address>${MANAGER_IP}</address>" "${OSSEC_CONF}"; then
  echo "✓ ossec.conf already points to ${MANAGER_IP}, skipping."
else
  echo "Set manager address = ${MANAGER_IP}..."
  cp -n "${OSSEC_CONF}" "${OSSEC_CONF}.bak.$(date +%s)" 2>/dev/null || true

  # Order matters: try replacing an EXISTING <address> value first.
  # A fresh Wazuh install defaults to <address>0.0.0.0</address> (or MANAGER_IP
  # if installed with env). Injecting a new <server> when one already exists
  # produces nested invalid tags:
  #   <server><address>0.0.0.0</address><server><address>10.200.200.1</address></server></server>
  # and the agent fails to start.
  sed -i "s|<address>MANAGER_IP</address>|<address>${MANAGER_IP}</address>|g" "${OSSEC_CONF}"
  sed -i "s|<address>0\.0\.0\.0</address>|<address>${MANAGER_IP}</address>|g" "${OSSEC_CONF}"

  # If it is still missing (a config with no <server> block at all), then inject.
  # Insert <server> right before </client>, not before </server>.
  if ! grep -q "<address>${MANAGER_IP}</address>" "${OSSEC_CONF}"; then
    if grep -q "</client>" "${OSSEC_CONF}"; then
      sed -i "0,/<\/client>/s|</client>|    <server><address>${MANAGER_IP}</address></server>\n  </client>|" \
        "${OSSEC_CONF}"
    else
      echo "ERROR: ossec.conf has no <client> block — unrecognized structure." >&2
      echo "Check manually: grep -n '<client>\\|</client>' ${OSSEC_CONF}" >&2
      exit 1
    fi
  fi

  # Verify the result is valid: exactly one <server> tag (not nested).
  SERVER_OPEN=$(grep -c "<server>" "${OSSEC_CONF}" || true)
  if [ "${SERVER_OPEN}" -gt 1 ]; then
    echo "ERROR: found ${SERVER_OPEN} <server> tags in ossec.conf — likely nested." >&2
    echo "Restore from backup: ls ${OSSEC_CONF}.bak.*" >&2
    exit 1
  fi
  echo "✓ ossec.conf updated (${SERVER_OPEN} server block)."
fi

# --- 3. Enrollment via agent config (NOT agent-auth) ---
#
# WHY not `agent-auth`:
#   `agent-auth -P ""` (empty password) hits a Wazuh bug — the manager rejects:
#     wazuh-authd: ERROR: Invalid request for new agent from: <ip>
#     agent-auth: ERROR: Invalid request for new agent. Unable to add agent
#   Upstream bug: https://github.com/wazuh/wazuh/issues/15230
#   ("authd starts under a registration password that is not valid for agents")
#
#   The path that works: auto-enrollment via config. The agent enrolls itself
#   when the service starts, with just a <client><enrollment> block. Proven:
#     wazuh-agentd: INFO: Valid key received
#     wazuh-authd: INFO: Agent key generated for '<name>'
#
# IMPORTANT — turn enrollment off once the key is obtained:
#   If <enabled>yes</enabled> is left on, EVERY agent restart tries to enroll
#   again. The manager rejects it because the name is taken, and the log fills:
#     wazuh-authd: WARNING: Duplicate name '<name>', rejecting enrollment.
#   Not fatal (the old key is still used, the connection works), but it clutters
#   the log. The correct pattern: enroll once -> <enabled>no</enabled>.
CLIENT_KEYS="/var/ossec/etc/client.keys"
ALREADY_ENROLLED=0
if [ -s "${CLIENT_KEYS}" ] && grep -qE " ${AGENT_NAME} " "${CLIENT_KEYS}" 2>/dev/null; then
  ALREADY_ENROLLED=1
fi

if [ "${ALREADY_ENROLLED}" -eq 1 ]; then
  echo "✓ Agent '${AGENT_NAME}' already has a key — enrollment disabled."
  ENROLL_ENABLED="no"
else
  echo "Agent not enrolled yet — enrollment enabled for this run."
  ENROLL_ENABLED="yes"
fi

# Write/update the <enrollment> block per the condition above.
python3 - "$OSSEC_CONF" "$AGENT_NAME" "$ENROLL_ENABLED" <<'PYEOF'
import re
import sys

path, agent_name, enabled = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()

block = (
    "    <enrollment>\n"
    f"      <enabled>{enabled}</enabled>\n"
    f"      <agent_name>{agent_name}</agent_name>\n"
    # use_source_ip: ask the manager to derive the IP from the enrollment
    # message, instead of storing "any". Without this the agent shows
    # "IP: any" on the dashboard. Must be paired with
    # <auth><use_source_ip>yes on the manager.
    "      <use_source_ip>yes</use_source_ip>\n"
    "    </enrollment>\n"
)

if "<enrollment>" in src:
    # Update the <enabled> value in the existing block (do not duplicate).
    src = re.sub(
        r"(<enrollment>\s*<enabled>)(yes|no)(</enabled>)",
        rf"\g<1>{enabled}\g<3>",
        src,
        count=1,
    )
    print(f"  <enrollment> updated -> <enabled>{enabled}</enabled>")
else:
    if "</client>" in src:
        src = src.replace("</client>", block + "  </client>", 1)
        print(f"  <enrollment> added (<enabled>{enabled}</enabled>)")
    else:
        print("  ERROR: no </client> in ossec.conf", file=sys.stderr)
        sys.exit(1)

open(path, "w").write(src)
PYEOF

# Protocol MUST be tcp: wazuh-remoted on this image listens on 1514/TCP.
if grep -q "<protocol>udp</protocol>" "${OSSEC_CONF}"; then
  echo "Correcting protocol udp -> tcp (remoted listens TCP)..."
  sed -i "s|<protocol>udp</protocol>|<protocol>tcp</protocol>|" "${OSSEC_CONF}"
fi
if ! grep -q "<protocol>tcp</protocol>" "${OSSEC_CONF}"; then
  echo "Adding <protocol>tcp</protocol>..."
  sed -i "0,/<address>${MANAGER_IP}<\/address>/s|<address>${MANAGER_IP}</address>|<address>${MANAGER_IP}</address>\n      <protocol>tcp</protocol>|" \
    "${OSSEC_CONF}"
fi

# --- 4. Enable + start (auto-enrollment terjadi saat start) ---
systemctl enable wazuh-agent >/dev/null 2>&1 || true
systemctl restart wazuh-agent

# --- 5. Wait for enrollment + verify (do not just trust the exit code) ---
echo "Waiting for enrollment (max 40 seconds)..."
ENROLLED=0
for i in $(seq 1 8); do
  sleep 5
  if [ -s "${CLIENT_KEYS}" ]; then
    ENROLLED=1
    echo "✓ Enrollment detected (attempt ${i}): $(wc -l < "${CLIENT_KEYS}") key(s)"
    break
  fi
  echo "  attempt ${i}/8 — client.keys still empty"
done

if [ "${ENROLLED}" -ne 1 ]; then
  echo "ERROR: agent not enrolled after 40 seconds." >&2
  echo "Check: sudo tail -30 /var/ossec/logs/ossec.log" >&2
  echo "     docker exec wazuh-manager /var/ossec/bin/agent_control -l" >&2
  exit 1
fi

if systemctl is-active --quiet wazuh-agent; then
  echo "✓ wazuh-agent active."
else
  echo "WARNING: wazuh-agent is not active." >&2
  echo "  systemctl status wazuh-agent && tail -30 /var/ossec/logs/ossec.log" >&2
  exit 1
fi

echo
echo "=== Done ==="
echo "Check: docker exec wazuh-manager /var/ossec/bin/agent_control -l"
echo "     (the 'Active' status appears a few seconds after the first keepalive)"
