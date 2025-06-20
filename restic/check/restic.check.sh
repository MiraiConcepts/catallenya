#!/bin/bash

. /zpool/catallenya/restic/restic.conf

# Verify integrity of repository.
restic -r ${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION} --verbose check --read-data --password-file ${RESTIC_PASSWORD_FILE}