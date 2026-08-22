#!/bin/bash
set -euo pipefail

. /zpool/catallenya/restic/restic.conf
# shellcheck source=/zpool/catallenya/restic/restic.lib.sh
. /zpool/catallenya/restic/restic.lib.sh

# See restic.lib.sh. --verbose check prints a line per structural pass and, with
# --read-data, a progress bar per pack batch.
RESTIC_CAPTURE="$(mktemp)"
trap 'rm -f "$RESTIC_CAPTURE"' EXIT

check_type="$1"

# Clear a stale lock left by a run killed mid-flight — SIGKILL, an OOM kill,
# power loss. restic >=0.17.0 releases on SIGINT and SIGTERM (#4703), so the
# 2026-08-07 `timeout` case that orphaned an exclusive lock is fixed by the
# 0.19.1 upgrade; the ways a process dies WITHOUT a signal it can handle are
# not, and this host has no UPS. A LIVE run is never touched: restic refreshes its own
# lock every 5 min and self-aborts at 22.5 min if it cannot, so a running job's
# lock can never reach the 30 min staleness threshold.
restic -r "${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION}" \
    --password-file "${RESTIC_PASSWORD_FILE}" unlock

# --retry-lock waits out a LIVE lock (another job mid-run); the unlock above
# clears a DEAD one. Different cases, neither substitutes for the other.
case "$check_type" in
    meta)
        restic_run "$RESTIC_CAPTURE" \
            -r "${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION}" \
            --retry-lock=30m \
            --verbose check \
            --password-file "${RESTIC_PASSWORD_FILE}"
        ;;
    data)
        restic_run "$RESTIC_CAPTURE" \
            -r "${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION}" \
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
        restic_run "$RESTIC_CAPTURE" \
            -r "${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION}" \
            --retry-lock=30m \
            --verbose check --read-data-subset="$(date +%-m)/12" \
            --password-file "${RESTIC_PASSWORD_FILE}"
        ;;
    *)
        echo "Unknown check type: $check_type" >&2
        exit 1
        ;;
esac

# --- the receipt ------------------------------------------------------------
# `check` is the one job whose ANSWER is a single sentence, so the receipt says it
# plainly and names which pass ran — `Check: Succeeded` alone cannot distinguish the
# monthly twelfth from the yearly full read.
_clean="$(first_match "$RESTIC_CAPTURE" 's/^(no errors were found)$/\1/p')"
_subset="$(first_match "$RESTIC_CAPTURE" 's/.*read ([0-9]+\/[0-9]+) of the (repository )?data.*/\1/p')"

case "$check_type" in
    meta)   fact "Structure checked, no pack data read" ;;
    data)   fact "Full pack data read" ;;
    subset) fact "Pack subset $(date +%-m)/12 read" ;;
esac
[[ -n "$_subset" ]] && fact "restic reports ${_subset} read"
if [[ -n "$_clean" ]]; then
    fact "No errors found"
else
    # check exited 0 without saying so. Not a failure, but not a clean bill either,
    # and a receipt that claimed one would be the exact shape this repo keeps
    # finding: a report that says healthy while looking at nothing.
    fact "Finished, but restic did not report a clean result"
fi
exit 0