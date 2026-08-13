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

# A single-word unit name has no topic to split off, so it is its own. This is not
# a broken caller — catallenya.service is exactly that shape, and since every job
# now inherits OnFailure= from the base policy, the boot orchestrator reaches here
# too. An earlier version rejected these outright.
if [[ "$service_name" != *.* ]]; then
    topic="$service_name"
    job_type="$service_name"
fi

# --- Is this one of ours? ---
#
# This replaces a hand-maintained `case` allowlist of five topic names. That list
# had already eaten alerts once: four units wired OnFailure= here through the
# template and every one hit the else branch and died with "Unknown service type",
# silently, because systemd does not report a failed OnFailure= handler anywhere.
# Fixing the list is a fix that lasts until the next unit; asking the system is a
# fix that lasts.
#
# The question the allowlist was really asking is "did we install this unit", and
# systemd can answer it directly. A typo'd or foreign unit has no fragment under
# the repo and is still refused — which was the point of the list.
fragment=$(systemctl show "${service_name}.service" -p FragmentPath --value 2>/dev/null)
if [[ -z "$fragment" ]] || [[ "$(readlink -f "$fragment" 2>/dev/null)" != /zpool/catallenya/* ]]; then
    # catallenya.service is written to /etc rather than symlinked from the repo —
    # it must load before ZFS mounts — so it is named explicitly rather than
    # discovered.
    if [[ "$service_name" != "catallenya" ]]; then
        echo "Not a catallenya unit, refusing to publish: ${service_name} (fragment: ${fragment:-none})"
        exit 1
    fi
fi

# --- Where does it go? ---
#
# Deriving the topic from the unit name is what makes a new job work with no edit
# here. What cannot be derived is whether a PHONE is subscribed to the result:
# ntfy creates a topic on first publish, so an unsubscribed one accepts the alert
# with a 200 OK and drops it on the floor.
#
# So rather than refuse an unknown topic — which guarantees the alert is lost —
# route it to the host-health channel with its intended topic in the title, which
# guarantees it is delivered. Worst case you get a correctly-labelled alert on the
# wrong-but-watched channel.
#
# This is not hypothetical: catallenya and catallenya.heartbeat both derive the
# topic `catallenya`, which is not subscribed and never will be.
#
# HOST_TOPIC is `boot` until the boot -> host rename lands; both change together,
# after the phone is subscribed, so there is never a window where either points at
# a channel nobody is watching.
HOST_TOPIC="boot"
SUBSCRIBED="restic capture documents immich changedetection disk zpool ${HOST_TOPIC}"

routed_note=""
if [[ " ${SUBSCRIBED} " != *" ${topic} "* ]]; then
    routed_note=" [${topic}]"
    topic="${HOST_TOPIC}"
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
    title="${job_type} Failure${routed_note}"
    priority="high"
else
    tag="green_heart"
    title="${job_type} Success${routed_note}"
    priority="default"
fi

# Get systemctl status output
message=$(systemctl status "${service_name}.service" || true)

curl -H "Tags: $tag" \
     -H "Title: $title" \
     -H "Priority: $priority" \
     -d "$message" \
     "${NTFY_URL}/${topic}"