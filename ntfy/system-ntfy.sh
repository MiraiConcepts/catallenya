#!/bin/bash

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

service_name="$1"

# Extract job type from service name - only handle restic now
if [[ "$service_name" =~ restic\.(.*) ]]; then
    job_type="${BASH_REMATCH[1]}"
    topic="restic"
else
    echo "Unknown service type: $service_name"
    exit 1
fi

# Handle special cases
if [[ "$job_type" == "check@meta" ]]; then
    job_type="Check Metadata"
elif [[ "$job_type" == "check@data" ]]; then
    job_type="Check Data"
else
    # Capitalize first letter for other jobs
    job_type="$(tr '[:lower:]' '[:upper:]' <<< ${job_type:0:1})${job_type:1}"
fi

if systemctl is-failed --quiet "${service_name}.service"; then
    tag="mending_heart"
    title="${job_type} Failure"
    priority="high"
else
    tag="green_heart"
    title="${job_type} Success"
    priority="default"
fi

# Get systemctl status output
message=$(systemctl status "${service_name}.service")

curl -H "Tags: $tag" \
     -H "Title: $title" \
     -H "Priority: $priority" \
     -d "$message" \
     "${NTFY_URL}/${topic}"