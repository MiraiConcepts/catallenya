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
    send_out="$(notify "Disk Space Alert" "" warning "$ALERT_MESSAGE" 2>&1)"
    if [[ -n "$send_out" ]]; then
        echo "disk: ntfy publish FAILED, the alert above was not delivered: ${send_out}" >&2
        exit 1
    fi
fi
