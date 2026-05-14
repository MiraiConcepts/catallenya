#!/bin/bash
set -euo pipefail

. /zpool/catallenya/restic/restic.conf

# List all snapshots in a repository.
restic -r "${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION}" --verbose snapshots --password-file "${RESTIC_PASSWORD_FILE}"