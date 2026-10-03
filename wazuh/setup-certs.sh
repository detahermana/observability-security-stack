#!/usr/bin/env bash
#
# Generate self-signed certificates for the Wazuh stack (manager, indexer, dashboard).
# Run di host VPS sekali setelah `docker compose -f wazuh/docker-compose.yml up -d`
# atau setelah Wazuh image sudah di-pull.
#
# Idempotent: if certs already exist in the wazuh_certs volume, skip generation.
# Safe to re-run — it will not overwrite existing certs.
#
# Usage:
#   bash wazuh/setup-certs.sh
#
# Prasyarat:
#   - Docker is running and the user can run docker without sudo
#   - openssl installed (default on Ubuntu/Debian)
#   - The `wazuh_certs` volume exists (auto-created by docker compose up,
#     or pre-created manually: docker volume create wazuh_certs)
#
# ARCHITECTURE NOTE:
#   The `wazuh/wazuh-certs-generator:0.0.4` image we first used turned out to
#   be a bootstrap-only image — it downloads `wazuh-certs-tool.sh` from
#   packages.wazuh.com and runs it. The script URL there now returns an error
#   (the tool to create the certificates does not exist in any bucket). Fix:
#   download the script directly and run it on the host. It only needs openssl
#   + config.yml in the same folder.
#

set -euo pipefail

# Resolve paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/certs/config.yml"

# Paths
# Host cert folder that is bind-mounted into each container (see
# wazuh/docker-compose.yml). This folder path is RELATIVE to
# `wazuh/docker-compose.yml`, so it lives at `wazuh/certs/`.
CERTS_DIR="$(cd "${SCRIPT_DIR}/certs" 2>/dev/null && pwd || echo "${SCRIPT_DIR}/certs")"
CERTS_TOOL_URL="https://packages.wazuh.com/4.14/wazuh-certs-tool.sh"
# Temporary working folder for the script + config + output. When done, the
# certs in $WORK_DIR/wazuh-certificates/ are copied to the CERTS_DIR folder.
WORK_DIR="$(mktemp -d -t wazuh-certs-XXXXXX)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# --- Pre-flight checks ---
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found in PATH." >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: openssl not installed. Install: sudo apt-get install -y openssl" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: docker daemon not accessible (need to join the docker group or use sudo)." >&2
  exit 1
fi

# Create the certs folder (if not present)
mkdir -p "${CERTS_DIR}"

# --- Check whether certs already exist (idempotent) ---
echo "Checking whether certificates already exist in ${CERTS_DIR}..."
if [ -f "${CERTS_DIR}/wazuh.indexer.pem" ] && [ -f "${CERTS_DIR}/wazuh.indexer.key" ]; then
  echo "✓ Certificates already exist, skipping generation."
  echo ""
  echo "To force a re-generate, delete the certs folder:"
  echo "  rm -rf ${CERTS_DIR}"
  echo "then run this script again."
  exit 0
fi

# --- Download script + config ke WORK_DIR ---
echo "Downloading wazuh-certs-tool.sh from ${CERTS_TOOL_URL}..."
curl -fsSL -o "${WORK_DIR}/wazuh-certs-tool.sh" "${CERTS_TOOL_URL}"
chmod +x "${WORK_DIR}/wazuh-certs-tool.sh"

# Place config.yml in the same folder as the script (the script expects it there)
cp "${CONFIG_FILE}" "${WORK_DIR}/config.yml"

# --- Generate certs ---
echo ""
echo "Generating certificates (may take 1-2 minutes)..."
echo ""

# The script outputs to /tmp/wazuh-certificates/ on the host (hard-coded default).
# `bash ./wazuh-certs-tool.sh -A` = generate a new root CA + all certs from config.yml.
# (Without -A, the script only prints help and exits.)
cd "${WORK_DIR}"
bash ./wazuh-certs-tool.sh -A
cd - >/dev/null

# --- Copy cert dari tmp output ke volume ---
if [ ! -d "${WORK_DIR}/wazuh-certificates" ]; then
  echo "ERROR: cert output folder not found at ${WORK_DIR}/wazuh-certificates" >&2
  echo "Check the cert-tool log at ${WORK_DIR}/wazuh-certificates-tool.log (if present)." >&2
  exit 1
fi

echo ""
echo "Copying certs to ${CERTS_DIR}..."
# wazuh-certs-tool.sh outputs files named `<node>-key.pem` (dash).
# The Wazuh Docker images expect the filename `<node>.key` (dot) inside the
# container. We rename them in the CERTS_DIR folder before compose mounts them.
#
# Container path mapping:
#   wazuh.indexer-key.pem   -> wazuh.indexer.key   (indexer image expects dot)
#   wazuh.dashboard-key.pem -> wazuh.dashboard.key (dashboard image expects dot)
#   wazuh.manager-key.pem   -> wazuh.manager.key   (compose renames to filebeat.key on mount)
docker run --rm \
  -v "${WORK_DIR}/wazuh-certificates:/src:ro" \
  -v "${CERTS_DIR}:/dst" \
  alpine:latest \
  sh -c '
    set -e
    cp /src/admin.pem         /dst/admin.pem
    cp /src/admin-key.pem     /dst/admin-key.pem
    cp /src/root-ca.pem       /dst/root-ca.pem
    cp /src/root-ca.key       /dst/root-ca.key
    cp /src/wazuh.indexer.pem     /dst/wazuh.indexer.pem
    cp /src/wazuh.indexer-key.pem /dst/wazuh.indexer.key
    cp /src/wazuh.dashboard.pem   /dst/wazuh.dashboard.pem
    cp /src/wazuh.dashboard-key.pem /dst/wazuh.dashboard.key
    cp /src/wazuh.manager.pem     /dst/wazuh.manager.pem
    cp /src/wazuh.manager-key.pem /dst/wazuh.manager.key
    # Permission 644 — the script sets 600, but the Wazuh container runs as non-root UID 1000
    find /dst -type f \( -name "*.key" -o -name "*.pem" \) -exec chmod 644 {} \;
  '

# --- Verify ---
echo ""
echo "✓ Certificates generated. Contents of ${CERTS_DIR}:"
ls -la "${CERTS_DIR}"

echo ""
echo "Now restart the Wazuh stack to pick up the certs:"
echo "  docker compose -f docker-compose.yml -f wazuh/docker-compose.yml restart wazuh.manager wazuh.dashboard"