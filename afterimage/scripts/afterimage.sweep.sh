#!/usr/bin/env bash
# Housekeeping for pending captures. Run nightly at 07:30 SGT by
# afterimage.sweep.timer — morning-side, because most of what it does is send phone
# notifications, and 2am pings train you to mute the topic.
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
#   4. PRUNE the screenshot out of archived records older than
#      PRUNE_IMAGE_AFTER_DAYS. The text (proposal, .ics, context, verdict) stays.
#   5. REPORT any stray file sitting in incoming/ that the .path unit's *.png
#      glob cannot see — such a file is invisible to the whole pipeline and
#      nothing else will ever mention it.
#
# Makes no API calls itself — pure filesystem + ntfy. A re-queue causes the
# triage to make one, later.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=afterimage.lib.sh
source "${SELF_DIR}/afterimage.lib.sh"

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
# NO early exit on an empty pending/ — that exact line (`|| exit 0`) sat here from
# the first version, and because pending/ is empty on almost every run it skipped
# everything below the loop: the image prune NEVER actually ran in 90 days of
# hourly sweeps. An empty array just means the loop body doesn't execute.

now=$(date +%s)
renotified=0 ignored=0 requeued=0 abandoned=0 parked=0

for rec in "${records[@]}"; do
    rec="${rec%/}"
    id="$(basename "$rec")"

    # --- parked: the API never answered ---------------------------------------
    # The test is capture.json, NOT proposal.json. capture.json is the model's whole
    # reply and the triage writes it before any branch can resolve the record, so its
    # absence is the direct answer to "did the AI ever answer?". proposal.json was
    # only ever a proxy for that, and a wrong one: a needs-a-human record has no
    # proposal either, because there was no date to render. Keying on the proxy would
    # send a screenshot the model has already read back for a second vision call.
    if [[ ! -f "${rec}/capture.json" ]]; then
        # screenshot.* not screenshot.png: the triage names the claimed copy after its
        # real format (Android uploads are JPEG), so matching .png literally would make
        # every JPEG record invisible here.
        shots=("${rec}"/screenshot.*)
        (( ${#shots[@]} )) || continue                   # nothing to act on
        shot="${shots[0]}"

        # No stamp means the triage has not finished with it — a run still in flight,
        # not something parked. Leave it alone.
        [[ -f "${rec}/first_failed" ]] || continue
        first="$(date -d "$(cat "${rec}/first_failed")" +%s 2>/dev/null || echo "$now")"
        age_d=$(( (now - first) / 86400 ))

        # RESOLVE at seven days, measured from the FIRST failure. The two-attempt rule
        # this replaced was calibrated for an hourly sweep and inherited a nightly one,
        # so "retry once then give up" quietly became "give up after two days" — and
        # gave up on an outage that had not finished. Retries never move the marker, so
        # a stuck item cannot postpone its own deadline.
        if (( age_d >= PAUSED_GIVE_UP_DAYS )); then
            (( DRY )) && { log "would give up on ${id:0:8} (${age_d}d parked)"; continue; }
            # Say WHY, in the words ai_reason() used at the last park — this record
            # is being destroyed on the strength of it, and "could not reach the
            # API" is actively wrong for the commonest cause, an empty balance the
            # owner can fix. Records parked before paused_reason existed keep the
            # old wording rather than inventing a cause for them.
            #
            # Read BEFORE archive_record, which MOVES the whole record out of
            # pending/ — afterwards this path names nothing.
            gave_up=""
            [[ -f "${rec}/paused_reason" ]] && gave_up="$(cat "${rec}/paused_reason")"
            if [[ -n "$gave_up" ]]; then
                give_up_body="${gave_up} — that screenshot (id ${id:0:8}) went unanswered for ${age_d} days. Take it again once things are healthy."
            else
                give_up_body="Could not reach the API for that screenshot (id ${id:0:8}) in ${age_d} days. Take it again once things are healthy."
            fi
            archive_record "$id" "$rec" failed "API unavailable for ${age_d} days" \
                && { abandoned=$((abandoned + 1)); log "gave up on ${id:0:8} (${age_d}d)"; }
            notify "$(title_count Abandoned 1 Screenshot)" "" "exclamation" "$give_up_body"
            continue
        fi

        # Otherwise put it back in the queue. Once per sweep, so once per day: the
        # triage re-claims it, and if the API is still down it parks again with the
        # same stamp. Destination keeps .png whatever the source's real format — it is
        # the token afterimage.triage.path globs on, and the triage sniffs the bytes.
        (( DRY )) && { log "would retry ${id:0:8} (${age_d}d parked)"; parked=$((parked + 1)); continue; }
        if mv -f "$shot" "${IN_DIR}/${id}.png"; then
            requeued=$((requeued + 1)); parked=$((parked + 1))
            log "retrying ${id:0:8} (${age_d}d parked)"
        else
            log "  !! could not retry ${id:0:8}"
        fi
        continue
    fi

    # --- the model answered but there was nothing to propose --------------------
    # capture.json present, proposal.json absent: a needs-a-human record. Nothing to
    # retry — the model has read it and said it cannot place it — so it runs the same
    # nudge-then-expire lifecycle as a proposal nobody tapped. Ages from capture.json,
    # since there is no proposal to take an mtime from.
    if [[ ! -f "${rec}/proposal.json" ]]; then
        nh_age_h=$(( (now - $(stat -c %Y "${rec}/capture.json" 2>/dev/null || echo "$now")) / 3600 ))
        if (( nh_age_h >= IGNORE_AFTER_HOURS )); then
            (( DRY )) && { log "would archive needs-human ${id:0:8} (${nh_age_h}h)"; continue; }
            archive_record "$id" "$rec" needs_human "no action within ${nh_age_h}h" \
                && { ignored=$((ignored + 1)); log "needs-human expired ${id:0:8} (${nh_age_h}h)"; }
            continue
        fi
        if (( nh_age_h >= RENOTIFY_AFTER_HOURS )) && [[ ! -f "${rec}/renotified" ]]; then
            (( DRY )) && { log "would re-notify needs-human ${id:0:8} (${nh_age_h}h)"; continue; }
            nh_t="$(jq -r 'first(.events[]?.title // empty) // ""' "${rec}/capture.json" 2>/dev/null)"
            nh_r="$(jq -r '.reason // ""' "${rec}/capture.json" 2>/dev/null)"
            # Retract-then-publish under the same id the triage used, so the phone ends
            # up with one message rather than two.
            retract "$id"
            notify "$(title_count "Still Flagged" 1 Event "${nh_t}" "$(title_age "$nh_age_h")")" "" "exclamation" \
                   "$(md_escape "${nh_r:-Time or date unclear — not adding.}") — still waiting after ${nh_age_h}h." \
                   "" "$id"
            : > "${rec}/renotified"
            renotified=$((renotified + 1))
            log "re-notified needs-human ${id:0:8} (${nh_age_h}h)"
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
        if base="$(capture_base_url)" && actions="$(record_actions "$base" "$id" "$rec")"; then
            # The nudge used to hardcode [Add] [Discard], which dropped the
            # ALTERNATIVE button — while event.alt.ics sat on disk and the ?alt=1
            # route stayed live. Since the nudge retracts the original message, the
            # second reading was not merely unlabelled, it became unreachable: the
            # only notification offering it had just been withdrawn. record_actions
            # builds the same buttons the triage did, from the record itself.
            # Withdraw the original, then publish the nudge under the SAME id, so
            # the phone ends up with one notification rather than two. Deliberately
            # retract-then-publish and not an in-place update: an update may be
            # applied silently, and a nudge that does not alert is not a nudge.
            retract "$id"
            notify "$(title_quote "$title" "$(title_age "$age_h")")" "" "calendar" \
                   "${when} — proposed ${age_h}h ago, no action yet." "$actions" "$id"
            : > "${rec}/renotified"
            renotified=$((renotified + 1))
            log "re-notified ${id:0:8} (${age_h}h)"
        fi
    fi
done

# --- paused: the summary matches what is still parked ----------------------
# The triage publishes this too, but it only runs when a screenshot arrives — so
# the run that gave up on the LAST parked record above would otherwise leave
# "Paused: 1 Screenshot" on the phone until the next capture, which may be never.
# Unconditional, like the triage's: with nothing parked this is a retract and
# nothing else, and that retract is the whole point.
mapfile -t paused_items < <(parked_ids "$PENDING_DIR")
if (( DRY )); then
    log "would sync the paused summary (${#paused_items[@]} parked)"
else
    paused_sync "$PAUSED_NTFY_ID" Screenshot "$(parked_reason "$PENDING_DIR")" \
                "$(parked_cause "$PENDING_DIR")" \
                "archived in 7 days, and the screenshots go with them" "${paused_items[@]}"
fi

# --- withdraw notifications for resolved records ---------------------------
# A record in archive/ is resolved, however it got there — the ignore branch
# above, a triage failure, or a tap the CONTAINER archived. pending/<id> is gone,
# so its Add button now answers 404: the notification is not just clutter, it
# lies. This is the one place that withdraws it, precisely because archiving
# happens in both host bash and the container and only the sweep sees both.
#
# Marker-guarded, so each record costs exactly one DELETE ever. Records archived
# longer ago than RETRACT_WITHIN_DAYS get the marker WITHOUT the call: on the
# first run after this shipped, archive/ already held months of history whose
# notifications are long expired, and firing a delete for each would have pushed
# a burst of no-op events through the topic to no purpose.
retracted=0
for rec in "$ARCHIVE_DIR"/*/; do
    rec="${rec%/}"
    [[ -f "${rec}/retracted" ]] && continue
    rid="$(basename "$rec")"
    # decision.json is written as the record is archived, so its mtime is the
    # resolution time. Fall back to the directory for a record that predates it.
    anchor="${rec}/decision.json"; [[ -f "$anchor" ]] || anchor="$rec"
    arch_age_d=$(( (now - $(stat -c %Y "$anchor" 2>/dev/null || echo "$now")) / 86400 ))
    if (( DRY )); then
        (( arch_age_d < RETRACT_WITHIN_DAYS )) && log "would retract ${rid:0:8} (archived ${arch_age_d}d ago)"
        continue
    fi
    if (( arch_age_d < RETRACT_WITHIN_DAYS )); then
        retract "$rid"
        retracted=$((retracted + 1))
    fi
    : > "${rec}/retracted"
done

# --- prune old screenshots -------------------------------------------------
# Discard does not delete, so images accumulate indefinitely — and a screenshot
# can hold anything that was on screen. Only the IMAGE is dropped, whatever the
# record's outcome; proposal, .ics, context and verdict stay, because they are
# text-sized and carry the analysis value.
#
# THE MARKER IS NOT AN IMAGE. It is called screenshot.pruned, so it matches the
# screenshot.* glob below — which meant a record whose image had already gone was
# pruned again every night from the day the marker itself turned
# PRUNE_IMAGE_AFTER_DAYS old: the marker was deleted and immediately rewritten, its
# mtime reset, and the run counted a phantom prune. Nothing was lost (the image was
# already gone) but the count was a lie and the only evidence of when a record was
# pruned was destroyed nightly. Two guards, because the first is about intent and
# the second about the glob: skip a record that is already marked, and never let the
# marker into the list even if the first check is ever loosened.
pruned=0
if (( PRUNE_IMAGE_AFTER_DAYS > 0 )); then
    for rec in "$ARCHIVE_DIR"/*/; do
        rec="${rec%/}"
        [[ -f "${rec}/screenshot.pruned" ]] && continue
        shots=()
        for shot in "${rec}"/screenshot.*; do
            [[ -f "$shot" && "$shot" != *"/screenshot.pruned" ]] && shots+=("$shot")
        done
        (( ${#shots[@]} )) || continue
        age_d=$(( (now - $(stat -c %Y "${shots[0]}" 2>/dev/null || echo "$now")) / 86400 ))
        (( age_d >= PRUNE_IMAGE_AFTER_DAYS )) || continue
        if (( DRY )); then
            log "would prune image from $(basename "$rec" | cut -c1-8) (${age_d}d)"
        elif rm -f "${shots[@]}"; then
            : > "${rec}/screenshot.pruned"
            pruned=$((pruned + 1))
        fi
    done
fi

# --- stray files in incoming/ ----------------------------------------------
# The .path unit globs *.png and the triage drains the same glob, so anything else
# in incoming/ is invisible to the whole pipeline: no trigger, no triage, no
# notification, no ageing out — it just sits there looking accepted. The container
# only writes <id>.png (and cleans its own .part-* on restart), so a stray means
# something outside the normal flow put it there. Report it; deleting a file
# nobody understands is worse than naming it. One line per day until it is dealt
# with is the point, not a defect.
# A fresh .part-* is a legitimate upload mid-write, so anything younger than an
# hour is left unmentioned.
strays=()
for f in "$IN_DIR"/* "$IN_DIR"/.[!.]*; do
    [[ -f "$f" ]] || continue
    [[ "$f" == *.png ]] && continue
    (( now - $(stat -c %Y "$f" 2>/dev/null || echo "$now") >= 3600 )) || continue
    strays+=("$(basename "$f")")
done
if (( ${#strays[@]} )); then
    if (( DRY )); then
        log "would report ${#strays[@]} stray file(s) in incoming/: ${strays[*]}"
    else
        body="incoming/ holds ${#strays[@]} file$( (( ${#strays[@]} == 1 )) || printf s ) the pipeline cannot see:"
        for s in "${strays[@]:0:5}"; do body+=$'\n'"• $(md_escape "$s")"; done
        (( ${#strays[@]} > 5 )) && body+=$'\n'"• … and $(( ${#strays[@]} - 5 )) more"
        body+=$'\n'"Only *.png is triaged. Rename it to <uuid>.png to queue it, or remove it."
        notify "$(title_count Stranded "${#strays[@]}" File)" "" "exclamation" "$body"
        log "reported ${#strays[@]} stray file(s) in incoming/"
    fi
fi

(( renotified || ignored || requeued || abandoned || pruned || retracted )) && \
    log "sweep: ${renotified} re-notified, ${ignored} ignored, ${requeued} retried, ${abandoned} gave up, ${retracted} notifications withdrawn, ${pruned} images pruned"
exit 0
