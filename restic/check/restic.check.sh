#!/bin/bash
set -euo pipefail

. /zpool/catallenya/restic/restic.conf

check_type="$1"

# Clear a stale lock left by a run killed mid-flight — a shutdown SIGTERM, a
# `timeout`, an OOM kill, power loss. restic 0.16.4 only cleans up on SIGINT
# (fixed upstream in 0.17.0, #4703, which noble will never ship), so every other
# death orphans the lock. A LIVE run is never touched: restic refreshes its own
# lock every 5 min and self-aborts at 22.5 min if it cannot, so a running job's
# lock can never reach the 30 min staleness threshold.
restic -r "${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION}" \
    --password-file "${RESTIC_PASSWORD_FILE}" unlock

# --retry-lock waits out a LIVE lock (another job mid-run); the unlock above
# clears a DEAD one. Different cases, neither substitutes for the other.
case "$check_type" in
    meta)
        restic -r "${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION}" \
            --retry-lock=30m \
            --verbose check \
            --password-file "${RESTIC_PASSWORD_FILE}"
        ;;
    data)
        restic -r "${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION}" \
            --retry-lock=30m \
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
            --retry-lock=30m \
            --verbose check --read-data-subset="$(date +%-m)/12" \
            --password-file "${RESTIC_PASSWORD_FILE}"
        ;;
    *)
        echo "Unknown check type: $check_type" >&2
        exit 1
        ;;
esac