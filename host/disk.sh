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
# NTFY_MARKDOWN is GONE (2026-08-21). It was set to `no` here because the body was
# machine-built from `df` and `zpool list` and nothing in it was authored as Markdown,
# so rendering it could only surprise. body_fact() escapes every line it renders, which
# is what made the opt-out unnecessary — escaping in one place is what makes rendering
# safe everywhere.
# shellcheck disable=SC2034  # read by ntfy.lib.sh, sourced below
NTFY_TOPIC="disk"

# A STABLE SEQUENCE ID, so a condition that persists is ONE message that keeps being
# replaced rather than a pile. This job runs HOURLY and alerts on every run while over threshold, so a pool sitting
# at 78% across a weekend used to produce forty-five notifications.
#
# It does NOT self-clear when the condition goes away. A fault has no buttons, and a
# notification without buttons is never withdrawn by the system: an absent message is
# ambiguous — fixed, mis-swiped, or never sent — and a stale one is not. See
# ntfy/MESSAGES.md.
#
# ONE ID PER FILESYSTEM, because they are different subjects with different remedies:
# root filling up and the pool filling up have nothing to do with each other, and a
# shared id would mean whichever crossed second silently replaced the first.
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

# ONE NOTIFICATION PER FILESYSTEM OVER THRESHOLD, not one summary for both.
#
# The old shape had a `Filesystems: 2 Full` fallback title above a body of two
# comma-joined runs, and it fails the body language two ways: a count title stands in
# for two different subjects, and metrics get their own line rather than a run. Both
# are the liquidroom decision restated — a run where two things happened cannot
# honestly wear one subject. Split, each keeps its real title (`zpool: 78% Full`), its
# own facts, and its own stable id, so neither replaces the other and neither stacks.
#
# Facts carry no stub label and must read as complete statements: `▪ 400G free`, never
# `▪ Free: 400G` and never `▪ about 400G`. See ntfy/MESSAGES.md § 3.
ALERTS=()   # "name<TAB>pct<TAB>body"

if [ "$ROOT_USAGE" -ge "$ROOT_THRESHOLD" ]; then
    ROOT_DIFF=$((ROOT_USAGE - ROOT_THRESHOLD))
    ALERTS+=("root"$'\t'"$ROOT_USAGE"$'\t'"$(body_fact \
        "${ROOT_USED} of ${ROOT_SIZE} used" \
        "${ROOT_AVAIL} free" \
        "${ROOT_DIFF}% over the ${ROOT_THRESHOLD}% threshold")")
fi

if [ "$ZPOOL_USAGE" -ge "$ZPOOL_THRESHOLD" ]; then
    ZPOOL_DIFF=$((ZPOOL_USAGE - ZPOOL_THRESHOLD))
    ALERTS+=("zpool"$'\t'"$ZPOOL_USAGE"$'\t'"$(body_fact \
        "${ZPOOL_ALLOC} of ${ZPOOL_SIZE} used" \
        "${ZPOOL_FREE} free" \
        "${ZPOOL_DIFF}% over the ${ZPOOL_THRESHOLD}% threshold")")
fi

# Only publish (and log anything) if something crossed.
FAILED=0
for entry in "${ALERTS[@]:-}"; do
    [[ -n "$entry" ]] || continue
    name="${entry%%$'\t'*}"
    rest="${entry#*$'\t'}"
    pct="${rest%%$'\t'*}"
    body="${rest#*$'\t'}"

    # The journal gets it too, unconditionally and BEFORE the wire. If delivery
    # fails, these lines are the only surviving record of what the alert said.
    printf '%s at %s%%\n%s\n' "$name" "$pct" "$body"

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
    #
    # EVERY alert is attempted before exiting. Bailing on the first failure would mean
    # a down ntfy loses the pool alert because the root alert was queued ahead of it.
    send_out="$(notify_fault "$(title_state "$name" "${pct}% Full")" "$body" "${DISK_NTFY_ID}-${name}" 2>&1)"
    if [[ -n "$send_out" ]]; then
        echo "disk: ntfy publish FAILED, the ${name} alert above was not delivered: ${send_out}" >&2
        FAILED=1
    fi
done
(( FAILED == 0 ))
