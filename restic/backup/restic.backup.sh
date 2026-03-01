#!/bin/bash
set -eo pipefail

. /zpool/catallenya/restic/restic.conf

# Dump Memoka's PostgreSQL database to a compressed SQL file before restic runs.
# Raw postgres data dirs (memoka/postgres, memoka/redis) are excluded from restic
# since copying live PG files is unsafe. This dump is the authoritative DB backup.
MEMOKA_BACKUP_DIR=/zpool/catallenya/memoka/backup
mkdir -p ${MEMOKA_BACKUP_DIR}
echo "Dumping Memoka database..."
docker exec memoka_postgresql pg_dump -U memoka_user memoka \
    | gzip > ${MEMOKA_BACKUP_DIR}/memoka.dump.sql.gz
echo "Memoka database dump complete."

# Build --exclude flags — one per path (restic requires a separate flag each time).
EXCLUDES=""
for target in ${RESTIC_EXCLUDE_TARGETS}; do
    EXCLUDES="$EXCLUDES --exclude $target"
done
echo "Exclude targets: ${RESTIC_EXCLUDE_TARGETS}"

# Backup target folders to repository.
restic -r ${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION} \
    ${EXCLUDES} \
    --verbose backup ${RESTIC_BACKUP_TARGETS} \
    --password-file ${RESTIC_PASSWORD_FILE}
