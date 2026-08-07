#!/bin/bash
set -euo pipefail

. /zpool/catallenya/restic/restic.conf

# Alert when the newest snapshot is older than this. OnFailure= on the backup unit
# only fires when a run FAILS — a run that never STARTS fails nothing, so a disabled
# timer, a unit missing after a rebuild, or a box that sat powered off is completely
# silent. 48h leaves room for one missed nightly before shouting.
MAX_AGE_HOURS=48

REPO="${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION}"

# Ask the repository, not systemd. A backup that exits 0 having written nothing looks
# healthy to systemd and is caught here; this also proves the whole path still works
# (credentials, network, bucket, repo readable), which no local check can.
#
# --no-lock: a read-only age query must never queue behind, or fight with, a running
# backup. It also means a stale exclusive lock cannot mute the alarm at the one moment
# it most needs to fire.
#
# max_by over ALL snapshots, deliberately — not `--latest 1` with `.[0]`. `--latest` is
# per GROUP, and forget's default --group-by host,paths means this repo has 18 groups
# (one per historical RESTIC_BACKUP_TARGETS edit), so --latest 1 returns 18 snapshots
# and .[0] is the oldest group's newest. That reported the repo as 17186h stale while
# backups were running fine every night.
latest="$(restic -r "${REPO}" --password-file "${RESTIC_PASSWORD_FILE}" \
    --no-lock snapshots --json | jq -r 'max_by(.time).time // empty')"

if [[ -z "${latest}" ]]; then
    echo "No snapshots found in ${RESTIC_BACKUP_LOCATION}." >&2
    exit 1
fi

age_hours=$(( ( $(date +%s) - $(date -d "${latest}" +%s) ) / 3600 ))

if (( age_hours > MAX_AGE_HOURS )); then
    echo "Newest snapshot is ${age_hours}h old, over the ${MAX_AGE_HOURS}h limit (${latest})." >&2
    exit 1
fi

echo "Newest snapshot is ${age_hours}h old, within the ${MAX_AGE_HOURS}h limit (${latest})."
