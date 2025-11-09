#!/bin/bash

. /zpool/catallenya/restic/restic.conf

check_type="$1"

case "$check_type" in
    meta)
        restic -r ${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION} \
            --verbose check \
            --password-file ${RESTIC_PASSWORD_FILE}
        ;;
    data)
        restic -r ${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION} \
            --verbose check --read-data \
            --password-file ${RESTIC_PASSWORD_FILE}
        ;;
    *)
        echo "Unknown check type: $check_type" >&2
        exit 1
        ;;
esac