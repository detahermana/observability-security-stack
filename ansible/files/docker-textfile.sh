#!/bin/bash
# Generate Docker container metrics for the node_exporter textfile collector.
# Output metrics (Prometheus text format):
#   - docker_container_up (gauge 0/1)        — running state
#   - docker_container_restart_count (counter) — restarts since container created
#   - docker_container_health_status (gauge 0-3) — healthcheck state
#                                              0=none/no-healthcheck, 1=starting,
#                                              2=healthy, 3=unhealthy
#
# Used by the "Docker Container Health" dashboard (id=52) in site-server-overview.
# The restart count matters for detecting crash loops (a restart count > 0 means
# the container died and was restarted by the Docker daemon).
#
# Run as root via a systemd timer (docker-textfile.timer) every 60 seconds.
# Output is written to /var/lib/node_exporter/textfile_collector/docker.prom,
# automatically included in node_exporter /metrics via the
# --collector.textfile.directory flag.

set -e

OUTDIR="/var/lib/node_exporter/textfile_collector"
OUTFILE="$OUTDIR/docker.prom"
TMPFILE="$OUTFILE.tmp"

HOSTNAME_SHORT=$(hostname -s)

{
  echo "# HELP docker_container_up Container status (1=running, 0=stopped/restarting/exited)"
  echo "# TYPE docker_container_up gauge"
  echo "# HELP docker_container_restart_count Number of times container has been restarted"
  echo "# TYPE docker_container_restart_count counter"
  echo "# HELP docker_container_health_status Docker healthcheck status (0=none, 1=starting, 2=healthy, 3=unhealthy)"
  echo "# TYPE docker_container_health_status gauge"

  # Loop over all containers (running + stopped)
  docker ps -a --format '{{.Names}}|{{.Image}}' | while IFS='|' read -r name image; do
    name_clean="${name#/}"

    # Inspect for the full data. Fallback defaults if the container is gone.
    state=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || echo "unknown")
    restart_count=$(docker inspect --format '{{.RestartCount}}' "$name" 2>/dev/null || echo 0)
    health=$(docker inspect --format '{{if eq .State.Health.Status ""}}none{{else}}{{.State.Health.Status}}{{end}}' "$name" 2>/dev/null || echo "none")

    if [ "$state" = "running" ]; then up=1; else up=0; fi

    case "$health" in
      starting) h=1 ;;
      healthy) h=2 ;;
      unhealthy) h=3 ;;
      *) h=0 ;;
    esac

    echo "docker_container_up{host=\"$HOSTNAME_SHORT\",container=\"$name_clean\",image=\"$image\"} $up"
    echo "docker_container_restart_count{host=\"$HOSTNAME_SHORT\",container=\"$name_clean\",image=\"$image\"} $restart_count"
    echo "docker_container_health_status{host=\"$HOSTNAME_SHORT\",container=\"$name_clean\",image=\"$image\"} $h"
  done
} > "$TMPFILE" && mv "$TMPFILE" "$OUTFILE"
