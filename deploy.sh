#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "The .env file does not exist yet. Copy from .env.example and fill it in first:"
  echo "  cp .env.example .env && nano .env"
  exit 1
fi

if ! command -v envsubst >/dev/null 2>&1; then
  echo "envsubst not found, install it first: sudo apt-get install -y gettext-base"
  exit 1
fi

set -a
source .env
set +a

envsubst < alertmanager/alertmanager.yml.template > alertmanager/alertmanager.generated.yml
echo "alertmanager.generated.yml generated from the template."

# Permissions for the Wazuh integrator script.
#
# WHY here: the Unix mode is NOT preserved by scp from Windows (git-bash does not
# keep the execute bit). The file arrives on the VPS as 644, and wazuh-integratord
# then fails to run it:
#   wazuh-integratord: ERROR: Couldn't execute command
#     (integrations /tmp/custom-alertmanager-*.alert ...). Check file and permissions.
# ...and as the wazuh user: "Permission denied" (exit 126).
#
# WHY 755 and NOT chown root:wazuh 750:
#
#   The Wazuh docs suggest `chown root:wazuh` + 750. But that CANNOT be used in
#   this flow, because the pipeline scp's `wazuh/` as the ubuntu user on the NEXT
#   deploy. If the file is owned by root, scp fails:
#     scp: dest open ".../custom-alertmanager": Permission denied
#     scp: failed to upload directory wazuh to /opt/vps-monitoring/
#   (happened on 2026-09-17, pipeline failed). The file is mounted `:ro` into the
#   container, so chown cannot be done from inside the container either
#   ("Read-only file system").
#
#   With 755 and owner ubuntu:ubuntu (uid 1000, gid 1001), the wazuh user
#   (uid 999) is neither owner nor group member, so it falls into the "others"
#   category — and 755 gives others execute. The script still runs.
#
# PROVEN NOT TO BE THE PROBLEM: integratord calls the script correctly (verified
# 2026-09-17 via `integrator.debug=2`): the alert is received ("Sending new
# alert"), filtered per `<level>` ("Skipping: Alert level is too low" for alerts
# below 10), and a manual send reaches Alertmanager (POST /api/v2/alerts
# succeeded, exit 0). So the 755 permission blocks nothing.
#
# `chown -R` on the integrations folder is avoided — only these two files need
# changing, and their ownership must stay ubuntu so the next deploy can overwrite
# the files.
if [ -d wazuh/config/wazuh.manager/integrations ]; then
  chmod 755 wazuh/config/wazuh.manager/integrations/custom-alertmanager
  chmod 755 wazuh/config/wazuh.manager/integrations/custom-alertmanager.py
  echo "Integrator custom-alertmanager permission set to 755."
fi

# Generate wazuh.yml from the template (fills in the real API password for the dashboard).
#
# WHY: wazuh.yml is bind-mounted into the dashboard and holds the API user
# credentials (`wazuh-wui`). That value is used AS-IS — no image entrypoint
# replaces the placeholder from env (confirmed by the Wazuh docs +
# wazuh/wazuh-docker#838). If the file holds a placeholder, the dashboard sends
# the wrong password to the manager API, gets 401 continuously, and the UI shows
# "The API connections could be down or inaccessible" even though the API is healthy.
#
# The real password exists only in the VPS environment, so the file is generated
# here (on the VPS) from the template — the repo stays free of credentials.
if [ -f wazuh/config/wazuh.dashboard/wazuh.yml.template ]; then
  # The value is taken from wazuh/.env (WAZUH_INDEXER_ADMIN_PASSWORD = the
  # wazuh-wui user password, same as the API_PASSWORD env in the compose file).
  # The .env source is already loaded above, but fall back to wazuh/.env if it is
  # not in the environment.
  if [ -z "${WAZUH_INDEXER_ADMIN_PASSWORD:-}" ] && [ -f wazuh/.env ]; then
    WAZUH_INDEXER_ADMIN_PASSWORD=$(grep '^WAZUH_INDEXER_ADMIN_PASSWORD=' wazuh/.env | cut -d= -f2-)
    export WAZUH_INDEXER_ADMIN_PASSWORD
  fi
  if [ -n "${WAZUH_INDEXER_ADMIN_PASSWORD:-}" ]; then
    envsubst < wazuh/config/wazuh.dashboard/wazuh.yml.template \
      > wazuh/config/wazuh.dashboard/wazuh.yml.generated
    chmod 600 wazuh/config/wazuh.dashboard/wazuh.yml.generated
    echo "wazuh.yml.generated generated from the template (API password injected)."

    # Quick check: make sure no placeholder is left.
    if grep -q '\${' wazuh/config/wazuh.dashboard/wazuh.yml.generated; then
      echo "WARNING: some variables are still unexpanded in wazuh.yml.generated:"
      grep -n '\${' wazuh/config/wazuh.dashboard/wazuh.yml.generated
    fi
  else
    echo "WARNING: WAZUH_INDEXER_ADMIN_PASSWORD not found, wazuh.yml.generated SKIPPED."
    echo "The dashboard will fail to connect to the API (401). Check wazuh/.env."
  fi
