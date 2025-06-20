#!/bin/bash

. /zpool/catallenya/restic/restic.conf

# Unlocks a repository.
restic -r ${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION} --verbose unlock --password-file ${RESTIC_PASSWORD_FILE}