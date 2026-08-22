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
        # One SIXTH of the pack data per month, rotating by calendar month so the
        # whole repository is read twice a year. The month number is what makes it
        # rotate: a hardcoded 1/6 would re-read the SAME sixth every month and
        # never touch the other five, which looks like it is working while
        # verifying 17% of the repo forever. The `% 6 + 1` is what folds months
        # 7-12 back onto buckets 1-6; without it they would ask for buckets that
        # do not exist and restic would read ZERO packs and still exit 0.
        #
        # No 10# guard is needed because %-m is already unpadded. A weekly variant
        # keyed on `date +%V` WOULD need one — that pads, and 08/09 are invalid
        # octal, so the check would hard-fail two weeks a year.
        #
        # check always does the full structural pass (indexes, snapshots, trees,
        # every referenced blob), so this supersedes the old quarterly meta check —
        # same verification, monthly instead.
        #
        # THE YEARLY --read-data IS GONE (removed 2026-08-22) and this is why.
        # Bucket membership is `pack[0] % t` on the pack ID — selectPacksByBucket
        # in restic's cmd/restic/cmd_check.go — so it is a pure function of a byte
        # that never changes. Nothing is recomputed between runs and nothing
        # drifts: a completed rotation reads every pack that survived it, which is
        # exactly what a full read promises. The old comment here claimed the
        # opposite and was the sole justification for an 8h30m exclusive lock.
        # n/6 rather than n/12 preserves the two sweeps a year the pair used to
        # give, and halves the worst case a corrupt pack sits unseen: 12mo -> 6mo.
        restic_run "$RESTIC_CAPTURE" \
            -r "${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION}" \
            --retry-lock=30m \
            --verbose check --read-data-subset="$(( ($(date +%-m) - 1) % 6 + 1 ))/6" \
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