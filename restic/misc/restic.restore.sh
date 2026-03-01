#!/bin/bash

. /zpool/catallenya/restic/restic.conf

# Restores the latest snapshot in repository to a target folder.
restic -r ${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION} --verbose restore latest --target ${RESTIC_RESTORE_TARGET} --password-file ${RESTIC_PASSWORD_FILE}

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
