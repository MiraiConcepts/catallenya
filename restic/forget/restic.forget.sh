#!/bin/bash
set -euo pipefail

. /zpool/catallenya/restic/restic.conf

# Clear a stale lock left by a run killed mid-flight — a shutdown SIGTERM, a
# `timeout`, an OOM kill, power loss. restic 0.16.4 only cleans up on SIGINT
# (fixed upstream in 0.17.0, #4703, which noble will never ship), so every other
# death orphans the lock. A LIVE run is never touched: restic refreshes its own
# lock every 5 min and self-aborts at 22.5 min if it cannot, so a running job's
# lock can never reach the 30 min staleness threshold.
restic -r "${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION}" \
    --password-file "${RESTIC_PASSWORD_FILE}" unlock

# Forget and prune stale snapshots in repository. --retry-lock waits out a LIVE
# lock (another job mid-run); the unlock above clears a DEAD one. Different
# cases, neither substitutes for the other.
restic -r "${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION}" \
    --password-file "${RESTIC_PASSWORD_FILE}" \
    --retry-lock=30m \
    --verbose forget --prune \
    --keep-daily "${RESTIC_NUMBER_DAILY_TO_KEEP}" \
    --keep-weekly "${RESTIC_NUMBER_WEEKLY_TO_KEEP}" \
    --keep-monthly "${RESTIC_NUMBER_MONTHLY_TO_KEEP}" \
    --keep-yearly "${RESTIC_NUMBER_YEARLY_TO_KEEP}"