#!/bin/bash
set -euo pipefail

. /zpool/catallenya/restic/restic.conf

# Restores the latest snapshot in repository to a target folder.
restic -r "${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION}" --verbose restore latest --target "${RESTIC_RESTORE_TARGET}" --password-file "${RESTIC_PASSWORD_FILE}"

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
# Each backup runs sqlite3 .backup against votes.db, writing a consistent copy to
# upvotes/dump/votes.db, which is what restic captures. To restore:
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