fi

# Set vm.max_map_count for OpenSearch (the Wazuh indexer needs large VMA).
# Idempotent: skip if already large enough, append to sysctl.conf so it persists.
CURRENT_MAP_COUNT=$(cat /proc/sys/vm/max_map_count)
if [ "${CURRENT_MAP_COUNT}" -lt 262144 ]; then
  echo "vm.max_map_count=${CURRENT_MAP_COUNT} < 262144, raising to 262144..."
  sudo sysctl -w vm.max_map_count=262144
  if ! grep -qE '^vm\.max_map_count\s*=' /etc/sysctl.conf; then
    echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf >/dev/null
  fi
else
  echo "vm.max_map_count=${CURRENT_MAP_COUNT} >= 262144, OK."
fi

# Detect whether the Wazuh stack must also be deployed (wazuh/.env present)
# `-f` must come before `pull`/`up` — docker compose parses global flags before
# the subcommand. Set it once up front and reuse for pull and up.
WAZUH_COMPOSE_ARGS=""
WAZUH_CERTS_DIR="wazuh/certs"
if [ -f wazuh/.env ]; then
  # Ensure the wazuh certs exist in the folder (idempotent, skip if present).
  # setup-certs.sh downloads wazuh-certs-tool.sh directly from packages.wazuh.com,
  # generates certs in /tmp, renames + copies them into wazuh/certs/.
  if [ ! -f "${WAZUH_CERTS_DIR}/wazuh.indexer.pem" ] || \
     [ ! -f "${WAZUH_CERTS_DIR}/wazuh.indexer.key" ]; then
    echo "Certificates not present, generating via wazuh/setup-certs.sh..."
    bash wazuh/setup-certs.sh
  fi
  WAZUH_COMPOSE_ARGS="-f wazuh/docker-compose.yml"
fi

if [ -f wazuh/.env ]; then
  set -a
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    export "$key=$value"
  done < wazuh/.env
  set +a
fi

# ---------------------------------------------------------------------------
# Detect changes to bind-mounted CONFIG files so containers get recreated.
#
# PROBLEM: `docker compose up -d` does NOT recreate a container when only the
# CONTENT of a bind-mounted file changes. Compose compares the HASH of the SERVICE
# DEFINITION (image, env, ports, mount paths) — not the content of mounted files.
# If a file's content changes, compose sees no change and the container keeps the
# old config. This is by design, confirmed by the docker/compose maintainers:
#   https://github.com/docker/compose/issues/13045 (config content changes
#   do not trigger a recreate) and #11900.
#
# Why it is fatal for the Wazuh manager: the image copies
# /wazuh-config-mount/etc/ossec.conf -> /var/ossec/etc/ossec.conf ONLY ONCE at
# init. If a new ossec.conf lands after the container is running, the container
# keeps the old config. If the old config is broken (e.g. an invalid <api> block,
# or a missing <remote>), wazuh-csyslogd/remoted fail to parse and init exits 1 →
# the ENTIRE manager daemon set fails to start, port 55000 is dead, the dashboard
# spams "ECONNREFUSED :55000", even though `docker ps` says the container is "Up".
# This actually happened on 2026-09-16.
#
# FIX: compute a per-file checksum of the bind-mounted configs, store it in
# .deploy-state. If a hash changes, run `up -d --force-recreate <service>` for
# ONLY the services using that file. `--force-recreate` is REQUIRED: without it
# compose silently does nothing (evidence: `up -d wazuh.manager` replies
# "Container wazuh-manager Running" and does not recreate).
# The recreate is limited to affected services so the indexer (2-3 minute JVM
# warmup) is not needlessly restarted.
# ---------------------------------------------------------------------------
CONFIG_STATE_FILE=".deploy-state"

