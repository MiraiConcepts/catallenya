#!/usr/bin/env bash
# shellcheck disable=SC2034  # config vars are consumed by the scripts that source this
# Shared helpers for the capture triage. Sourced, never executed.
#
# Layout mirrors pigeonhole.lib.sh: config at the top, .env sourced at call time
# (it is runtime-only and not in the repo), ntfy addressed through the tailnet
# Caddy URL rather than a container name or a hardcoded IP.
#
# Everything that talks to api.anthropic.com now lives in ai.lib.sh, shared with
# documents.intake — api_post/api_class (transport + retry), image_mime/image_ext,
# ai_build_request and ai_extract. Sourced FIRST, before the log()/die() below, so
# this file's identical definitions stay authoritative. Do not re-add a local copy
# of any of it: capture's was the copy, and the divergence risk is the whole point.
# shellcheck source=/zpool/catallenya/ai/scripts/ai.lib.sh
source "/zpool/catallenya/ai/scripts/ai.lib.sh"

AFTERIMAGE_DIR="/zpool/catallenya/afterimage"
DATA_DIR="${AFTERIMAGE_DIR}/data"
IN_DIR="${DATA_DIR}/incoming"
PENDING_DIR="${DATA_DIR}/pending"
# Every capture ends here once resolved — accepted, rejected, or ignored — with the
# screenshot, the model's proposal and the recorded verdict side by side. That triple
# is a labelled EVAL example — not training data: these models cannot be fine-tuned
# here, so its uses are replaying a new model against recorded verdicts, iterating
# the prompt against real failures, and few-shot examples. Exactly the shape of the
# golden set used for the 2026-07-24 bake-off, but accumulating on its own.
ARCHIVE_DIR="${DATA_DIR}/archive"
# There is no ledger and no recording mode any more (retired 2026-08-01, with the
# documents convergence). State is LOCATIONS ONLY — incoming -> pending -> archive —
# and each archived record carries its own decision.json, so any ledger-style
# question is a jq over archive/*/decision.json. The mode machinery existed to
# protect a production accept-rate metric that was never actually consulted; old
# records keep their `mode` files and fields, which nothing reads.
SCRIPT_DIR="${AFTERIMAGE_DIR}/scripts"

NTFY_TOPIC="afterimage"
# Model + effort come from ai.lib.sh (AI_MODEL / AI_EFFORT), shared with the
# documents pipeline — one edit there moves both.
# Output ceiling for one triage call. Adaptive thinking counts against this, and a
# festival page fanning out to MAX_EVENTS_PER_CAPTURE entries is the widest reply the
# schema can produce. Truncation surfaces as stop_reason=max_tokens, which ai_extract
# rejects rather than handing a half-parsed proposal downstream.
MAX_TOKENS=4096
EVENT_TZ="Asia/Singapore" # fallback when the screenshot gives no timezone clue
DURATION_MIN=60           # default length when only a start time is known
# Everything here stays LOCAL: capture/ is deliberately absent from restic's path
# allowlist, so nothing is copied off-box. ZFS + sanoid still cover disk failure
# and rollback. Do NOT add capture/ to restic without revisiting that decision — a
# screenshot can contain anything that was on screen.
# A festival page can list a dozen acts, and each becomes its own notification, so
# this bounds the ping storm. Raised from 4 on 2026-07-27: a real Esplanade day
# listing had six and two were dropped. Truncating is now logged and surfaced in the
# notification body — silently discarding a user's events is worse than a few pings.
MAX_EVENTS_PER_CAPTURE=8
# Longest button label. ntfy imposes no limit of its own — 9, 17, 22 and 43
# characters were all accepted with HTTP 200 when tested on 2026-07-28 — so this
# is purely about phone width with three buttons in a row. 12 was the old value
# and truncated "Esplanade Concert Hall" to the mid-word "Esplanade Co", which
# read as a bug. Labels now cut back to a word boundary rather than mid-word, so
# raising this only ever adds whole words.
BUTTON_LABEL_MAX=20
# Separator between an event's detail and the alternative on offer. The word "or"
# used to sit here ("19:15  ·  or 20:15"); the bullet alone says the same thing in
# a line that has to survive a phone's wrapping.
ALT_SEP=" • "
RENOTIFY_AFTER_HOURS=24   # one nudge, in case the first ntfy was never seen
IGNORE_AFTER_HOURS=168    # 7 days untouched -> archive with outcome "ignored"

