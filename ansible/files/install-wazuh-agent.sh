#!/usr/bin/env bash
#
# Install the Wazuh agent on a target host and enroll it with the manager on the VPS.
# Used by Ansible (playbook.yml) to deploy to the site (pve/target-1/target-2)
# and by setup-monitoring.sh (Windows equivalent).
#
# How it works:
#   1. Download the Wazuh agent .deb/.rpm from packages.wazuh.com
#   2. Install via apt/yum
#   3. Edit /var/ossec/etc/ossec.conf — set <server><address> to MANAGER_IP
#   4. Run agent-auth once for enrollment (receive the agent key from the manager)
#   5. Enable + start the wazuh-agent systemd service
#
# Usage (idempotent — safe to re-run, no duplicates):
#   AGENT_NAME="site-pve" MANAGER_IP="10.200.200.1" bash install-wazuh-agent.sh
#
# Prerequisites:
#   - Already connected to the VPS WireGuard network (route to 10.200.200.1)
#   - Wazuh manager on the VPS already running and certs generated
#   - Agent name UNIQUE per host (hostname-based or descriptive)
#

set -euo pipefail

WAZUH_VERSION="${WAZUH_VERSION:-4.x.y}"   # pin to the exact Wazuh release you deploy
AGENT_NAME="${AGENT_NAME:-$(hostname)}"
MANAGER_IP="${MANAGER_IP:-10.200.200.1}"

# Detect package manager
if command -v apt-get >/dev/null 2>&1; then
  PKG_MGR="apt"
  WAZUH_DEB_URL="https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_${WAZUH_VERSION}-1_amd64.deb"
elif command -v yum >/dev/null 2>&1; then
  PKG_MGR="yum"
  WAZUH_RPM_URL="https://packages.wazuh.com/4.x/yum/wazuh-agent-${WAZUH_VERSION}-1.x86_64.rpm"
else
  echo "ERROR: unrecognized package manager (apt or yum required)." >&2
  exit 1
fi

echo "=== Installing Wazuh agent ${WAZUH_VERSION} on ${AGENT_NAME} (manager: ${MANAGER_IP}) ==="

# --- 1. Install package (idempotent: skip if already present) ---
if command -v /var/ossec/bin/wazuh-agent >/dev/null 2>&1 || \
   [ -f /var/ossec/bin/wazuh-agent ]; then
  echo "✓ Wazuh agent already installed, skipping."
else
  echo "Downloading + installing Wazuh agent..."
  if [ "${PKG_MGR}" = "apt" ]; then
    # PITFALL Debian 13 (trixie): the `lsb-release` package was REMOVED from the
    # trixie repo, while this wazuh-agent version still declares Depends: lsb-release.
    # As a result apt fails with:
    #   wazuh-agent : Depends: lsb-release but it is not installable
    # Fix: pull lsb-release 11.1.0 from Debian bookworm (this package is only a
    # Python script + symlink, with no compiled binary, so it is safe on trixie).
    if ! command -v lsb_release >/dev/null 2>&1; then
      echo "  lsb_release missing — trying to install from the repo first..."
      DEBIAN_FRONTEND=noninteractive apt-get install -y lsb-release >/dev/null 2>&1 || {
        echo "  Repo does not provide lsb-release (Debian 13?) — fetching from bookworm..."
        curl -sSL -o /tmp/lsb-release.deb \
          "http://deb.debian.org/debian/pool/main/l/lsb/lsb-release_11.1.0_all.deb"
        dpkg -i /tmp/lsb-release.deb
        rm -f /tmp/lsb-release.deb
      }
      command -v lsb_release >/dev/null 2>&1 || {
        echo "ERROR: lsb_release still cannot be installed." >&2
        exit 1
      }
      echo "  ✓ lsb_release installed."
    fi

    curl -sSL -o /tmp/wazuh-agent.deb "${WAZUH_DEB_URL}"
    WAZUH_MANAGER="${MANAGER_IP}" apt-get install -y /tmp/wazuh-agent.deb
    rm -f /tmp/wazuh-agent.deb
  else
    curl -sSL -o /tmp/wazuh-agent.rpm "${WAZUH_RPM_URL}"
    WAZUH_MANAGER="${MANAGER_IP}" yum install -y /tmp/wazuh-agent.rpm
    rm -f /tmp/wazuh-agent.rpm
  fi
fi

# --- 2. Configure ossec.conf — set server address (idempotent) ---
OSSEC_CONF="/var/ossec/etc/ossec.conf"
if grep -q "<address>${MANAGER_IP}</address>" "${OSSEC_CONF}"; then
  echo "✓ ossec.conf already points to ${MANAGER_IP}, skipping."
