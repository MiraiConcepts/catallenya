#!/bin/bash
set -euo pipefail

# The alarm of last resort. Every OnFailure= in the fleet points here, so this script
# deliberately DOES NOT source ntfy/ntfy.lib.sh — owner's call, and the reason is the
# position rather than the code: the one job whose whole purpose is to speak when
# something else has broken should depend on as little as possible, including on
# another file in this repo being intact. It is the only publisher in the tree with
# that exemption. The cost is that the two lines of curl below have to keep pace with
# the transport by hand; the flags carry the reasons inline for that.

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
# restic.backup -> restic/Backup, afterimage.triage -> afterimage/Triage. This used to
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
    # Adopted units fail the fragment test yet are ours: catallenya.service is
    # written to /etc (it must load before ZFS mounts), and the sanoid pair are
    # vendor fragments under /usr whose only catallenya-ness is the sticker
    # drop-in install.sh gives them. What marks a unit as ours everywhere else
    # is that merged Class= — so ask the same question the watchdog asks,
    # rather than keeping a name list here: the last hand-maintained list in
    # this script silently ate four units' alerts. A foreign or typo'd unit has
    # no sticker and is still refused. Same awk as the watchdog's sticker():
    # section-aware, last match wins.
    class=$(systemctl cat "${service_name}.service" 2>/dev/null | awk '
        /^\[/  { inside = ($0 == "[X-Catallenya]"); next }
        inside && index($0, "Class=") == 1 { v = substr($0, 7) }
        END { if (v != "") print v }')
    if [[ -z "$class" ]]; then
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
# Renamed from `boot` on 2026-08-13 after the phone was subscribed and a test
# publish confirmed, never before — an unsubscribed topic accepts a publish with a
# 200 OK and discards it.
HOST_TOPIC="host"
SUBSCRIBED="restic afterimage pigeonhole immich changedetection disk zpool liquidroom ${HOST_TOPIC}"

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

# THE ONE PLACE IN THE REPO THAT BUILDS A TITLE BY HAND.
#
# ntfy/kinds.sh has title_state() for exactly this shape and this file deliberately
# does not use it — for the same reason it does not source ntfy/ntfy.lib.sh. This is
# the alarm of last resort that every OnFailure= points at, and it must depend on as
# little as possible, including on another file in this repo being intact. The cost of
# that exemption is that the grammar has to be kept in step by hand, so:
#
#   <Subject>: <State>[ [rerouted-topic]]      e.g. "Backup: Failed [restic]"
#
# systemd/contract.sh checks this file by PATTERN rather than by constructor. See
# ntfy/MESSAGES.md § 5, nuance 12.
#
# THE SUCCESS BRANCH IS NOT DEAD CODE AND MUST NOT BE DELETED. Three units wire
# OnSuccess= here — restic.backup, restic.forget and restic.check@ — and those pings
# are the ONLY positive evidence that this path still reaches the phone. Nothing
# watches the courier: it inherits no OnFailure= (that would call the courier to
# complain about the courier) and carries no [X-Catallenya] Class, so the watchdog
# skips it too. Only the DAILY backup ping is frequent enough to serve as that canary;
# weekly, monthly and yearly are not. See ntfy/MESSAGES.md § 5, nuance 13.
# NO TAG AND NO PRIORITY, matching the shared transport by hand — which is the price
# of this file's exemption from it. Both were dropped repo-wide on 2026-08-20: priority
# had one legal value, and tags were twelve glyphs of which four meant "something is
# wrong". The title says which this is.
if systemctl is-failed --quiet "${service_name}.service"; then
    title="${job_type}: Failed${routed_note}"
else
    title="${job_type}: Succeeded${routed_note}"
fi

# Get systemctl status output
message=$(systemctl status "${service_name}.service" || true)

# Same guard the intake libs and the heartbeat carry, placed immediately before
# the curl so everything up to the wire — ownership, topic routing, title and
# status derivation — is exercised by the offline suite without pinging the phone.
if [[ "${NTFY_DISABLE:-}" == "1" ]]; then
    echo "system-ntfy: NTFY_DISABLE=1, not publishing (${title} -> ${topic})"
    exit 0
fi

# -f: an HTTP-level error (5xx, a future auth failure) must exit non-zero, not
# swallow the alert with a 200-shaped success. systemd still reports a failed
# OnFailure= handler nowhere, but a failed courier at least shows in
# `systemctl --failed` instead of nowhere at all.
#
# --max-time: this runs as a FAILURE HANDLER, and an ntfy that accepts the connection
# and then stops answering would hold the handler open indefinitely — a systemd job
# stuck reporting a job that is already dead. TimeoutStartSec=2min on the unit is the
# outer bound; 15s is the same one the shared transport uses, chosen so three of these
# firing at once still finish inside it.
#
# --data-raw, never -d: curl reads a -d value beginning with "@" as a FILENAME and
# POSTs that file's contents. The body here is `systemctl status` output, which starts
# with a bullet today — but it is a machine-built string this script does not control,
# and the one difference between the two flags is that --data-raw can never be talked
# into reading a file.
curl -f --max-time 15 \
     -H "Title: $title" \
     --data-raw "$message" \
     "${NTFY_URL}/${topic}"