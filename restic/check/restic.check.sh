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
    subset)
        # One twelfth of the pack data per month, rotating by calendar month so a
        # year covers the whole repository. The month number is what makes it
        # rotate: a hardcoded 1/12 would re-read the SAME twelfth every month and
        # never touch the other eleven, which looks like it is working while
        # verifying 8% of the repo forever.
        #
        # check always does the full structural pass (indexes, snapshots, trees,
        # every referenced blob), so this supersedes the old quarterly meta check —
        # same verification, monthly instead. The yearly --read-data stays: it is
        # the only thing that closes the gap where n/12 is recomputed each month
        # against a pack set that keeps changing.
        restic -r "${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION}" \
            --verbose check --read-data-subset="$(date +%-m)/12" \
            --password-file "${RESTIC_PASSWORD_FILE}"
        ;;
    *)
        echo "Unknown check type: $check_type" >&2
        exit 1
        ;;
esac