#!/bin/bash
set -euo pipefail

. /zpool/catallenya/restic/restic.conf

# Clear a stale lock left by a run killed mid-flight — SIGKILL, an OOM kill, power
# loss on a host with no UPS. Same pair as backup.sh, check.sh and forget.sh, and for
# the same reason each of them carries it: `unlock` deletes a DEAD lock, --retry-lock
# waits out a LIVE one, and neither substitutes for the other. A LIVE run is never
# collected — restic refreshes its own lock every 5 minutes and self-aborts at 22.5 if
# it cannot, so a running job's lock can never reach the 30-minute staleness threshold.
#
# It matters MOST here, and this script was the one place without it. A restore is what
# you run on the worst day this repository has, and the nightly backup holds a shared
# lock for part of every night: without --retry-lock a restore started in that window
# died at `lock repository` and had to be noticed and re-run by hand, at the one moment
# nobody has attention to spare.
restic -r "${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION}" \
    --password-file "${RESTIC_PASSWORD_FILE}" unlock

# Restores the latest snapshot in repository to a target folder.
#
# RESTIC_RESTORE_TARGET is deliberately OFF the pool (/mnt/restore): a full restore
# measures ~1.55 TiB, which fits on /zpool only by ~210 GiB, trips the 75% disk alert,
# and — being one dataset — is captured by Sanoid, so deleting it reclaims nothing for
# 14 days. Mount external media there, or restore a subset with --include.
restic -r "${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION}" \
    --retry-lock=30m \
    --verbose restore latest --target "${RESTIC_RESTORE_TARGET}" --password-file "${RESTIC_PASSWORD_FILE}"

# --- Memoka database restore ---
# The Memoka PostgreSQL database is not backed up as raw files. Instead, a pg_dump
# is taken before each restic backup and stored at memoka/backup/memoka.dump.sql.gz.
# After restic restores the files, load the dump manually:
#
#   1. Start only the Memoka postgres container (creates a fresh empty DB):
#        docker compose up -d memoka_postgresql
#
#   2. Wait for it to be healthy, then load the dump:
#        gunzip -c ${RESTIC_RESTORE_TARGET}/zpool/catallenya/memoka/backup/memoka.dump.sql.gz \
#            | docker exec -i memoka_postgresql psql -U memoka_user memoka
#
#   3. Start the remaining services:
#        docker compose up -d
#
# --- Upvotes database restore ---
# Live upvotes/data is excluded from restic (WAL writes mid-copy = corruption).
# Each backup runs `VACUUM INTO` inside the upvotes container — the same Bun-bundled
# SQLite engine that owns the database, so the host needs no sqlite3 of its own —
# writing a consistent copy to upvotes/dump/votes.db, which is what restic captures.
# (This comment said `sqlite3 .backup` for as long as the mechanism has been VACUUM
# INTO; backup.sh's own comment is the source of truth for what actually runs.)
# To restore:
#
#   1. Stop upvotes so it doesn't fight us on the file:
#        docker compose stop upvotes
#
#   2. Drop the restored dump into the live data dir, removing stale WAL:
#        cp ${RESTIC_RESTORE_TARGET}/zpool/catallenya/upvotes/dump/votes.db \
#           /zpool/catallenya/upvotes/data/votes.db
#        rm -f /zpool/catallenya/upvotes/data/votes.db-wal \
#              /zpool/catallenya/upvotes/data/votes.db-shm
#
#   3. Start it back up:
#        docker compose up -d upvotes
