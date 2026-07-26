#!/usr/bin/env bash
# Housekeeping for pending captures. Run hourly by capture.sweep.timer.
#
# The triage only runs when a screenshot arrives, so it cannot manage the life of
# a proposal that is sitting unanswered. This does:
#
#   1. RE-NOTIFY once at RENOTIFY_AFTER_HOURS. "No tap" is genuinely ambiguous —
#      it may mean "I ignored this" or "I never saw it" (phone off, away, ntfy's
#      own 12h message cache expired). One nudge separates the two: if it is still
#      untouched afterwards, "ignored" is a label worth recording.
#   2. ARCHIVE at IGNORE_AFTER_HOURS with outcome "ignored", so the screenshot and
#      the model's proposal are preserved as data rather than deleted.
#
# Makes no API calls — pure filesystem + ntfy, so it costs nothing to run often.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=capture.lib.sh
source "${SELF_DIR}/capture.lib.sh"

mkdir -p "$PENDING_DIR" "$ARCHIVE_DIR"

shopt -s nullglob
records=("$PENDING_DIR"/*/)
(( ${#records[@]} )) || exit 0

now=$(date +%s)
renotified=0 ignored=0

for rec in "${records[@]}"; do
    rec="${rec%/}"
    id="$(basename "$rec")"
    [[ -f "${rec}/proposal.json" ]] || continue   # mid-write by triage; skip

    age_h=$(( (now - $(stat -c %Y "${rec}/proposal.json")) / 3600 ))

    # --- expire ---
    if (( age_h >= IGNORE_AFTER_HOURS )); then
        archive_record "$id" "$rec" ignored "no action within ${age_h}h" \
            && { ignored=$((ignored + 1)); log "ignored ${id:0:8} (${age_h}h)"; }
        continue
    fi

    # --- one nudge ---
    if (( age_h >= RENOTIFY_AFTER_HOURS )) && [[ ! -f "${rec}/renotified" ]]; then
        title="$(jq -r '.title // "Capture"' "${rec}/proposal.json")"
        when="$(jq -r 'if .all_day then .date + " (all day)" else .date + " " + (.start_time // "") end' \
                "${rec}/proposal.json")"
        if base="$(capture_base_url)"; then
            actions="http, Add, ${base}/capture/${id}/add, method=POST, headers.X-Capture=1, clear=true; http, Discard, ${base}/capture/${id}/drop, method=POST, headers.X-Capture=1, clear=true"
            notify "Still waiting: ${title}" default "hourglass,calendar" \
                   "${when} — proposed ${age_h}h ago, no action yet." "$actions"
            : > "${rec}/renotified"
            renotified=$((renotified + 1))
            log "re-notified ${id:0:8} (${age_h}h)"
        fi
    fi
done

(( renotified || ignored )) && log "sweep: ${renotified} re-notified, ${ignored} archived as ignored"
exit 0
