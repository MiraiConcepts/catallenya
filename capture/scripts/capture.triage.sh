#!/usr/bin/env bash
# Capture triage: screenshot -> opus-5 (vision) -> .ics + ntfy proposal.
#
# Fired by capture.triage.path whenever a PNG lands in data/incoming/. Drains the
# whole directory serially, then exits.
#
# HARD INVARIANT — every file MUST leave incoming/ before this script can exit,
# success or failure. PathExistsGlob re-fires for as long as a file remains, so a
# crash that left the PNG in place would hot-loop systemd and bill an API call per
# spin. Every path below either moves the file out or deletes it.
#
# Model contract (validated 2026-07-25): claude-opus-5, vision (base64 image, NOT
# OCR — the bake-off showed modality was the lever, 7/7 vs 4/7), adaptive thinking
# at medium effort, and output_config.format json_schema so the reply is a
# schema-constrained object rather than prose to parse.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=capture.lib.sh
source "${SELF_DIR}/capture.lib.sh"

: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY not set (EnvironmentFile=/etc/capture.env)}"

mkdir -p "$IN_DIR" "$PENDING_DIR" "$ARCHIVE_DIR"

# Nothing is purged here: screenshots are retained indefinitely as dataset
# material, and capture.sweep.sh owns the pending -> renotify -> ignored lifecycle.

# --- prompt ----------------------------------------------------------------
# NOW is the capture time in SGT: relative dates ("next Sunday", "the 26th")
# must resolve against when the screenshot was taken, never against host time
# (this host runs PDT while the calendar is SGT).
triage_prompt() {
    cat <<EOF
You are a calendar triage assistant. You are looking at a screenshot from the user's screen. Decide whether it describes ONE specific calendar event to add.

The current date/time is ${1} (${EVENT_TZ}); resolve relative dates against it, but prefer explicit dates shown in the image.

Rules:
- Not a specific event (receipt, article, ad, meme, general chat, a contact card with no request) -> is_event=false.
- timezone: infer from context; if unclear use ${EVENT_TZ}.
- calendar: "birthday" ONLY for a person's birthday/DOB -> then title="<Name> Birthday", all_day=true, recurrence="yearly". Otherwise "general".
- If several times were discussed and the last one was proposed but never explicitly confirmed, USE THAT LAST PROPOSED TIME and set needs_human=false. The user reviews every event before it is added, so a stated-but-unconfirmed time is useful; note the uncertainty in description. Reserve needs_human=true for when NO usable time is stated at all (e.g. "sometime next week") — never invent one.
- Read times from the image directly; do not trust a time you are unsure of.
- date = YYYY-MM-DD; start_time = HH:MM 24h in the event's local timezone (null if all_day).
- end_time: if the image shows an end time or a duration ("5:00 PM - 7:00 PM", "2hrs", "90 min"), give the resulting HH:MM end. Null if only a start is shown — a sensible default is applied then.
- title: short and human, no emoji prefix.
- location: include the venue/address if shown, else null.
- alternatives: when the screenshot genuinely supports more than one reading (two times discussed, a corrected date, two possible venues), list the ONE next-most-likely reading here so the user can pick it with a single tap. Each needs a short button label (<=12 chars, e.g. "2:00pm" or "Sat 25 Jul"). Give an empty array when the reading is unambiguous — do not invent alternatives. Only the first is used.
EOF
}

# ask <png> <now-human> -> structured JSON on stdout, non-zero on failure
ask() {
    local png="$1" now="$2" b64f msgf out
    b64f="$(mktemp)"; msgf="$(mktemp)"
    # Base64 goes via a FILE, never argv — a screenshot is ~1MB of base64, well
    # past ARG_MAX. (Same trap that bit documents.intake three times.)
    base64 -w0 "$png" > "$b64f"

    jq -n --rawfile b64 "$b64f" --arg prompt "$(triage_prompt "$now")" \
          --argjson schema "$CAPTURE_SCHEMA" --arg model "$MODEL" --arg effort "$EFFORT" \
        '{model: $model,
          max_tokens: 4096,
          thinking: {type: "adaptive"},
          output_config: {effort: $effort,
                          format: {type: "json_schema", schema: $schema}},
          messages: [{role: "user", content: [
            {type: "image", source: {type: "base64", media_type: "image/png",
                                     data: ($b64|rtrimstr("\n"))}},
            {type: "text", text: $prompt}]}]}' > "$msgf"
    rm -f "$b64f"

    # The key goes via a curl config on stdin, never argv: /proc is mounted
    # without hidepid here, so /proc/<pid>/cmdline is world-readable for the whole
    # 10-20s call. (The unit comment used to claim this was already true. It was
    # not — fixed 2026-07-25.)
    out="$(curl -fsS -K - --max-time 180 2>&1 <<CURLRC