else
  echo "Updating ossec.conf: manager address = ${MANAGER_IP}..."
  cp -n "${OSSEC_CONF}" "${OSSEC_CONF}.bak.$(date +%s)" 2>/dev/null || true

  # Replace an existing <address> value first (placeholder or default 0.0.0.0).
  # Injecting a new <server> while one already exists produces nested tags that
  # are invalid and make the agent fail to start.
  sed -i "s|<address>MANAGER_IP</address>|<address>${MANAGER_IP}</address>|g" "${OSSEC_CONF}"
  sed -i "s|<address>0\.0\.0\.0</address>|<address>${MANAGER_IP}</address>|g" "${OSSEC_CONF}"

  # Only inject if there is genuinely no <server> block yet (insert before </client>).
  if ! grep -q "<address>${MANAGER_IP}</address>" "${OSSEC_CONF}"; then
    if grep -q "</client>" "${OSSEC_CONF}"; then
      sed -i "0,/<\\/client>/s|</client>|    <server><address>${MANAGER_IP}</address></server>\n  </client>|" \
        "${OSSEC_CONF}"
    else
      echo "ERROR: ossec.conf has no <client> block." >&2
      exit 1
    fi
  fi

  SERVER_OPEN=$(grep -c "<server>" "${OSSEC_CONF}" || true)
  if [ "${SERVER_OPEN}" -gt 1 ]; then
    echo "ERROR: found ${SERVER_OPEN} <server> tags — likely nested." >&2
    exit 1
  fi
  echo "✓ ossec.conf updated."
fi

# Protocol MUST be tcp. wazuh-remoted on this image listens on 1514/TCP:
#   wazuh-remoted: INFO: Started. Listening on port 1514/TCP (secure).
# The agent defaults to tcp, but if a templated config carries udp, correct it.
if grep -q "<protocol>udp</protocol>" "${OSSEC_CONF}"; then
  echo "Correcting protocol udp -> tcp..."
  sed -i "s|<protocol>udp</protocol>|<protocol>tcp</protocol>|" "${OSSEC_CONF}"
fi

# --- 3. Enrollment via agent config (NOT agent-auth) ---
#
# WHY not `agent-auth`:
#   `agent-auth -P ""` (empty password) hits a Wazuh bug — the manager rejects:
#     wazuh-authd: ERROR: Invalid request for new agent from: <ip>
#     agent-auth: ERROR: Invalid request for new agent. Unable to add agent
#   Upstream bug: https://github.com/wazuh/wazuh/issues/15230
#
#   The path that works: auto-enrollment via <client><enrollment>. The agent
#   enrolls itself when the service starts. Proven on the VPS host:
#     wazuh-agentd: INFO: Valid key received
#
# IMPORTANT — turn enrollment off once the key is obtained, so there is no
# repeated enroll attempt on every restart that triggers
# "Duplicate name, rejecting enrollment".
CLIENT_KEYS="/var/ossec/etc/client.keys"
ALREADY_ENROLLED=0
if [ -s "${CLIENT_KEYS}" ] && grep -qE " ${AGENT_NAME} " "${CLIENT_KEYS}" 2>/dev/null; then
  ALREADY_ENROLLED=1
fi

if [ "${ALREADY_ENROLLED}" -eq 1 ]; then
  echo "✓ Agent '${AGENT_NAME}' already has a key — enrollment disabled."
  ENROLL_ENABLED="no"
else
  echo "Enrolling agent '${AGENT_NAME}' with ${MANAGER_IP} (auto-enrollment)..."
  ENROLL_ENABLED="yes"
fi

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
    # "IP: any" on the dashboard. Must be paired with <auth><use_source_ip>yes
    # on the manager.
    "      <use_source_ip>yes</use_source_ip>\n"
    "    </enrollment>\n"
)

if "<enrollment>" in src:
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

# --- 4. Enable + start the service (auto-enrollment happens on start) ---
systemctl enable wazuh-agent >/dev/null 2>&1 || true
systemctl restart wazuh-agent

# --- 5. Wait for enrollment + verify (do not just trust the exit code) ---
echo "Waiting for enrollment (max 40 seconds)..."
ENROLLED=0
for i in $(seq 1 8); do
  sleep 5
  if [ -s "${CLIENT_KEYS}" ] && grep -qE " ${AGENT_NAME} " "${CLIENT_KEYS}" 2>/dev/null; then
    ENROLLED=1
    echo "✓ Enrollment OK (attempt ${i})"
    break
  fi
  echo "  attempt ${i}/8 — key not present yet"
done

if [ "${ENROLLED}" -ne 1 ]; then
  echo "ERROR: agent not enrolled after 40 seconds." >&2
  echo "Check: tail -30 /var/ossec/logs/ossec.log" >&2
  exit 1
fi

if systemctl is-active --quiet wazuh-agent; then
  echo "✓ wazuh-agent active."
else
  echo "WARNING: wazuh-agent is not active." >&2
  exit 1
fi

echo ""
echo "=== Done ==="
echo "Check the dashboard: https://siem.example.net -> Agents -> ${AGENT_NAME}"
echo "(the 'Active' status appears a few seconds after the first keepalive)"
