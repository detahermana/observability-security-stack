#!/bin/bash
# Monitor Proxmox Backup Server (PBS) backup status and expose the result
# as Prometheus metrics via the node_exporter textfile collector.
#
# Runs on pve2 (192.0.2.3) as root via a systemd timer.
# Output is written to /var/lib/node_exporter/textfile_collector/pbs_backup.prom
# and scraped by Prometheus through the "site-node-exporter" job (.3:9100)
# after node_exporter is restarted with the --collector.textfile.directory flag.
#
# Why the PBS API, not parsing the vzdump log:
#   - The PBS API is the source of truth (the snapshots actually stored),
#     whereas the vzdump log can be lost to log rotation or when a task fails
#     before writing the log.
#   - The API also gives the datastore size, so capacity can be warned about
#     before it fills, not after a backup fails.
#
# Auth: a read-only API token "monitoring@pbs!pve2" (DatastoreAudit role only,
# it CANNOT write or delete backups). The token is read from
# /etc/pbs-monitor.env (mode 600, root) so it does not appear in `ps` or the
# process list.
#
# Metrics produced:
#   pbs_backup_last_success_timestamp  epoch seconds of the last successful backup (0 = none yet)
#   pbs_backup_last_duration_seconds   duration of the last backup (seconds)
#   pbs_backup_last_size_bytes         total size of the last backup (bytes)
#   pbs_backup_snapshot_count          snapshots stored in the datastore
#   pbs_backup_vm_snapshot_count{...}  snapshots per VM (detect a missed VM)
#   pbs_backup_vm_last_timestamp{...}  epoch of the last snapshot per VM
#   pbs_datastore_size_bytes           total datastore capacity
#   pbs_datastore_used_bytes           used capacity
#   pbs_datastore_avail_bytes          free capacity
#   pbs_monitor_up                     whether the script queried PBS successfully (1) or failed (0)
#   pbs_monitor_last_run_timestamp     epoch of the last script run (detect a dead timer)

set -euo pipefail

ENV_FILE="/etc/pbs-monitor.env"
OUTDIR="/var/lib/node_exporter/textfile_collector"
OUTFILE="$OUTDIR/pbs_backup.prom"
TMPFILE="$OUTFILE.tmp"
API_BASE="https://192.0.2.4:8007/api2/json"
DATASTORE="site-backup"
HOSTNAME_SHORT=$(hostname -s)

# ---- Helper: query the PBS API, return the JSON body ----
pbs_api() {
  local path="$1"
  curl -sk -m 20 \
    -H "Authorization: PBSAPIToken=${PBS_TOKEN_ID}:${PBS_TOKEN_SECRET}" \
    "${API_BASE}${path}" 2>/dev/null
}

# ---- Helper: parse JSON with python3 (available on PBS/Debian) ----
# Used to compute aggregates (snapshot counts, latest timestamp) because bash
# has no built-in JSON parser.
json_extract() {
  local mode="$1"
  python3 -c "
import json, sys
mode = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    print('ERROR')
    sys.exit(0)
data = d.get('data')
if data is None:
    print('ERROR')
    sys.exit(0)

if mode == 'status':
    print(int(data.get('total', 0)), int(data.get('used', 0)), int(data.get('avail', 0)))
elif mode == 'snapshots':
    # Aggregate every vm/ct backup snapshot in the datastore
    snaps = [s for s in data if isinstance(s, dict)]
    if not snaps:
        print('COUNT=0')
        sys.exit(0)
    # last backup timestamp = max backup-time
    times = [int(s.get('backup-time', 0)) for s in snaps]
    # last duration
    durs = [int(s.get('duration', 0)) for s in snaps]
    # total size of the last snapshot (all file types combined)
    files = [len(s.get('files', [])) for s in snaps]
    last_time = max(times) if times else 0
    # find the snapshot with the max time for duration + size
    last = max(snaps, key=lambda s: int(s.get('backup-time', 0))) if snaps else {}
    last_dur = int(last.get('duration', 0))
    # size: sum the size of all files in the last snapshot
    size = 0
    for f in last.get('files', []):
        try:
            size += int(f.get('size', 0))
        except Exception:
            pass
    # per-VM aggregate
    per_vm = {}
    for s in snaps:
        key = '%s/%s' % (s.get('backup-type', '?'), s.get('backup-id', '?'))
        t = int(s.get('backup-time', 0))
        if key not in per_vm:
            per_vm[key] = {'count': 0, 'last': 0}
        per_vm[key]['count'] += 1
        if t > per_vm[key]['last']:
            per_vm[key]['last'] = t
    print('COUNT=%d' % len(snaps))
    print('LAST_TIME=%d' % last_time)
    print('LAST_DURATION=%d' % last_dur)
    print('LAST_SIZE=%d' % size)
    for k, v in sorted(per_vm.items()):
        print('VM=%s:%d:%d' % (k, v['count'], v['last']))
" "$mode" 2>/dev/null || echo "ERROR"
}

# ---- Read the token ----
if [ ! -r "$ENV_FILE" ]; then
  echo "FATAL: $ENV_FILE is not readable" >&2
  PBS_TOKEN_ID=""
  PBS_TOKEN_SECRET=""
else
  # shellcheck disable=SC1090
  . "$ENV_FILE"
fi

NOW=$(date +%s)
MONITOR_UP=0
BACKUP_LAST_TIME=0
BACKUP_LAST_DURATION=0
BACKUP_LAST_SIZE=0
SNAPSHOT_COUNT=0
DS_TOTAL=0
DS_USED=0
DS_AVAIL=0
VM_LINES=""

