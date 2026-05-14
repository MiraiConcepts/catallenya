#!/bin/bash
set -euo pipefail

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

# Dump the upvotes SQLite DB via the online-backup API. VACUUM INTO is run
# inside the upvotes container itself (same Bun-bundled SQLite engine that
# owns the DB), so we don't need sqlite3 on the host. Safe under concurrent
# writes — WAL mode means readers don't block writers. The live /data dir
# is NOT in the restic targets; only this consistent copy under /dump is.
UPVOTES_DUMP_DIR=/zpool/catallenya/upvotes/dump
mkdir -p ${UPVOTES_DUMP_DIR}
if ! docker ps --format '{{.Names}}' | grep -qx upvotes; then
    echo "Upvotes container not running; skipping SQLite backup."
else
    echo "Backing up upvotes SQLite database..."
    # Overwrite any stale dump first — VACUUM INTO refuses to write over an existing file.
    rm -f ${UPVOTES_DUMP_DIR}/votes.db
    docker exec upvotes bun -e '
        const Database = require("bun:sqlite").default;
        const db = new Database("/data/votes.db", { readonly: true });
        db.exec("VACUUM INTO ?", ["/dump/votes.db"]);
        db.close();
    '
    echo "Upvotes SQLite backup complete."
fi

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
