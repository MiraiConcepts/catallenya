#!/bin/bash
# Exit immediately if a command fails, or if unset variables are used
set -euo pipefail

# Notification transport is shared; this script no longer builds a URL or reads the
# root .env itself. It used to `source` that file wholesale — forty-odd database
# credentials and service tokens, to use three of them, and arbitrary code execution
# if a data file ever grew a $(...) — and then hand-rolled a curl with no --max-time
# and no hdr_safe. ntfy.lib.sh extracts only the three keys the transport needs and
# carries both.
#
# Sourced by ABSOLUTE path: this runs from systemd with no meaningful working
# directory, and User=carrein under the monitor class's ProtectSystem=strict, which
# leaves the whole tree readable and only this job's stamp writable.
#
# NTFY_MARKDOWN=no, the immich opt-out: the body below is machine-built from `df` and
# `zpool list` output, written for a lock screen rather than for a renderer. Nothing
# in it is authored as Markdown, so rendering it could only ever surprise.
# shellcheck disable=SC2034  # both are read by ntfy.lib.sh, sourced below
NTFY_TOPIC="disk"
# shellcheck disable=SC2034
NTFY_MARKDOWN=no

# A STABLE SEQUENCE ID, so a condition that persists is ONE message that keeps being
# replaced rather than a pile. This job runs HOURLY and alerts on every run while over threshold, so a pool sitting
# at 78% across a weekend used to produce forty-five notifications.
#
# It does NOT self-clear when the condition goes away. A fault has no buttons, and a
# notification without buttons is never withdrawn by the system: an absent message is
# ambiguous — fixed, mis-swiped, or never sent — and a stale one is not. See
# ntfy/MESSAGES.md.
DISK_NTFY_ID="disk-full"
# shellcheck source=/zpool/catallenya/ntfy/ntfy.lib.sh
source "/zpool/catallenya/ntfy/ntfy.lib.sh"

ROOT_THRESHOLD=75
ZPOOL_THRESHOLD=75

# Root is ext4/LVM -> df is the right metric. Capture pcent + human-readable used/size/avail.
read -r ROOT_USED ROOT_SIZE ROOT_AVAIL ROOT_PCENT < <(df -h --output=used,size,avail,pcent / | tail -n 1)
ROOT_USAGE=${ROOT_PCENT%\%}

# Zpool is ZFS -> use pool-level capacity. Unlike df, this counts snapshot-held space,
# so the alert reflects TRUE pool fill (df under-reports when snapshots hold space).
read -r ZPOOL_USAGE ZPOOL_SIZE ZPOOL_ALLOC ZPOOL_FREE < <(zpool list -H -o capacity,size,alloc,free zpool)
ZPOOL_USAGE=${ZPOOL_USAGE%\%}

ALERT_MESSAGE=""
# Which filesystems crossed, and how full. The TITLE is built from these rather than
# from a literal: `Disk Space Alert` never said which one or how full, and both facts
# were already sitting in the body you had to open to read them.
#
# The subject may not repeat the topic — this publishes to `disk` — so one filesystem
# over names ITSELF (`zpool`, `root`), and both over fall back to a count, because two
# subjects do not fit one subject slot. `zpool` and `root` are identifiers and keep
# their real case: the pool is literally called `zpool`, and `Zpool` names nothing.
OVER_NAME=(); OVER_PCT=()

if [ "$ROOT_USAGE" -ge "$ROOT_THRESHOLD" ]; then
    ROOT_DIFF=$((ROOT_USAGE - ROOT_THRESHOLD))
    OVER_NAME+=("root"); OVER_PCT+=("$ROOT_USAGE")
    ALERT_MESSAGE="Root partition at ${ROOT_USAGE}% — ${ROOT_USED} used of ${ROOT_SIZE} (${ROOT_AVAIL} free), ${ROOT_DIFF}% over ${ROOT_THRESHOLD}% threshold"
fi

if [ "$ZPOOL_USAGE" -ge "$ZPOOL_THRESHOLD" ]; then
    ZPOOL_DIFF=$((ZPOOL_USAGE - ZPOOL_THRESHOLD))
    OVER_NAME+=("zpool"); OVER_PCT+=("$ZPOOL_USAGE")
    new_line="Zpool at ${ZPOOL_USAGE}% — ${ZPOOL_ALLOC} used of ${ZPOOL_SIZE} (${ZPOOL_FREE} free), ${ZPOOL_DIFF}% over ${ZPOOL_THRESHOLD}% threshold"

    if [ -n "$ALERT_MESSAGE" ]; then
        ALERT_MESSAGE="${ALERT_MESSAGE}"$'\n'"${new_line}"
    else
        ALERT_MESSAGE="${new_line}"
    fi
fi

# Only publish (and log anything) if there is an alert.
if [ -n "$ALERT_MESSAGE" ]; then
    # The journal gets it too, unconditionally and BEFORE the wire. If delivery
    # fails, this line is the only surviving record of what the alert said.
    echo "$ALERT_MESSAGE"

    # A DROPPED ALERT MUST FAIL THIS UNIT.
    #
    # notify() is best-effort BY DESIGN — every path in it ends in `|| true`, because
    # for the intake pipelines a failed notification must never fail work that has
    # already succeeded. This job inverts that: it is silent unless a threshold is
    # crossed, so the notification IS the work. A swallowed publish would leave an
    # hour that looks exactly like a healthy one, and systemd would still run
    # ExecStartPost= and stamp this monitor fresh for the watchdog.
    #
    # The old bare curl carried no -f, so an HTTP error (5xx, a future auth failure)
    # returned 0 and the alert vanished with success recorded; only a connection
    # failure ever failed the unit, and adopting a best-effort transport would have
    # lost even that. So the transport's own silence is the test: curl -fsS prints
    # nothing on a successful publish and prints the failure otherwise, and _ntfy_env
    # logs when it declines. Anything the transport says is an undelivered alert.
    #
    # Failing exits non-zero, which is three things at once: no completion stamp, so
    # the watchdog reports this monitor stale within its 3h MaxAge; the inherited
    # OnFailure= fires; and `systemctl --failed` shows it. The first is what survives
    # an ntfy that is itself down.
    if (( ${#OVER_NAME[@]} == 1 )); then
        DISK_TITLE="$(title_state "${OVER_NAME[0]}" "${OVER_PCT[0]}% Full")"
    else
        DISK_TITLE="$(title_state Filesystems "${#OVER_NAME[@]} Full")"
    fi
    send_out="$(notify_fault "$DISK_TITLE" "$ALERT_MESSAGE" "$DISK_NTFY_ID" 2>&1)"
    if [[ -n "$send_out" ]]; then
        echo "disk: ntfy publish FAILED, the alert above was not delivered: ${send_out}" >&2
        exit 1
    fi
fi