# ---- Query datastore status ----
if [ -n "${PBS_TOKEN_ID:-}" ] && [ -n "${PBS_TOKEN_SECRET:-}" ]; then
  STATUS_JSON=$(pbs_api "/admin/datastore/${DATASTORE}/status" || true)
  if [ -n "$STATUS_JSON" ]; then
    read -r DS_TOTAL DS_USED DS_AVAIL <<< "$(echo "$STATUS_JSON" | json_extract status)"
    if [ "${DS_TOTAL:-0}" -gt 0 ]; then
      MONITOR_UP=1
    fi
  fi

  SNAP_JSON=$(pbs_api "/admin/datastore/${DATASTORE}/snapshots" || true)
  if [ -n "$SNAP_JSON" ]; then
    PARSED=$(echo "$SNAP_JSON" | json_extract snapshots)
    if [ "$PARSED" != "ERROR" ]; then
      MONITOR_UP=1
      while IFS= read -r line; do
        case "$line" in
          COUNT=*)         SNAPSHOT_COUNT="${line#COUNT=}" ;;
          LAST_TIME=*)     BACKUP_LAST_TIME="${line#LAST_TIME=}" ;;
          LAST_DURATION=*) BACKUP_LAST_DURATION="${line#LAST_DURATION=}" ;;
          LAST_SIZE=*)     BACKUP_LAST_SIZE="${line#LAST_SIZE=}" ;;
          VM=*)            VM_LINES="${VM_LINES}${line#VM=}"$'\n' ;;
        esac
      done <<< "$PARSED"
    fi
  fi
fi

# ---- Write metrics (atomic: write to .tmp then rename) ----
{
  echo "# HELP pbs_monitor_up Whether the monitoring script queried the PBS API successfully (1=yes, 0=failed)"
  echo "# TYPE pbs_monitor_up gauge"
  echo "pbs_monitor_up{host=\"$HOSTNAME_SHORT\"} $MONITOR_UP"

  echo "# HELP pbs_monitor_last_run_timestamp Time the monitoring script last ran"
  echo "# TYPE pbs_monitor_last_run_timestamp gauge"
  echo "pbs_monitor_last_run_timestamp{host=\"$HOSTNAME_SHORT\"} $NOW"

  echo "# HELP pbs_backup_last_success_timestamp Time of the last backup stored in PBS (epoch)"
  echo "# TYPE pbs_backup_last_success_timestamp gauge"
  echo "pbs_backup_last_success_timestamp{host=\"$HOSTNAME_SHORT\",datastore=\"$DATASTORE\"} $BACKUP_LAST_TIME"

  echo "# HELP pbs_backup_last_duration_seconds Duration of the last backup (seconds)"
  echo "# TYPE pbs_backup_last_duration_seconds gauge"
  echo "pbs_backup_last_duration_seconds{host=\"$HOSTNAME_SHORT\",datastore=\"$DATASTORE\"} $BACKUP_LAST_DURATION"

  echo "# HELP pbs_backup_last_size_bytes Total size of the last backup files (bytes)"
  echo "# TYPE pbs_backup_last_size_bytes gauge"
  echo "pbs_backup_last_size_bytes{host=\"$HOSTNAME_SHORT\",datastore=\"$DATASTORE\"} $BACKUP_LAST_SIZE"

  echo "# HELP pbs_backup_snapshot_count Snapshots stored in the datastore"
  echo "# TYPE pbs_backup_snapshot_count gauge"
  echo "pbs_backup_snapshot_count{host=\"$HOSTNAME_SHORT\",datastore=\"$DATASTORE\"} $SNAPSHOT_COUNT"

  echo "# HELP pbs_backup_vm_snapshot_count Snapshots stored per VM"
  echo "# TYPE pbs_backup_vm_snapshot_count gauge"
  echo "# HELP pbs_backup_vm_last_timestamp Time of the last snapshot per VM (epoch)"
  echo "# TYPE pbs_backup_vm_last_timestamp gauge"
  if [ -n "$VM_LINES" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      # format: type/id:count:last
      VMKEY="${line%%:*}"
      REST="${line#*:}"
      VCOUNT="${REST%%:*}"
      VLAST="${REST##*:}"
      VTYPE="${VMKEY%%/*}"
      VID="${VMKEY##*/}"
      echo "pbs_backup_vm_snapshot_count{host=\"$HOSTNAME_SHORT\",datastore=\"$DATASTORE\",type=\"$VTYPE\",vmid=\"$VID\"} $VCOUNT"
      echo "pbs_backup_vm_last_timestamp{host=\"$HOSTNAME_SHORT\",datastore=\"$DATASTORE\",type=\"$VTYPE\",vmid=\"$VID\"} $VLAST"
    done <<< "$VM_LINES"
  fi

  echo "# HELP pbs_datastore_size_bytes Total PBS datastore capacity"
  echo "# TYPE pbs_datastore_size_bytes gauge"
  echo "pbs_datastore_size_bytes{host=\"$HOSTNAME_SHORT\",datastore=\"$DATASTORE\"} $DS_TOTAL"

  echo "# HELP pbs_datastore_used_bytes Used PBS datastore capacity"
  echo "# TYPE pbs_datastore_used_bytes gauge"
  echo "pbs_datastore_used_bytes{host=\"$HOSTNAME_SHORT\",datastore=\"$DATASTORE\"} $DS_USED"

  echo "# HELP pbs_datastore_avail_bytes Free PBS datastore capacity"
  echo "# TYPE pbs_datastore_avail_bytes gauge"
  echo "pbs_datastore_avail_bytes{host=\"$HOSTNAME_SHORT\",datastore=\"$DATASTORE\"} $DS_AVAIL"
} > "$TMPFILE" && mv "$TMPFILE" "$OUTFILE"

# Ensure node_exporter can read it
chown node_exporter:node_exporter "$OUTFILE" 2>/dev/null || true
chmod 644 "$OUTFILE"