# Screenshot retention. Discard does not delete, so every capture accumulates —
# and a screenshot can hold anything that was on screen. After this many days the
# IMAGE is deleted from an archived record, whatever its outcome (7, was 90 — and
# the 90 never ran: the sweep exited early on an empty pending/ before reaching
# the prune, so nothing was ever pruned). The proposal, the rendered .ics, the
# context and the verdict stay forever: small, text-only, and they carry the
# analysis value. The old carve-out that kept failure-case images indefinitely
# retired with the ledger — a week is long enough to look at a case the model got
# wrong, and a screenshot is the sensitive half of the record.
# 0 disables pruning entirely.
PRUNE_IMAGE_AFTER_DAYS=7

# How far back the sweep's retract pass reaches into archive/. Anything resolved
# longer ago than this is marked as handled without a DELETE being sent: its
# notification has long since aged out of the phone, so the call would be a no-op
# event in the topic. Exists only to bound the FIRST run after this shipped, which
# would otherwise have swept every record ever archived.
RETRACT_WITHIN_DAYS=14

# API_MAX_ATTEMPTS / API_RETRY_BASE_S / API_URL and image_mime / image_ext moved to
# ai.lib.sh (sourced at the top). Transient-failure policy is unchanged: the record
# is left in pending/ without a proposal.json and the sweep re-queues the screenshot
# once before giving up.

# diff_axis <this-event-json> <other-event-json> -> year|date|time|venue|none
# Which single thing distinguishes two ways of attending the same event. Both the
# button labels and the notification body read this, so they can never disagree
# about what is being chosen — the body used to state "Wednesday, 31 March 2027" as
# settled while the buttons offered [31 Mar] [1 Apr].
diff_axis() {
    local a="$1" b="$2" ad bd at bt al bl
    ad="$(jq -r '.date // ""' <<<"$a")"; bd="$(jq -r '.date // ""' <<<"$b")"
    [[ "${ad%%-*}" != "${bd%%-*}" ]] && { echo year;  return; }
    [[ "$ad" != "$bd" ]]              && { echo date;  return; }
    at="$(jq -r '.start_time // ""' <<<"$a")"; bt="$(jq -r '.start_time // ""' <<<"$b")"
    [[ "$at" != "$bt" ]]              && { echo time;  return; }
    al="$(jq -r '.location // ""' <<<"$a")";   bl="$(jq -r '.location // ""' <<<"$b")"
    [[ -n "$al" && "$al" != "$bl" ]]  && { echo venue; return; }
    echo none
}

