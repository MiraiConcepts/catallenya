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

# Safer way to get percentage: --output=pcent grabs just the percent column
# 'tail' gets the last line (the value), and 'tr' removes the % sign
ROOT_USAGE=$(df --output=pcent / | tail -n 1 | tr -d ' %')
ZPOOL_USAGE=$(df --output=pcent /zpool | tail -n 1 | tr -d ' %')

ALERT_MESSAGE=""

if [ "$ROOT_USAGE" -ge "$ROOT_THRESHOLD" ]; then
    # Calculate the difference
    ROOT_DIFF=$((ROOT_USAGE - ROOT_THRESHOLD))
    # Build the new message format
    ALERT_MESSAGE="Root partition usage is ${ROOT_DIFF}% above ${ROOT_THRESHOLD}% threshold (at ${ROOT_USAGE}%)"
fi

if [ "$ZPOOL_USAGE" -ge "$ZPOOL_THRESHOLD" ]; then
    # Calculate the difference
    ZPOOL_DIFF=$((ZPOOL_USAGE - ZPOOL_THRESHOLD))
    # Define the new message line
    new_line="Zpool partition usage is ${ZPOOL_DIFF}% above ${ZPOOL_THRESHOLD}% threshold (at ${ZPOOL_USAGE}%)"
    
    if [ -n "$ALERT_MESSAGE" ]; then
        # Use a proper newline character \n to append
        ALERT_MESSAGE="${ALERT_MESSAGE}"$'\n'"${new_line}"
    else
        # Or set it as the first message
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