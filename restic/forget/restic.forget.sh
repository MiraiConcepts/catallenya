#!/bin/bash

. /zpool/catallenya/restic/restic.conf

# Forget and prune stale snapshots in repository.
restic -r ${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION} \
    --password-file ${RESTIC_PASSWORD_FILE} \
    --verbose forget --prune \
    --keep-daily ${RESTIC_NUMBER_DAILY_TO_KEEP} \
    --keep-weekly ${RESTIC_NUMBER_WEEKLY_TO_KEEP} \
    --keep-monthly ${RESTIC_NUMBER_MONTHLY_TO_KEEP} \
    --keep-yearly ${RESTIC_NUMBER_YEARLY_TO_KEEP}