# Mapping of config file -> compose service that must be recreated if the file
# changes. Service names use those in the compose file (wazuh.indexer, etc.).
# Format: "<file_path>:<service>" or "<file_path>:wazuh:<service>" when the
# service is in wazuh/docker-compose.yml (the "wazuh:" prefix = another compose file).
CONFIG_SERVICE_MAP=(
  # Root compose (monitoring)
  "prometheus/prometheus.yml:prometheus"
  "prometheus/alert.rules.yml:prometheus"
  "promtail/promtail-config.yml:promtail"
  "promtail/loki-config.yml:loki"
  "alertmanager/alertmanager.generated.yml:alertmanager"
  "grafana/provisioning/datasources/datasource.yml:grafana"
  "grafana/provisioning/dashboards/dashboard.yml:grafana"
  # Wazuh compose
  "wazuh/config/wazuh.manager/ossec.conf:wazuh:wazuh.manager"
  "wazuh/config/wazuh.manager/rules/local_rules.xml:wazuh:wazuh.manager"
  "wazuh/config/wazuh.indexer/wazuh.indexer.yml:wazuh:wazuh.indexer"
  "wazuh/config/wazuh.indexer/internal_users.yml:wazuh:wazuh.indexer"
  "wazuh/config/wazuh.dashboard/opensearch_dashboards.yml:wazuh:wazuh.dashboard"
  # wazuh.yml is generated from the template (see the top of the script). What is
  # hashed is the generated file, because that is what is mounted into the container.
  "wazuh/config/wazuh.dashboard/wazuh.yml.generated:wazuh:wazuh.dashboard"
)

STATE_TMP="${CONFIG_STATE_FILE}.new"
: > "$STATE_TMP"

# Services that need recreation, split per compose file.
RECREATE_ROOT=""
RECREATE_WAZUH=""

for entry in "${CONFIG_SERVICE_MAP[@]}"; do
  file="${entry%%:*}"
  svc_spec="${entry#*:}"

  [ -f "$file" ] || continue

  file_hash=$(md5sum "$file" | awk '{print $1}')
  echo "${file_hash}  ${file}" >> "$STATE_TMP"

  # Compare with the old hash (if state exists).
  old_hash=""
  if [ -f "$CONFIG_STATE_FILE" ]; then
    old_hash=$(grep -F "  ${file}" "$CONFIG_STATE_FILE" 2>/dev/null | awk '{print $1}' | head -1 || true)
  fi

  if [ "$old_hash" != "$file_hash" ]; then
    case "$svc_spec" in
      wazuh:*)
        svc="${svc_spec#wazuh:}"
        RECREATE_WAZUH="${RECREATE_WAZUH} ${svc}"
        ;;
      *)
        RECREATE_ROOT="${RECREATE_ROOT} ${svc_spec}"
        ;;
    esac
    echo "  config changed: ${file} (recreate: ${svc_spec})"
  fi
done

