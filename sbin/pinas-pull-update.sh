#!/bin/bash
set -euo pipefail

# Compatibility shim to keep legacy cron jobs/webhooks working.
# The new deployment flow uses the Worker/R2 powered pinas-update.sh script.

LOG_FILE="/var/log/pinas-pull-update.log"
UPDATE_BIN="/usr/local/sbin/pinas-update.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

{
  echo "$(timestamp) [INFO] Delegating to pinas-update.sh"
} >>"$LOG_FILE"

if [ ! -x "$UPDATE_BIN" ] && [ -x "$SCRIPT_DIR/pinas-update.sh" ]; then
  UPDATE_BIN="$SCRIPT_DIR/pinas-update.sh"
fi

if [ ! -x "$UPDATE_BIN" ]; then
  echo "ERROR: pinas-update.sh is not available. Reinstall piNAS or copy the script to /usr/local/sbin." | tee -a "$LOG_FILE" >&2
  exit 1
fi

exec "$UPDATE_BIN" "$@"