# button_label <this-event-json> <other-event-json> -> short button text
# Labels the axis that actually DIFFERS between the two choices, so a pair always
# reads as a comparison rather than two unrelated facts:
#
#   two showtimes      [19:15]     [20:15]
#   a run over 2 days  [30 Jul]    [31 Jul]
#   two years          [15 Nov 26] [15 Nov 27]
#   two venues         [Esplanade] [TOMATILLO]
#
# Symmetric by construction: each side is told about the other, so the primary can
# never show its time while the alternative shows a date. Pass the same object twice
# when there is no alternative — a lone button then says the time, which is right.
#
# Nothing here comes from the model: it used to name the alternative itself, and its
# prompt examples were 12-hour while the primary is forced to 24-hour, which is how a
# notification came to read "19:00" beside "8.15pm".
button_label() {
    local a="$1" b="$2" at v sd ed
    at="$(jq -r '.start_time // ""' <<<"$a")"
    case "$(diff_axis "$a" "$b")" in
        year)  date -d "$(jq -r '.date' <<<"$a")" '+%-d %b %y' 2>/dev/null || printf 'Alternative' ;;
        date)  date -d "$(jq -r '.date' <<<"$a")" '+%-d %b'    2>/dev/null || printf 'Alternative' ;;
        time)
            if [[ "$at" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then printf '%s' "$at"
            else printf 'All day'; fi ;;
        venue)
            # Strip to the Actions-header charset before truncating, so a venue with
            # a comma shortens rather than failing the whitelist outright.
            v="$(jq -r '.location' <<<"$a" | tr -cd 'A-Za-z0-9 :.-')"
            if (( ${#v} > BUTTON_LABEL_MAX )); then
                # Cut back to a WORD boundary. A hard cut produced "Esplanade Co",
                # which reads as a rendering fault rather than an abbreviation.
                # A single word longer than the cap still has to be chopped.
                if [[ "${v:BUTTON_LABEL_MAX:1}" == " " ]]; then
                    v="${v:0:BUTTON_LABEL_MAX}"
                else
                    v="${v:0:BUTTON_LABEL_MAX}"
                    [[ "$v" == *" "* ]] && v="${v% *}"
                fi
            fi
            printf '%s' "$(sed 's/ *$//' <<<"$v")" ;;
        *)
            # A SPAN labels its range. "All day" on a two-day market says nothing
            # about the second day, and the range is the whole point of end_date.
            sd="$(jq -r '.date' <<<"$a")"; ed="$(jq -r '.end_date // ""' <<<"$a")"
            if [[ -n "$ed" && "$ed" != "null" && "$ed" != "$sd" ]]; then
                if [[ "$(date -d "$sd" '+%m' 2>/dev/null)" == "$(date -d "$ed" '+%m' 2>/dev/null)" ]]; then
                    printf '%s-%s' "$(date -d "$sd" '+%-d' 2>/dev/null)" \
                                   "$(date -d "$ed" '+%-d %b' 2>/dev/null)"
                else
                    # Crosses a month, so both halves need their month naming.
                    printf '%s-%s' "$(date -d "$sd" '+%-d %b' 2>/dev/null)" \
                                   "$(date -d "$ed" '+%-d %b' 2>/dev/null)"
                fi
            elif [[ "$(jq -r '.all_day' <<<"$a")" == "true" || -z "$at" || "$at" == "null" ]]; then
                printf 'All day'
            elif [[ "$at" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then printf '%s' "$at"
            else printf 'Alternative'; fi ;;
    esac
}

# fork_record <src-record> <dst-record> <ext> <capture-group-id>
# Copy one capture's record into a sibling for another event from the same
# screenshot. The image is HARDLINKED, so N events off one screenshot cost one
# image on disk.
#
# Every sibling must exist before any event is processed: archive_record MOVES the
# record directory, so a failure on the first event once deleted the screenshot the
# remaining events were still being built from, losing the whole capture.
fork_record() {
    local src="$1" dst="$2" ext="$3" group="$4"
    mkdir -p "$dst" || return 1
    ln "${src}/screenshot.${ext}" "${dst}/screenshot.${ext}" 2>/dev/null \
        || cp "${src}/screenshot.${ext}" "${dst}/screenshot.${ext}" || return 1
    # The whole model reply, so any record can answer "what else was on that page".
    cp "${src}/capture.json" "${dst}/capture.json" 2>/dev/null
    jq -c --arg g "$group" '. + {capture_group:$g}' "${src}/context.json" \
        > "${dst}/context.json" 2>/dev/null || cp "${src}/context.json" "${dst}/context.json" 2>/dev/null
    return 0
}

# event_is_past <date> <start_time> <all_day> <now-epoch> -> true when it is over
# Computed here, never asked of the model. An all-day event is past only once its
# whole day has gone; a timed one the moment its start has.
event_is_past() {
    local d="$1" st="$2" ad="$3" now="$4" when
    if [[ "$ad" == "true" || -z "$st" || "$st" == "null" ]]; then
        when="$(TZ="$EVENT_TZ" date -d "${d} 23:59:59" +%s 2>/dev/null)" || return 1
    else
        when="$(TZ="$EVENT_TZ" date -d "${d} ${st}" +%s 2>/dev/null)" || return 1
    fi
    [[ -n "$when" ]] || return 1
    (( when < now ))
}

# api_class / api_post moved to ai.lib.sh (sourced at the top), unchanged.

REQUEUE_AFTER_HOURS=1     # how long a proposal-less record waits before re-queueing.
                          # Must exceed the triage's TimeoutStartSec (15min) so a
                          # run still in flight is never adopted mid-call.

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# Caddy serves ntfy on the tailnet; the URL comes from .env like everything else
# (no hardcoded IP, no docker socket). Returns non-zero if .env is unreadable.
# Only the four keys this pipeline needs, extracted rather than sourced. `source`
# on the root .env pulled in every database credential and service token the stack
# has — roughly forty values, to use four — while the unit file claimed the sandbox
# prevented it. It is also arbitrary code execution if that file ever grows a
# $(...), which a data file should never be able to do.
#
# (Deliberately not naming the variables here: gitleaks 8.24.3, which CI pins,
# reads a secret-shaped name beside the word "password" as a finding.)
_load_env() {
    local root_env="/zpool/catallenya/.env" k v line
    [[ -f "$root_env" ]] || { log "no .env"; return 1; }
    for k in TAILNET_DOMAIN TAILNET_DNS_NAME NTFY_REVERSE_PROXY_PORT AFTERIMAGE_REVERSE_PROXY_PORT; do
        line="$(grep -m1 "^${k}=" "$root_env" 2>/dev/null)" || continue
        v="${line#*=}"
        v="${v%\"}"; v="${v#\"}"     # tolerate quoted values
        printf -v "$k" '%s' "$v"
    done
}

# hdr_safe and md_escape moved to ai.lib.sh (sourced at the top), unchanged. They
# guard the same boundary ai_extract does — untrusted model output heading for a
# sink — and documents.intake needs them for identical reasons.

# --- the model-output gate -------------------------------------------------
# Everything the model returns is untrusted: it is derived from a screenshot whose
# contents an attacker may control. It reaches three sinks that each used to defend
# themselves differently (a curl body, an iCalendar TEXT value, the ntfy body the
# user actually reads). These two functions are the single choke point instead —
# run once, immediately after the API call, before any consumer.

# clean_proposal <json> -> json on stdout
# Strip C0 control characters and DEL from every model-authored free-text field, and
# cap length. Control characters are what let a title break out of an iCalendar
# property; the cap keeps an over-long field from crowding out the rest of the body.
clean_proposal() {
    jq -c '
      def clean: if type == "string"
                 then (explode | map(select(. >= 32 and . != 127)) | implode | .[0:500])
                 else . end;
        .reason |= clean
      | .events = [ .events[]?
                    | .title       |= clean
                    | .location    |= clean
                    | .description |= clean
                    | .alternatives = [ .alternatives[]? | .location |= clean ] ]
    ' <<<"$1"
}

# validate_proposal <json> -> prints a reason code and returns 1 if unusable.
# Mechanical checks only — never the model's own self-assessment.
#
# The structured-output schema constrains SHAPE, not VALUES: date, start_time and
# timezone are plain strings. documents.intake learned this the expensive way — its
# date regex accepted 2023-02-29 and a model emitted exactly that on a paystub,
# twice, which is what commit fa5638e fixed. A strict schema is necessary and not
# sufficient; this is that pipeline's `gate()` applied to the same problem.
validate_proposal() {
    local p="$1" v f

    v="$(jq -r '.date // ""' <<<"$p")"
    [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "BAD_DATE"; return 1; }
    date -d "$v" >/dev/null 2>&1 || { echo "IMPOSSIBLE_DATE"; return 1; }

    # end_date turns an event into a SPAN, so a bad one silently changes how long
    # the entry is rather than failing visibly. An end before the start would make
    # render_ics emit DTEND < DTSTART, which clients display unpredictably.
    local ed; ed="$(jq -r '.end_date // "null"' <<<"$p")"
    if [[ "$ed" != "null" && -n "$ed" ]]; then
        [[ "$ed" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "BAD_END_DATE"; return 1; }
        date -d "$ed" >/dev/null 2>&1 || { echo "IMPOSSIBLE_END_DATE"; return 1; }
        [[ "$ed" < "$v" ]] && { echo "END_BEFORE_START"; return 1; }
    fi

    # HH:MM 24h, or null. An unparseable time used to fall through to an all-day
    # event while the notification still showed "5pm" — the user approved one thing
    # and the calendar got another.
    for f in start_time end_time; do
        v="$(jq -r --arg f "$f" '.[$f] // "null"' <<<"$p")"
        [[ "$v" == "null" ]] && continue
        [[ "$v" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "BAD_TIME"; return 1; }
    done

    # The zone must resolve. render_ics.py falls back to EVENT_TZ on an unknown zone,
    # but the notification shows a bare HH:MM with no zone — so a bad value is an
    # invisible time shift on an event the user thinks they verified.
    v="$(jq -r '.timezone // ""' <<<"$p")"
    if [[ -n "$v" ]] && ! python3 -c 'import sys,zoneinfo; zoneinfo.ZoneInfo(sys.argv[1])' "$v" 2>/dev/null; then
        echo "BAD_TIMEZONE"; return 1
    fi

    # The alternative is rendered into a real .ics and written on one tap, so it gets
    # the same checks. An unusable alternative is dropped, not fatal — the primary
    # reading is still good (afterimage.triage.sh falls back to plain Add/Discard).
    if [[ "$(jq -r '.alternatives | length' <<<"$p")" -gt 0 ]]; then
        v="$(jq -r '.alternatives[0].date // ""' <<<"$p")"
        if ! [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! date -d "$v" >/dev/null 2>&1; then
            echo "BAD_ALT"; return 1
        fi
        for f in start_time end_time; do
            v="$(jq -r --arg f "$f" '.alternatives[0][$f] // "null"' <<<"$p")"
            [[ "$v" == "null" ]] && continue
            [[ "$v" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "BAD_ALT"; return 1; }
        done
    fi
    return 0
}

# triage_route <is_event> <needs_human> <event-count> -> not_event|needs_human|events
# Which branch a model reply belongs in. Pure, and here rather than inline in
# afterimage.triage.sh so the tests assert the REAL mapping instead of a copy of it
# that drifts — same reasoning as api_class.
#
# THE ORDER IS THE WHOLE POINT, and it used to be wrong. The "no events" test ran
# first, so a reply meaning "this needs your attention but I could not build an
# event" — is_event=true, needs_human=true, events=[] — was reported as the quiet
# "No event found" instead of the "Needs a human" warning. A capture asking for
# help was filed as junk. Found 2026-07-28 replaying an archived capture through
# a different model, which emits that shape where opus-5 emits a placeholder
# event alongside; nothing guarantees opus-5 never will.
#
# is_event=false is still decided first: the model saying nothing schedulable is
# here settles the question, and a needs_human beside it is noise.
triage_route() {
    local is_event="$1" needs_human="$2" n="$3"
    [[ "$is_event"    != "true" ]] && { echo not_event;   return; }
    [[ "$needs_human" == "true" ]] && { echo needs_human; return; }
    # A non-numeric count is a malformed reply with nothing to add to a calendar.
    [[ "$n" =~ ^[0-9]+$ ]] || { echo not_event; return; }
    (( n == 0 )) && { echo not_event; return; }
    echo events
}

# notify <title> <priority> <tags> <body> [actions] [id]
# `actions` is a raw ntfy Actions header value; omit for a plain note.
#
# `id` is an ntfy sequence id (X-Sequence-ID). Pass the RECORD id for anything that can
# later become stale — it is what retract() addresses, and it is the only way to
# take a notification off the phone. Omit it for one-shot notices that nothing
# will ever withdraw (infrastructure alarms, "Already Passed"): an untagged
# message simply cannot be retracted, which for those is the correct behaviour.
#
# An EMPTY priority sends no Priority header at all, which is what the calendar
# notifications now do: ntfy then applies its own default and every proposal
# arrives at the same weight. Ranking them against each other was noise — a
# past-event note is not more or less important than the event beside it. The
# argument is kept, not removed, because the infrastructure alarms (a capture
# stuck in incoming/, a run that gave up) genuinely do want to shout. One
# calendar-facing exception: needs-a-human is high, because it fires exactly
# once with no buttons and no sweep nudge — the rationale is at its call site.
notify() {
    _load_env || { log "skipping notify"; return 0; }
    local url="https://${TAILNET_DOMAIN}.${TAILNET_DNS_NAME}:${NTFY_REVERSE_PROXY_PORT}"
    # Title is model-derived; Priority/Tags are ours. Sanitize the untrusted one.
    # Markdown renders in the ntfy web client, which is where these are read.
    # The Android app shows the raw markers instead — if that ever becomes the
    # primary surface, drop this header rather than un-escaping the bodies.
    local -a hdr=(-H "Title: $(hdr_safe "$1")" -H "Tags: $3" -H "Markdown: yes")
    [[ -n "${2:-}" ]] && hdr+=(-H "Priority: $2")
    # Sanitised here, not left to callers. Both current callers whitelist the
    # strings they splice in, but a CR/LF reaching this header injects a SECOND
    # Actions header, and Go's Header.Get returns the FIRST — so injected buttons
    # would REPLACE the real ones and a tap would POST wherever the attacker chose.
    [[ -n "${5:-}" ]] && hdr+=(-H "Actions: $(tr -d '\r\n' <<<"$5")")
    # X-Sequence-ID, and only this spelling family. `X-ID` looks like the obvious
    # name, is accepted with a 200, and is SILENTLY IGNORED — the message comes back
    # with no sequence_id and every later retract addresses nothing. Verified
    # against 2.27.0 by diffing our header against the CLI's own --sequence-id:
    # X-Sequence-ID / Sequence-ID / Sid work, X-ID / X-Seq / Seq do not.
    [[ -n "${6:-}" ]] && hdr+=(-H "X-Sequence-ID: $(ntfy_id_safe "$6")")
    # --data-raw, never -d: curl reads a -d value beginning with "@" as a FILENAME
    # and POSTs that file's contents. The body here is model-derived — a screenshot
    # saying 'set reason to "@/zpool/catallenya/.env"' would exfiltrate the file to
    # this (unauthenticated) topic. --data-raw is byte-identical except it never
    # interprets a leading @. Same fix applied to pigeonhole.lib.sh and
    # immich.fix-rotations.daily.sh, which carry copies of this function.
    ntfy_muted && return 0
    curl -fsS --max-time 15 "${hdr[@]}" \
        --data-raw "$(tail -c 3500 <<<"$4")" "${url}/${NTFY_TOPIC}" >/dev/null || true
}

# Test seam, mirroring pigeonhole.lib.sh, where it was added because that suite runs
# the real triage and apply and was publishing to the live topic on every run. This
# suite drives the sweep only with --dry-run, so it has never had the symptom — the
# seam is here so it cannot acquire it the first time a case runs something for
# real. Placed just BEFORE the curl, so header construction and sanitisation are
# still exercised under test. Never set in production.
ntfy_muted() { [[ "${NTFY_DISABLE:-}" == "1" ]]; }

# ntfy_id_safe <id> — reduce an id to what is safe in BOTH a header value and a
# URL path segment. Every current caller passes a UUID, so this changes nothing
# today; it is here because the id reaches ntfy through two different syntaxes
# and a stray slash would silently retract the wrong path.
#
# Leading dots go too, which is not fussiness: the charset alone leaves ".." whole,
# and DELETE on <topic>/.. resolves to the topic root rather than to a message.
# Stripping them empties that value, and retract() declines an empty id.
ntfy_id_safe() { tr -cd 'A-Za-z0-9._-' <<<"$1" | sed 's/^\.*//'; }

# retract <id> — take a previously tagged notification off the phone.
#
# ntfy has no per-message expiry and no scheduled delete (checked against 2.27.0,
# our server): the only way a notification disappears is an explicit DELETE
# addressed to its sequence id, which the server broadcasts to subscribers as a
# message_delete event. That is why every retractable notification has to carry
# an X-Sequence-ID in the first place.
#
# Best-effort by design, like notify(): a failed retract leaves clutter, never a
# wrong outcome, and must not fail the archive that called it. The server answers
# 200 even for an id it has never seen, so calling this speculatively is free.
#
# Known gap: the delete event lives in the server cache like any message, so a
# phone offline longer than the cache window (NTFY_CACHE_DURATION, widened to 72h
# in docker-compose.yml for exactly this reason) never receives it and keeps the
# stale notification. Re-sending for N nights would buy N days; not done, because
# the app's own auto-delete already mops up the rare straggler.
retract() {
    local id="${1:-}"
    [[ -n "$id" ]] || return 0
    _load_env || return 0
    local url="https://${TAILNET_DOMAIN}.${TAILNET_DNS_NAME}:${NTFY_REVERSE_PROXY_PORT}"
    ntfy_muted && return 0
    curl -fsS --max-time 15 -X DELETE \
        "${url}/${NTFY_TOPIC}/$(ntfy_id_safe "$id")" >/dev/null || true
}

# write_context <record-dir> <now-local> <image> <prompt>
# Everything needed to interpret this record later, written when the capture is
# claimed so it survives an API failure too.
#
# The prompt is stored in full, not just hashed. A record has to be readable on its
# own — without checking out the commit the repo happened to be on that day — and
# 2KB of text next to a 2MB screenshot costs nothing. The hash is there so records
# can be grouped by prompt version without diffing text. The schema is hashed only,
# since it is long and rarely the thing you are asking about.
#
# Without this, a proposal cannot be attributed: the prompt changed twice on
# 2026-07-27 alone, so a difference between two records could be the prompt, the
# model, or the screenshot, with no way to tell which.
write_context() {
    local rec="$1" now_local="$2" img="$3" prompt="$4"
    local psha ssha bytes
    # Hash the TEMPLATE, not the rendered prompt. The prompt embeds the capture
    # time, so hashing the rendered text gave every capture a unique digest — seven
    # captures produced five hashes on 2026-07-27 — which defeats the only thing the
    # field is for: grouping records by prompt version. Substituting the timestamp
    # back out makes the digest stable across captures and change only when the
    # wording does.
    psha="$(printf '%s' "${prompt//${now_local}/<NOW>}" | sha256sum | cut -d' ' -f1)"
    ssha="$(printf '%s' "$CAPTURE_SCHEMA" | sha256sum | cut -d' ' -f1)"
    bytes="$(stat -c %s "$img" 2>/dev/null || echo 0)"

    jq -n --arg captured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          --arg captured_at_local "$now_local" --arg event_tz "$EVENT_TZ" \
          --arg model "$AI_MODEL" --arg effort "$AI_EFFORT" \
          --arg prompt "$prompt" --arg prompt_sha256 "$psha" \
          --arg schema_sha256 "$ssha" --arg mime "$(image_mime "$img")" \
          --argjson bytes "$bytes" --argjson duration_min "$DURATION_MIN" \
        '{captured_at:$captured_at, captured_at_local:$captured_at_local,
          event_tz:$event_tz,
          model:$model, effort:$effort, duration_min:$duration_min,
          prompt_sha256:$prompt_sha256, schema_sha256:$schema_sha256,
          image:{mime:$mime, bytes:$bytes},
          prompt:$prompt}' > "${rec}/context.json"
}

# add_usage <record-dir> <api-response>
# Fold the API's token counts into context.json once the call has returned. This is
# what answers "would a cheaper model do" without re-running anything.
add_usage() {
    local rec="$1" resp="$2" tmp
    [[ -f "${rec}/context.json" ]] || return 0
    tmp="$(mktemp)"
    if jq --argjson usage "$(jq -c '.usage // {}' <<<"$resp" 2>/dev/null || echo '{}')" \
          '. + {usage:$usage}' "${rec}/context.json" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "${rec}/context.json"
    else
        rm -f "$tmp"
    fi
}

# archive_record <id> <src-dir> <outcome> [note]
# Resolve a capture: stamp the verdict into decision.json and move the whole
# record (screenshot + proposal + rendered .ics) into the archive. The record IS
# the history — there is no ledger beside it.
# Outcomes: add | add_alt | discard | ignored | needs_human | not_event | failed
archive_record() {
    local id="$1" src="$2" outcome="$3" note="${4:-}"
    local dest="${ARCHIVE_DIR}/${id}"
    [[ -d "$src" ]] || return 1

    mkdir -p "$ARCHIVE_DIR"

    local decided proposed latency anchor
    decided="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # proposal.json's mtime is when the model answered. The record DIRECTORY was
    # used here before, but a directory's mtime moves every time a file is written
    # into it — including the sweep's own renotified/requeued markers — so the two
    # halves of this pipeline were writing the same field under two different
    # definitions. server.ts stats proposal.json; match it, and fall back to the
    # directory only when there is no proposal (a capture that failed before one).
    anchor="${src}/proposal.json"
    [[ -f "$anchor" ]] || anchor="$src"
    proposed="$(date -u -r "$anchor" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$decided")"
    latency=$(( $(date +%s) - $(stat -c %Y "$anchor" 2>/dev/null || date +%s) ))

    jq -n --arg id "$id" --arg outcome "$outcome" --arg note "$note" \
          --arg decided "$decided" --arg proposed "$proposed" --argjson latency "$latency" \
        '{id:$id, outcome:$outcome, note:$note, proposed_at:$proposed,
          decided_at:$decided, latency_s:$latency}' > "${src}/decision.json"

    rm -rf "$dest"
    mv "$src" "$dest" || return 1
    # NOT retracted here. Archiving happens in three places — this function, the
    # triage's terminal branches, and the container's own archive() on a tap — and
    # only one of them is host bash. The sweep withdraws notifications for
    # everything in archive/ in a single pass instead, so "resolved implies
    # withdrawn" holds however the record got resolved, including a tap.
}

# The capture service's own tailnet URL — the Add/Discard buttons POST back here,
# so the phone/laptop tapping them must be able to reach it (tailnet: yes).
#
# Every component is asserted: an unset var would otherwise yield a syntactically
# valid but dead URL ("https://host.ts.net:") and the buttons would fail silently
# on tap. Caught in live testing 2026-07-25 — fail loudly instead.
capture_base_url() {
    _load_env || return 1
    local host="${TAILNET_DOMAIN:-}.${TAILNET_DNS_NAME:-}" port="${AFTERIMAGE_REVERSE_PROXY_PORT:-}"
    [[ -n "${TAILNET_DOMAIN:-}" && -n "${TAILNET_DNS_NAME:-}" ]] || {
        log "TAILNET_DOMAIN/TAILNET_DNS_NAME unset in .env"; return 1; }
    [[ -n "$port" ]] || { log "AFTERIMAGE_REVERSE_PROXY_PORT unset in .env"; return 1; }
    printf 'https://%s:%s' "$host" "$port"
}

# Structured-output schema. Sent as output_config.format.schema, so the model
# cannot return anything but this shape (no parsing of prose, no retries on
# malformed JSON). additionalProperties:false is required by the API.
read -r -d '' CAPTURE_SCHEMA <<'JSON' || true
{
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "is_event":    {"type": "boolean"},
    "needs_human": {"type": "boolean"},
    "events_seen": {"type": "integer"},
    "reason":      {"type": ["string", "null"]},
    "events": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "calendar":    {"type": "string", "enum": ["general", "birthday"]},
          "title":       {"type": "string"},
          "date":        {"type": "string"},
          "end_date":    {"type": ["string", "null"]},
          "start_time":  {"type": ["string", "null"]},
          "end_time":    {"type": ["string", "null"]},
          "all_day":     {"type": "boolean"},
          "timezone":    {"type": "string"},
          "recurrence":  {"type": "string", "enum": ["none","yearly","monthly","weekly","daily"]},
          "location":    {"type": ["string", "null"]},
          "description": {"type": ["string", "null"]},
          "alternatives": {
            "type": "array",
            "items": {
              "type": "object",
              "additionalProperties": false,
              "properties": {
                "date":       {"type": "string"},
                "start_time": {"type": ["string", "null"]},
                "end_time":   {"type": ["string", "null"]},
                "location":   {"type": ["string", "null"]}
              },
              "required": ["date", "start_time", "end_time", "location"]
            }
          }
        },
        "required": ["calendar","title","date","end_date","start_time","end_time","all_day",
                     "timezone","recurrence","location","description","alternatives"]
      }
    }
  },
  "required": ["is_event","needs_human","events_seen","reason","events"]
}
JSON
