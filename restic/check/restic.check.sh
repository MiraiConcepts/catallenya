#!/bin/bash
set -euo pipefail

. /zpool/catallenya/restic/restic.conf

check_type="$1"

# Clear stale locks left by a backup killed mid-run (e.g. a shutdown SIGTERM)
# before it could release its lock. `unlock` only removes locks whose owner PID
# is dead on this host AND >30min old, so a live concurrent backup is never
# touched. Without this, an orphaned lock silently blocks check's exclusive lock.
restic -r "${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION}" \
    --password-file "${RESTIC_PASSWORD_FILE}" unlock

case "$check_type" in
    meta)
        restic -r "${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION}" \
            --verbose check \
            --password-file "${RESTIC_PASSWORD_FILE}"
        ;;
    data)
        restic -r "${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION}" \
            --verbose check --read-data \
            --password-file "${RESTIC_PASSWORD_FILE}"
        ;;
    *)
        echo "Unknown check type: $check_type" >&2
        exit 1
        ;;
esac