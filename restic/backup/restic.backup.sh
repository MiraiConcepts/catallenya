#!/bin/bash
set -euo pipefail

. /zpool/catallenya/restic/restic.conf

# Dump Memoka's PostgreSQL database to a compressed SQL file before restic runs.
# Raw postgres data dirs (memoka/postgres, memoka/redis) are excluded from restic
# since copying live PG files is unsafe. This dump is the authoritative DB backup.
MEMOKA_BACKUP_DIR=/zpool/catallenya/memoka/backup
mkdir -p ${MEMOKA_BACKUP_DIR}
# Guarded the same way the upvotes dump below is. Unguarded, a stopped or
# unhealthy memoka_postgresql made `docker exec` exit non-zero, `set -e` killed
# the script, and NOTHING was backed up that night — Immich, Syncthing and
# Radicale included. One minor container should cost its own dump, not 1.5 TiB.
if ! docker ps --format '{{.Names}}' | grep -qx memoka_postgresql; then
    echo "Memoka postgres container not running; skipping database dump."
else
    echo "Dumping Memoka database..."
    # Write to .tmp and move on success: the old `> …dump.sql.gz` truncated the
    # previous good dump before pg_dump was known to work, so a failure midway
    # left a corrupt archive where a stale-but-valid one had been.
    if docker exec memoka_postgresql pg_dump -U memoka_user memoka \
        | gzip > ${MEMOKA_BACKUP_DIR}/memoka.dump.sql.gz.tmp; then
        mv ${MEMOKA_BACKUP_DIR}/memoka.dump.sql.gz.tmp \
           ${MEMOKA_BACKUP_DIR}/memoka.dump.sql.gz
        echo "Memoka database dump complete."
    else
        rm -f ${MEMOKA_BACKUP_DIR}/memoka.dump.sql.gz.tmp
        echo "Memoka dump FAILED; keeping the previous dump and continuing."
    fi
fi

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

# Clear a stale lock left by a run killed mid-flight — SIGKILL, an OOM kill,
# power loss. restic >=0.17.0 releases on SIGINT and SIGTERM (#4703), so the
# 2026-08-07 `timeout` case that orphaned an exclusive lock is fixed by the
# 0.19.1 upgrade; the ways a process dies WITHOUT a signal it can handle are
# not, and this host has no UPS. A LIVE run is never touched: restic refreshes its own
# lock every 5 min and self-aborts at 22.5 min if it cannot, so a running job's
# lock can never reach the 30 min staleness threshold.
restic -r "${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION}" \
    --password-file "${RESTIC_PASSWORD_FILE}" unlock

# Backup target folders to repository. --retry-lock waits out a LIVE lock (another
# job mid-run); the unlock above clears a DEAD one. Different cases, neither
# substitutes for the other.
restic -r ${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION} \
    ${EXCLUDES} \
    --retry-lock=30m \
    --verbose backup ${RESTIC_BACKUP_TARGETS} \
    --password-file ${RESTIC_PASSWORD_FILE}
