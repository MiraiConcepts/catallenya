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
#   3. RE-QUEUE a record the triage left behind when the API was unavailable. Such
#      a record has a screenshot but no proposal.json; it is put back in incoming/
#      once so the .path unit re-fires. If it comes back proposal-less a second
#      time, it is archived as failed and the user is told.
#
# Makes no API calls itself — pure filesystem + ntfy, so it costs nothing to run
# often. A re-queue causes the triage to make one, later.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=capture.lib.sh
source "${SELF_DIR}/capture.lib.sh"

# Argument parsing exists mainly so --dry-run is honoured. Every other script in
# this repo takes it, so the muscle memory is that it is safe to try; this one
# used to accept it silently and archive for real anyway.
DRY=0
usage() { printf 'usage: %s [--dry-run]\n' "${0##*/}" >&2; }
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown argument: ${arg}" ;;
    esac
done
(( DRY )) && log "DRY RUN — no records will be re-queued, archived or notified"

mkdir -p "$PENDING_DIR" "$ARCHIVE_DIR" "$IN_DIR"

shopt -s nullglob
records=("$PENDING_DIR"/*/)
(( ${#records[@]} )) || exit 0

now=$(date +%s)
renotified=0 ignored=0 requeued=0 abandoned=0

for rec in "${records[@]}"; do
    rec="${rec%/}"
    id="$(basename "$rec")"

    # --- no proposal: either mid-flight, or the triage gave up on a transient
    # API failure. These used to be skipped forever and accumulated silently.
    if [[ ! -f "${rec}/proposal.json" ]]; then
        # screenshot.* not screenshot.png: the triage names the claimed copy after
        # its real format (Android uploads are JPEG), so matching .png literally
        # would make every JPEG record invisible here — never re-queued, never
        # aged out, and silently, since this only runs hourly on stale records.
        shots=("${rec}"/screenshot.*)
        (( ${#shots[@]} )) || continue                   # nothing to act on
        shot="${shots[0]}"
        rec_age_h=$(( (now - $(stat -c %Y "${rec}" 2>/dev/null || echo "$now")) / 3600 ))
        (( rec_age_h >= REQUEUE_AFTER_HOURS )) || continue  # still in flight

        if [[ -f "${rec}/requeued" ]]; then
            # Second time round and still no proposal — the outage is not passing.
            (( DRY )) && { log "would abandon ${id:0:8} (re-queued once, still failing)"; continue; }
            archive_record "$id" "$rec" failed "API unavailable across two attempts" \
                && { abandoned=$((abandoned + 1)); log "abandoned ${id:0:8}"; }
            notify "Capture gave up" high "warning,camera" \
                   "Could not reach the API for that screenshot (id ${id:0:8}) across two attempts. Take it again once things are healthy."
        else
            (( DRY )) && { log "would re-queue ${id:0:8} (${rec_age_h}h, no proposal)"; continue; }
            # Marker first: if the mv succeeds and we die before writing it, the
            # next sweep would re-queue forever. Marker-then-move fails safe.
            : > "${rec}/requeued"
            # Destination keeps .png regardless of the source's real format — it is
            # the queue token capture.triage.path globs on, and the triage sniffs
            # the bytes rather than trusting it.
            if mv -f "$shot" "${IN_DIR}/${id}.png"; then
                requeued=$((requeued + 1)); log "re-queued ${id:0:8} (${rec_age_h}h)"
            else
                log "  !! could not re-queue ${id:0:8}"
            fi
        fi
        continue
    fi

    age_h=$(( (now - $(stat -c %Y "${rec}/proposal.json")) / 3600 ))

    # --- expire ---
    if (( age_h >= IGNORE_AFTER_HOURS )); then
        (( DRY )) && { log "would archive ${id:0:8} as ignored (${age_h}h)"; continue; }
        archive_record "$id" "$rec" ignored "no action within ${age_h}h" \
            && { ignored=$((ignored + 1)); log "ignored ${id:0:8} (${age_h}h)"; }
        continue
    fi

    # --- one nudge ---
    if (( age_h >= RENOTIFY_AFTER_HOURS )) && [[ ! -f "${rec}/renotified" ]]; then
        (( DRY )) && { log "would re-notify ${id:0:8} (${age_h}h)"; continue; }
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

# --- prune old screenshots -------------------------------------------------
# Discard stops deleting once recording-mode leaves `off`, so images accumulate
# indefinitely — and a screenshot can hold anything that was on screen. Only the
# IMAGE is dropped; proposal, .ics, context and verdict stay, because they are
# text-sized and carry the analysis value. Cases the model got wrong keep their
# image, since those are the ones worth looking at again.
pruned=0
if (( PRUNE_IMAGE_AFTER_DAYS > 0 )); then
    for rec in "$ARCHIVE_DIR"/*/; do
        rec="${rec%/}"
        shots=("${rec}"/screenshot.*)
        (( ${#shots[@]} )) || continue
        outcome="$(jq -r '.outcome // ""' "${rec}/decision.json" 2>/dev/null)"
        [[ " ${PRUNE_KEEP_IMAGE_OUTCOMES} " == *" ${outcome} "* ]] && continue
        age_d=$(( (now - $(stat -c %Y "${shots[0]}" 2>/dev/null || echo "$now")) / 86400 ))
        (( age_d >= PRUNE_IMAGE_AFTER_DAYS )) || continue
        if (( DRY )); then
            log "would prune image from $(basename "$rec" | cut -c1-8) (${outcome}, ${age_d}d)"
        elif rm -f "${shots[@]}"; then
            : > "${rec}/screenshot.pruned"
            pruned=$((pruned + 1))
        fi
    done
fi

(( renotified || ignored || requeued || abandoned || pruned )) && \
    log "sweep: ${renotified} re-notified, ${ignored} ignored, ${requeued} re-queued, ${abandoned} abandoned, ${pruned} images pruned"
exit 0
