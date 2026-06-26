#!/bin/bash
# Exit immediately if a command fails, or if unset variables are used
set -euo pipefail

# Source root .env
ROOT_ENV="/zpool/catallenya/.env"
if [[ -f "$ROOT_ENV" ]]; then
    source "$ROOT_ENV"
else
    echo "Root .env not found at $ROOT_ENV"
    exit 1
fi

# Interpolate NTFY_URL after sourcing
NTFY_URL="https://${TAILNET_DOMAIN}.${TAILNET_DNS_NAME}:${NTFY_REVERSE_PROXY_PORT}"

ROOT_THRESHOLD=75
ZPOOL_THRESHOLD=75
TOPIC="disk"

# Root is ext4/LVM -> df is the right metric. Capture pcent + human-readable used/size/avail.
read -r ROOT_USED ROOT_SIZE ROOT_AVAIL ROOT_PCENT < <(df -h --output=used,size,avail,pcent / | tail -n 1)
ROOT_USAGE=${ROOT_PCENT%\%}

# Zpool is ZFS -> use pool-level capacity. Unlike df, this counts snapshot-held space,
# so the alert reflects TRUE pool fill (df under-reports when snapshots hold space).
read -r ZPOOL_USAGE ZPOOL_SIZE ZPOOL_ALLOC ZPOOL_FREE < <(zpool list -H -o capacity,size,alloc,free zpool)
ZPOOL_USAGE=${ZPOOL_USAGE%\%}

ALERT_MESSAGE=""

if [ "$ROOT_USAGE" -ge "$ROOT_THRESHOLD" ]; then
    ROOT_DIFF=$((ROOT_USAGE - ROOT_THRESHOLD))
    ALERT_MESSAGE="Root partition at ${ROOT_USAGE}% — ${ROOT_USED} used of ${ROOT_SIZE} (${ROOT_AVAIL} free), ${ROOT_DIFF}% over ${ROOT_THRESHOLD}% threshold"
fi

if [ "$ZPOOL_USAGE" -ge "$ZPOOL_THRESHOLD" ]; then
    ZPOOL_DIFF=$((ZPOOL_USAGE - ZPOOL_THRESHOLD))
    new_line="Zpool at ${ZPOOL_USAGE}% — ${ZPOOL_ALLOC} used of ${ZPOOL_SIZE} (${ZPOOL_FREE} free), ${ZPOOL_DIFF}% over ${ZPOOL_THRESHOLD}% threshold"

    if [ -n "$ALERT_MESSAGE" ]; then
        ALERT_MESSAGE="${ALERT_MESSAGE}"$'\n'"${new_line}"
    else
        ALERT_MESSAGE="${new_line}"
    fi
fi

# Only run curl (and log anything) if there is an alert
if [ -n "$ALERT_MESSAGE" ]; then
    curl -H "Tags: warning" \
         -H "Title: Disk Space Alert" \
         -H "Priority: high" \
         -d "$ALERT_MESSAGE" \
         "${NTFY_URL}/${TOPIC}"
fi
