#!/bin/bash

. /zpool/catallenya-sev/restic/restic.conf

# Unlock a reposiory.
restic -r ${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION} --verbose unlock --password-file ${RESTIC_PASSWORD_FILE}