# Dedupe the service list (one service can use >1 file, e.g. grafana uses 2 files).
RECREATE_ROOT=$(printf '%s' "$RECREATE_ROOT" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')
RECREATE_WAZUH=$(printf '%s' "$RECREATE_WAZUH" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')

if [ -n "${RECREATE_ROOT}" ]; then
  echo "Recreate root compose :${RECREATE_ROOT}"
else
  echo "Recreate root compose : (none)"
fi
if [ -n "${RECREATE_WAZUH}" ]; then
  echo "Recreate wazuh compose:${RECREATE_WAZUH}"
else
  echo "Recreate wazuh compose: (none)"
fi

# ---------------------------------------------------------------------------
# Ensure the `wazuh_wazuh` network exists BEFORE the root compose is called.
#
# Why: the `alertmanager` service joins the `wazuh_wazuh` network (declared
# `external: true` in docker-compose.yml) so the Wazuh manager can resolve the
# name `alertmanager` and the custom-alertmanager integration works. That network
# belongs to the Wazuh compose project (`-p wazuh`), which is deployed AFTER the
# root compose below. So on a VPS that has never deployed Wazuh, the network does
# not exist and the root compose fails ("network wazuh_wazuh declared as
# external, but could not be found").
#
# Idempotent: `docker network inspect` first; create only if missing.
# On a normal VPS (Wazuh already running), this block does nothing.
#
# Note: no `com.docker.compose.*` label is used here, because the network created
# by the Wazuh project carries the label `com.docker.compose.network=wazuh`. A
# network we create manually (empty VPS) lacks that label — which is fine, since
# compose accesses it via `external: true`, which does not validate labels.
if ! docker network inspect wazuh_wazuh >/dev/null 2>&1; then
  echo "Network wazuh_wazuh not present, creating (used by alertmanager)..."
  docker network create wazuh_wazuh >/dev/null
  echo "Network wazuh_wazuh created."
else
  echo "Network wazuh_wazuh already exists, OK."
fi

# Step 1: a normal `up -d`. This handles NEW containers and services whose
# definition changed (image/env). With no service argument, compose converges ALL
# services to the definition — safe and idempotent, since compose only recreates
# those whose definition changed.
docker compose pull
docker compose up -d

# Step 2: an explicit recreate for services whose CONFIG FILE changed.
# `--force-recreate` is required here: compose does not detect bind-mount content
# changes, so without this flag nothing happens (see the comment above).
if [ -n "${RECREATE_ROOT}" ]; then
  docker compose up -d --force-recreate ${RECREATE_ROOT}
fi

if [ -n "${WAZUH_COMPOSE_ARGS}" ]; then
  docker compose ${WAZUH_COMPOSE_ARGS} pull
  docker compose ${WAZUH_COMPOSE_ARGS} up -d
  if [ -n "${RECREATE_WAZUH}" ]; then
    docker compose ${WAZUH_COMPOSE_ARGS} up -d --force-recreate ${RECREATE_WAZUH}
  fi
fi

# Save the new state AFTER all ups succeed (on failure, set -e stops the script
# before this line, so the old state stays saved and the recreate is retried on
# the next deploy).
mv "$STATE_TMP" "$CONFIG_STATE_FILE"
echo "Deploy state saved to ${CONFIG_STATE_FILE}."

# Sync the Wazuh Indexer OpenSearch Security config from the mounted files into
# the `.opendistro_security` index (persistent in the volume).
#
# Why this step is needed:
#   The OpenSearch Security plugin loads config from 2 sources:
#     1. Static files (the ones we mount, e.g. `internal_users.yml`)
#     2. A dynamic index `.opendistro_security` (persistent in the volume)
#   The first boot uses the static files. Subsequent boots use the cached index
#   and IGNORE the static files. So if we update `internal_users.yml` (e.g. add
#   the kibanaserver user), a container restart is not enough.
#
#   `securityadmin.sh` pushes config from the static files into the index,
#   syncing both. It MUST be run whenever the config changes.
#
# IMPORTANT (a bug that actually happened):
#   securityadmin.sh MUST connect to the REST API on port 9200, NOT 9300.
#   Port 9300 is the transport port (node-to-node), not HTTP. Pointing it at 9300
#   gives:
#     "ProtocolException: Not a valid protocol version: This is not an HTTP port"
#   Since we `docker exec` inside the same indexer container, use
#   `-h localhost -p 9200` (the indexer listens on 0.0.0.0:9200).
#
# Only runs when a Wazuh deploy is active. Skipped for an existing stack.
if [ -n "${WAZUH_COMPOSE_ARGS}" ]; then
  echo ""
  echo "Syncing Wazuh Indexer security config..."

  # Wait until the indexer is truly ready. After a RECREATE (not a normal start),
  # OpenSearch needs a JVM warmup + cluster state recovery >2 minutes — measured
  # >100 seconds on the 2026-09-16 deploy, which caused the security sync to be
  # missed. 24 attempts x 10s = a 240-second window.
  INDEXER_READY=0
  for i in $(seq 1 24); do
    if docker exec wazuh-indexer curl -sk -o /dev/null -w "%{http_code}" \
        "https://localhost:9200/_cluster/health" \
        -u "admin:${WAZUH_INDEXER_ADMIN_PASSWORD}" 2>/dev/null | grep -q "^200$"; then
      echo "Wazuh indexer ready (attempt $i)"
      INDEXER_READY=1
      break
    fi
    echo "Waiting for wazuh-indexer... (attempt $i/24)"
    sleep 10
  done

  if [ "${INDEXER_READY}" -eq 1 ]; then
    # Push every file in /usr/share/wazuh-indexer/config/opensearch-security/
    # into the .opendistro_security index. This tool ships in the wazuh-indexer
    # image under plugins/opensearch-security/tools/.
    #
    # `-p 9200` = REST API port (NOT the 9300 transport).
    # Output is captured into a variable first so it can be checked; on failure,
    # the error is shown in full (tail alone can hide a stack trace).
    SECADMIN_OUT=$(docker exec wazuh-indexer bash -c '
      export JAVA_HOME=/usr/share/wazuh-indexer/jdk
      export OPENSEARCH_PATH_CONF=/usr/share/wazuh-indexer/config
      /usr/share/wazuh-indexer/plugins/opensearch-security/tools/securityadmin.sh \
        -cd /usr/share/wazuh-indexer/config/opensearch-security/ \
        -cn wazuh-cluster \
        -h localhost \
        -p 9200 -nhnv \
        -cacert /usr/share/wazuh-indexer/config/certs/root-ca.pem \
        -cert /usr/share/wazuh-indexer/config/certs/admin.pem \
        -key /usr/share/wazuh-indexer/config/certs/admin-key.pem
    ' 2>&1) || true

    if echo "${SECADMIN_OUT}" | grep -q "Done with success"; then
      echo "Security config synced: $(echo "${SECADMIN_OUT}" | grep -c "SUCC:") config types OK"
    else
      echo "WARNING: securityadmin.sh did NOT succeed. Output:"
      echo "${SECADMIN_OUT}" | tail -25
      echo ""
      echo "The deploy continues, but indexer auth may fail."
      echo "Check manually: docker logs wazuh-dashboard | grep ResponseError"
    fi
  else
    echo "WARNING: wazuh-indexer not ready after 100 seconds, security config sync SKIPPED."
    echo "Re-run deploy.sh once the indexer is healthy."
  fi

  # -------------------------------------------------------------------------
NOOP
  #
  # WHY THIS STEP EXISTS (a bug that actually happened, 2026-09-16):
  #   The wazuh-manager image has cont-init.d/2-manager which runs
  #   create_user.py when the API_USERNAME + API_PASSWORD env vars are set. Its
  #   job: create/update the API user, then DISABLE other default users.
  #
  #   The problem is that on a fresh deploy this step does not always produce a
  #   working user — evidence: `2-manager` exits 0, no error output, but logging in
  #   as `wazuh-wui` to port 55000 returns:
  #     {"title": "Unauthorized", "detail": "Invalid credentials"}
  #   and the dashboard log spams "AxiosError: Request failed with status code 401".
  #
  #   The dependency chain is fragile: the entrypoint needs admin.json created, the
  #   script needs rbac.db already initialized, and the ordering races with daemon
  #   startup. If any one is off, the script exits 0 having done nothing — a silent
  #   failure, and the pipeline stays "green".
  #
  #   So we run it explicitly here: write admin.json from env, call create_user.py,
  #   delete admin.json, then VERIFY with a real login to the API. If the
  #   verification fails, the deploy fails hard (exit 1) so the pipeline does not
  #   report green while the API is unusable.
  # -------------------------------------------------------------------------
  echo ""
  echo "Ensuring the API user (wazuh-wui) has a matching password..."

  # Wait for the manager API to be ready. The manager starts after the indexer is
  # healthy, and needs a few seconds for apid to listen. Probe with curl without
  # credentials: 401 = up but not yet authenticated (what we want), 000 = not
  # listening yet.
  MANAGER_READY=0
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    CODE=$(docker exec wazuh-manager curl -sk -o /dev/null -w "%{http_code}" \
      https://localhost:55000/ 2>/dev/null || echo "000")
    if [ "${CODE}" = "401" ]; then
      echo "Wazuh manager API ready (attempt $i)"
      MANAGER_READY=1
      break
    fi
    echo "Waiting for wazuh-manager API... (attempt $i/12, HTTP ${CODE})"
    sleep 10
  done

  if [ "${MANAGER_READY}" -eq 1 ]; then
    # Write admin.json inside the container from env. Use printenv so the password
    # value never passes through argv/command-line (argv is visible in `ps`).
    API_SETUP_OUT=$(docker exec wazuh-manager sh -c '
      set -e
      if [ -z "${API_USERNAME:-}" ] || [ -z "${API_PASSWORD:-}" ]; then
        echo "API_USERNAME/API_PASSWORD not set in the container"
        exit 2
      fi
      printf "{\"username\": \"%s\", \"password\": \"%s\"}\n" \
        "$API_USERNAME" "$API_PASSWORD" \
        > /var/ossec/api/configuration/admin.json
      chown root:wazuh /var/ossec/api/configuration/admin.json
      chmod 660 /var/ossec/api/configuration/admin.json
      /var/ossec/framework/python/bin/python3 \
        /var/ossec/framework/scripts/create_user.py
      rm -f /var/ossec/api/configuration/admin.json
      echo "create_user.py done"
    ' 2>&1) || {
      API_SETUP_RC=$?
      echo "WARNING: API user setup failed (exit ${API_SETUP_RC}). Output:"
      echo "${API_SETUP_OUT}"
    }
    echo "${API_SETUP_OUT}" | tail -3

    # Verify: a real login to the API using the container env credentials.
    # THIS determines success/failure — not the create_user.py exit code.
    #
    # IMPORTANT about the auth method (got this wrong once, 2026-09-16):
    #   The /security/user/authenticate endpoint takes credentials via
    #   HTTP BASIC AUTH. If sent as a JSON body {"user":..,"password":..},
    #   the API rejects with 401 "Invalid credentials" in ~3ms — too fast for a DB
    #   query, a sign it is rejected before credential verification. This symptom is
    #   misleading: it reads like a wrong password, when the request format is wrong.
    #   Use curl -u so it sends basic auth (which is indeed supported).
    AUTH_OUT=$(docker exec wazuh-manager sh -c '
      curl -sk -o /dev/null -w "%{http_code}" \
        -u "$API_USERNAME:$API_PASSWORD" \
        "https://localhost:55000/security/user/authenticate?raw=true"
    ' 2>&1) || true

    if [ "${AUTH_OUT}" = "200" ]; then
      echo "API user OK: wazuh-wui login succeeded (HTTP 200)."
    else
      echo "FAILED: API user login did not succeed (HTTP ${AUTH_OUT})."
      echo "Check manually: docker exec wazuh-manager sh -c 'tail -30 /var/ossec/logs/api.log'"
      exit 1
    fi
  else
    echo "WARNING: wazuh-manager API not ready after 120 seconds."
    echo "API user setup SKIPPED. Check: docker logs wazuh-manager | tail -50"
  fi

  # ---------------------------------------------------------------------------
  # Wazuh agent on the VPS HOST itself (not in a container).
  #
  # Why: the agent monitors the VPS host — SSH brute force, critical file changes,
  # suspicious processes. Without it, the VPS running the SIEM is not watched by
  # its own SIEM.
  #
  # MANAGER_IP=10.200.200.1 (the VPS WireGuard IP), NOT 127.0.0.1: ports 1514/1515
  # are bound to the wg0 interface, so 127.0.0.1 is refused. The VPS host has wg0
  # with that IP, so the local agent can connect without changing the binding.
  #
  # A failure in this step does NOT fail the main deploy — the Wazuh stack itself
  # is already up and verified above. The host agent is extra monitoring; its
  # failure (e.g. needs sudo without NOPASSWD) is only reported.
  # ---------------------------------------------------------------------------
  if [ -f wazuh/install-agent-host.sh ]; then
    echo ""
    echo "Installing the Wazuh agent on the VPS host..."
    if [ "$(id -u)" -eq 0 ]; then
      AGENT_NAME="vps-host" MANAGER_IP="10.200.200.1" \
        bash wazuh/install-agent-host.sh || {
          echo "WARNING: host agent installation failed (not fatal)."
          echo "Run manually: sudo AGENT_NAME=vps-host MANAGER_IP=10.200.200.1 bash wazuh/install-agent-host.sh"
        }
    else
      # deploy.sh runs as a normal user (ubuntu). The agent needs root: try
      # sudo -n (no prompt). If a password is needed, skip with a message.
      if sudo -n true 2>/dev/null; then
        sudo -n AGENT_NAME="vps-host" MANAGER_IP="10.200.200.1" \
          bash wazuh/install-agent-host.sh || {
            echo "WARNING: host agent installation failed (not fatal)."
          }
      else
        echo "WARNING: passwordless sudo unavailable — host agent SKIPPED."
        echo "Run manually on the VPS:"
        echo "  sudo AGENT_NAME=vps-host MANAGER_IP=10.200.200.1 bash wazuh/install-agent-host.sh"
      fi
    fi
  fi
fi

echo ""
echo "Stack is up. Access (via SSH tunnel, all bound to 127.0.0.1 on the VPS):"
echo "  Grafana      : http://127.0.0.1:3030  (login: \$GF_SECURITY_ADMIN_USER)"
echo "  Uptime Kuma  : http://127.0.0.1:3033"
echo "  Prometheus   : http://127.0.0.1:9090"
echo "  Alertmanager : http://127.0.0.1:9093"
if [ -n "${WAZUH_COMPOSE_ARGS}" ]; then
  echo "  Wazuh Manager API : https://127.0.0.1:55000  (https, not http)"
  echo "  Wazuh Dashboard   : https://127.0.0.1:5601   (https, not http)"
  echo "                      public: https://siem.example.net (root path, basic auth + Wazuh login)"
fi