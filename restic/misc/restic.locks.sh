#!/bin/bash
set -euo pipefail

. /zpool/catallenya/restic/restic.conf

# List all locks in a repository.
restic -r "${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION}" --verbose list locks --password-file "${RESTIC_PASSWORD_FILE}"
