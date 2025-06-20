#!/bin/bash

. /zpool/catallenya/restic/restic.conf

# List all snapshots in a reposiory.
restic -r ${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION} --verbose snapshots --password-file ${RESTIC_PASSWORD_FILE}