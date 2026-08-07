#!/bin/bash
set -euo pipefail

# Source root .env
ROOT_ENV="/zpool/catallenya/.env"
if [[ -f "$ROOT_ENV" ]]; then
    # shellcheck source=/dev/null  # runtime-only file, not in the repo
    source "$ROOT_ENV"
else
    echo "Root .env not found at $ROOT_ENV"
    exit 1
fi

# Interpolate NTFY_URL after sourcing
NTFY_URL="https://${TAILNET_DOMAIN}.${TAILNET_DNS_NAME}:${NTFY_REVERSE_PROXY_PORT}"

service_name="$1"

# Split "<topic>.<job>" — the unit naming convention already carries the topic, so
# restic.backup -> restic/Backup, capture.triage -> capture/Triage. This used to
# match restic and nothing else, while FOUR units wired OnFailure= here through the
# system-ntfy@.service template: capture.{triage,sweep} and documents.{triage,apply}.
# All four hit the else branch and died with "Unknown service type", so their alerts
# were never delivered — silently, because systemd does not report a failed
# OnFailure= handler anywhere. Deriving the topic fixes every one of them at once and
# needs no edit for the next job that follows the convention.
topic="${service_name%%.*}"
job_type="${service_name#*.}"

# The allowlist is the part that must not be dropped for "simplicity". ntfy creates a
# topic on first publish, so a typo'd or unexpected unit name would publish into a
# channel nobody is subscribed to and the alert would vanish with a 200 OK. Refusing
# is the safe failure. Only topics that actually have a unit wired to this template
# belong here — disk/boot publish to ntfy directly from their own scripts and must NOT
# be added just because they are valid topic names. immich does BOTH: its script sends
# the outcome itself, and systemd/immich.fix-rotations.service wires OnFailure= here as
# a backstop for the script dying before it can. That unit is the only thing justifying
# the immich entry below — if it ever loses its OnFailure=, drop the entry too.
case "$topic" in
    restic|capture|documents|immich) ;;
    *)
        echo "Unknown service type: $service_name"
        exit 1
        ;;
esac

# A unit named with no dot at all would leave topic == job_type and pass the case above
# only if it were literally one of the allowlisted names. Reject it anyway: the title
# would be nonsense and it means the caller broke the convention.
if [[ "$service_name" != *.* ]]; then
    echo "Service name is not <topic>.<job>: $service_name"
    exit 1
fi

# Handle special cases
if [[ "$job_type" == "check@meta" ]]; then
    job_type="Check Metadata"
elif [[ "$job_type" == "check@data" ]]; then
    job_type="Check Data"
elif [[ "$job_type" == "check@subset" ]]; then
    job_type="Check Data Subset"
elif [[ "$job_type" == "fix-rotations" ]]; then
    # Plain capitalisation gives "Fix-rotations Failure". Match the unit's own
    # Description instead, for the same reason check@meta is spelled out.
    job_type="Rotation Bake"
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
message=$(systemctl status "${service_name}.service" || true)

curl -H "Tags: $tag" \
     -H "Title: $title" \
     -H "Priority: $priority" \
     -d "$message" \
     "${NTFY_URL}/${topic}"