url = "https://api.anthropic.com/v1/messages"
header = "x-api-key: ${ANTHROPIC_API_KEY}"
header = "anthropic-version: 2023-06-01"
header = "content-type: application/json"
data-binary = "@${msgf}"
CURLRC
)"
    local rc=$?
    rm -f "$msgf"
    (( rc == 0 )) || { log "  !! api call failed: $(tail -c 300 <<<"$out")"; return 1; }

    # A refusal or a truncated reply is not a usable proposal — fail loudly
    # rather than handing malformed JSON to the renderer.
    local stop
    stop="$(jq -r '.stop_reason // "?"' <<<"$out" 2>/dev/null)"
    case "$stop" in
        end_turn) ;;
        refusal)    log "  !! model refused"; return 1 ;;
        max_tokens) log "  !! truncated (max_tokens)"; return 1 ;;
        *)          log "  !! unexpected stop_reason=$stop"; return 1 ;;
    esac

    # With output_config.format the first text block IS the JSON object.
    jq -e -c 'first(.content[]? | select(.type=="text") | .text) | fromjson' <<<"$out" 2>/dev/null \
        || { log "  !! no structured object in reply"; return 1; }
}

# --- drain incoming/ -------------------------------------------------------
shopt -s nullglob
pngs=("$IN_DIR"/*.png)
(( ${#pngs[@]} )) || { log "nothing to do"; exit 0; }
log "draining ${#pngs[@]} capture(s)"

for png in "${pngs[@]}"; do
    id="$(basename "$png" .png)"
    log "capture ${id}"

    # Anchor "now" to the upload time (file mtime) expressed in the event tz.
    # Read BEFORE the move, since mv preserves mtime but the path changes.
    now_h="$(TZ="$EVENT_TZ" date -r "$png" '+%A %Y-%m-%d %H:%M')"
    now_z="$(date -u +%Y%m%dT%H%M%SZ)"

    # CLAIM THE FILE FIRST — this is what makes the hard invariant real.
    # Everything below operates on the moved copy, so incoming/ is drained before
    # a single API token is spent. Previously the move happened AFTER the call,
    # which meant (a) an unchecked mv failure on a full pool left the PNG in
    # place and PathExistsGlob re-fired it forever at ~$9/hour, and (b) any
    # crash, OOM, reboot or TimeoutStartSec kill mid-call re-billed the capture
    # on the next fire. Failing to claim is now fatal for this file, not silent.
    rec="${PENDING_DIR}/${id}"
    if ! mkdir -p "$rec" || ! mv -f "$png" "${rec}/screenshot.png"; then
        log "  !! cannot claim ${id:0:8} into pending/ — leaving it and skipping"
        notify "Capture stuck" high "warning,camera" \
               "Could not move a screenshot out of incoming/ (id ${id:0:8}). Disk full? The trigger will keep retrying until this is cleared."
        continue
    fi
    png="${rec}/screenshot.png"

    if ! proposal="$(ask "$png" "$now_h")"; then
        archive_record "$id" "$rec" failed "triage API call failed"
        notify "Capture failed" default "warning,camera" \
               "Could not read that screenshot (id ${id:0:8})."
        continue
    fi

    # Strip control characters from every free-text field before ANY consumer runs.
    # This has to happen here, not just before the .ics render: the not_event branch
    # below sends the model's `reason` straight to notify().
    proposal="$(clean_proposal "$proposal")"

    is_event="$(jq -r '.is_event' <<<"$proposal")"
    needs_human="$(jq -r '.needs_human' <<<"$proposal")"
    title="$(jq -r '.title // "Untitled"' <<<"$proposal")"
    reason="$(jq -r '.reason // ""' <<<"$proposal")"

    if [[ "$is_event" != "true" ]]; then
        jq -c . <<<"$proposal" > "${rec}/proposal.json" 2>/dev/null || true
        archive_record "$id" "$rec" not_event "${reason:-}"
        log "  not an event: ${reason:-(no reason given)}"
        notify "No event found" low "camera" "${reason:-That screenshot did not look like an event.}"
        continue
    fi

    if [[ "$needs_human" == "true" ]]; then
        # Keep the image AND the proposal: this is the branch a human has to
        # adjudicate, so preserve what the model actually read.
        jq -c . <<<"$proposal" > "${rec}/proposal.json" 2>/dev/null || true
        archive_record "$id" "$rec" needs_human "${reason:-}"
        log "  needs human: ${title} — ${reason:-(no reason given)}"
        notify "Needs a human: ${title}" default "warning,calendar" \
               "${reason:-Time or date unclear — not adding.} (id ${id:0:8})"
        continue
    fi

    # Gate the values before rendering. Runs here rather than straight after ask()
    # because the not_event and needs_human branches above are legitimately allowed
    # to carry a missing or unusable date — only a proposal we are about to turn
    # into a real calendar entry has to survive these checks.
    if ! gate_reason="$(validate_proposal "$proposal")"; then
        jq -c . <<<"$proposal" > "${rec}/proposal.json" 2>/dev/null || true
        archive_record "$id" "$rec" failed "rejected at gate: ${gate_reason}"
        log "  rejected at gate: ${gate_reason}"
        notify "Capture rejected" default "warning,camera" \
               "That screenshot did not produce a usable event (${gate_reason}, id ${id:0:8})."
        continue
    fi

    if ! jq -c . <<<"$proposal" > "${rec}/proposal.json" ||
       ! "${SCRIPT_DIR}/render_ics.py" --uid "$id" --now "$now_z" \
             --duration-min "$DURATION_MIN" <<<"$proposal" > "${rec}/event.ics"; then
        archive_record "$id" "$rec" failed "could not render .ics"
        notify "Capture failed" default "warning,camera" "Could not build the event (id ${id:0:8})."
        continue
    fi

    # One-tap disambiguation: if the model offered another plausible reading,
    # render it too so the alternative button writes a real event rather than
    # kicking off another round-trip. ntfy caps actions at 3, so exactly one
    # alternative can be shown alongside Discard.
    alt_label=""
    if [[ "$(jq -r '.alternatives | length' <<<"$proposal")" -gt 0 ]]; then
        # end_time MUST be reset: the alternatives sub-schema has no end_time, so
        # without this the primary reading's end survives into the alternative. An
        # alt starting later than the primary ended then renders end <= start, and
        # render_ics.py adds a day — a 23-hour event behind a button labelled "15:00".
        alt_json="$(jq -c '.alternatives[0] as $a | . + {date: $a.date, start_time: $a.start_time,
                           end_time: null,
                           location: ($a.location // .location)} | del(.alternatives)' <<<"$proposal")"
        if "${SCRIPT_DIR}/render_ics.py" --uid "$id" --now "$now_z" \
               --duration-min "$DURATION_MIN" <<<"$alt_json" > "${rec}/event.alt.ics" 2>/dev/null; then
            jq -c . <<<"$alt_json" > "${rec}/proposal.alt.json"
            alt_label="$(jq -r '.alternatives[0].label' <<<"$proposal")"
        else
            rm -f "${rec}/event.alt.ics"   # unrenderable alternative: fall back to Add/Discard
        fi
    fi


    # Human-readable "when" for the notification body.
    # Notification body, one fact per line — reads like a calendar entry:
    #   Sunday, 26 July 2026
    #   13:00 - 14:00
    #   5 Everton Park
    #   General
    # Empty fields are omitted rather than printed blank, so an all-day event
    # shows no time line and a locationless one shows no location line.
    ev_date="$(jq -r '.date' <<<"$proposal")"
    ev_start="$(jq -r '.start_time // ""' <<<"$proposal")"
    ev_end="$(jq -r '.end_time // ""' <<<"$proposal")"
    ev_loc="$(jq -r '.location // ""' <<<"$proposal")"
    ev_cal="$(jq -r '.calendar' <<<"$proposal")"
    all_day="$(jq -r '.all_day' <<<"$proposal")"

    # "2026-07-26" -> "Sunday, 26 July 2026" (%-d drops the leading zero)
    body="$(date -d "$ev_date" '+%A, %-d %B %Y' 2>/dev/null || printf '%s' "$ev_date")"

    if [[ "$all_day" == "true" ]]; then
        body+=$'\n'"All day"
    elif [[ -n "$ev_start" ]]; then
        # End time is optional: the model only fills it when the image showed a
        # range or duration, so fall back to a bare start rather than inventing one.
        if [[ -n "$ev_end" ]]; then
            body+=$'\n'"${ev_start} - ${ev_end}"
        else
            body+=$'\n'"${ev_start}"
        fi
    fi
    [[ -n "$ev_loc" ]] && body+=$'\n'"${ev_loc}"
    # Capitalise the calendar name for display: general -> General
    body+=$'\n'"${ev_cal^}"

    if base="$(capture_base_url)"; then
        if [[ -n "$alt_label" ]]; then
            # Primary reading first, then the alternative, then Discard (3 = the cap).
            # Button labels are spliced into a comma/semicolon-delimited Actions
            # header, so a comma or CRLF in either would splice the action list.
            # Whitelist rather than escape: anything unexpected falls back to "Add".
            primary="$(jq -r 'if .all_day then "Add" else (.start_time // "Add") end' <<<"$proposal")"
            [[ "$primary" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || primary="Add"
            [[ "$alt_label" =~ ^[A-Za-z0-9\ :.-]{1,12}$ ]] || alt_label="Alternative"
            actions="http, ${primary}, ${base}/capture/${id}/add, method=POST, headers.X-Capture=1, clear=true; http, ${alt_label}, ${base}/capture/${id}/add?alt=1, method=POST, headers.X-Capture=1, clear=true; http, Discard, ${base}/capture/${id}/drop, method=POST, headers.X-Capture=1, clear=true"
            notify "${title}" default "calendar" "$body" "$actions"
            log "  proposed: ${title} — ${ev_date} ${ev_start:-all day} (alt: ${alt_label})"
        else
            actions="http, Add, ${base}/capture/${id}/add, method=POST, headers.X-Capture=1, clear=true; http, Discard, ${base}/capture/${id}/drop, method=POST, headers.X-Capture=1, clear=true"
            notify "${title}" default "calendar" "$body" "$actions"
            log "  proposed: ${title} — ${ev_date} ${ev_start:-all day}"
        fi
    else
        notify "${title} (no buttons)" high "warning,calendar" \
               "$body. Could not build callback URL; record ${id:0:8} left pending."
        log "  !! could not build capture base url"
    fi
done

log "done"
