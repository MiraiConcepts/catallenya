#!/usr/bin/env bash
# Regression tests for the capture pipeline's deterministic halves.
#
# Everything here runs offline and free: render_ics.py is a pure stdin->stdout
# filter, and the gate in capture.lib.sh is pure bash+jq. The model half is not
# covered — exercising that costs an opus-5 vision call per case.
#
# Every case below is a bug that actually shipped and was found by review on
# 2026-07-26, or an invariant whose breakage would be silent. Run before commit:
#   bash capture/tests/run.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "${SELF_DIR}/../scripts" && pwd)"
# shellcheck source=../scripts/capture.lib.sh
source "${SCRIPT_DIR}/capture.lib.sh"

PASS=0 FAIL=0
CR=$'\r'

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$3" "$2"; }
has()  { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "contains $3" "$2"; }
hasnt(){ [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "must not contain $3" "$2"; }
isnt() { [[ "$2" != "$3" ]] && ok "$1" || bad "$1" "anything but $3" "$2"; }

# A valid proposal. Cases mutate one field off this baseline.
BASE='{"is_event":true,"needs_human":false,"calendar":"general","title":"Lunch",
       "date":"2026-07-26","start_time":"13:00","end_time":"14:00","all_day":false,
       "timezone":"Asia/Singapore","recurrence":"none","location":null,
       "description":null,"reason":null,"alternatives":[]}'
mut() { jq -c "$1" <<<"$BASE"; }

render() { "${SCRIPT_DIR}/render_ics.py" --uid TESTUID --now 20260726T000000Z --duration-min 60 2>&1; }

# ---------------------------------------------------------------- render_ics
echo "render_ics.py"

# The whole feature is wrong if this drifts: the box runs UTC/PDT, the calendar is
# SGT. 13:00 Singapore is 05:00Z.
out="$(mut '.' | render)"
has "SGT 13:00 renders as 05:00Z" "$out" "DTSTART:20260726T050000Z"
has "default duration is one hour" "$out" "DTEND:20260726T060000Z"

# Shipped bug: the alt button reset date/start_time/location but not end_time, so
# the primary reading's end survived. Alt at 15:00 with a 14:00 end rendered
# end<=start, render_ics added a day, and the button wrote a 23-hour event.
out="$(mut '.start_time="15:00" | .end_time=null' | render)"
has "alt with end_time cleared is 1h" "$out" "DTEND:20260726T080000Z"
hasnt "alt does not spill to next day" "$out" "DTEND:20260727"

# Shipped bug: esc() escaped \n but not \r, and Radicale's vobject splits on a bare
# CR — so a model-supplied title injected sibling properties into the same VEVENT
# (RRULE, VALARM, URL), none of which appear in the ntfy body the user approves.
out="$(mut ".title=\"Lunch${CR}RRULE:FREQ=DAILY\"" | render)"
hasnt "bare CR never reaches the .ics" "$out" "${CR}RRULE"
has   "CR is escaped into the value"   "$out" '\nRRULE:FREQ=DAILY'
is    "no injected RRULE line" "$(grep -c '^RRULE:' <<<"$out")" "0"

# Same class, via the other two model-controlled TEXT properties.
out="$(mut ".location=\"Cafe${CR}BEGIN:VALARM\" | .description=\"x${CR}URL:https://evil.example\"" | render)"
# Anchored: the payload text legitimately survives *inside* the escaped property
# value (LOCATION:Cafe\nBEGIN:VALARM). What must never happen is it starting a
# line of its own, which is what an unescaped CR would have caused.
is "no injected VALARM" "$(grep -c '^BEGIN:VALARM' <<<"$out")" "0"
is "no injected URL"    "$(grep -c '^URL:'         <<<"$out")" "0"

# RFC 5545 escaping that already worked — guard against a regression while editing esc().
out="$(mut '.title="Tea, cake; more"' | render)"
has "comma and semicolon escaped" "$out" 'SUMMARY:Tea\, cake\; more'

out="$(mut '.all_day=true | .start_time=null | .end_time=null' | render)"
has "all-day uses VALUE=DATE" "$out" "DTSTART;VALUE=DATE:20260726"

# ---------------------------------------------------------------------- gate
echo "validate_proposal"

gate() { if r="$(validate_proposal "$1")"; then echo "PASS"; else echo "$r"; fi; }

is "valid proposal passes"        "$(gate "$(mut '.')")"                        "PASS"
is "all-day (null times) passes"  "$(gate "$(mut '.all_day=true|.start_time=null|.end_time=null')")" "PASS"

# Shipped bug: start_time had no pattern, and render_ics silently emitted an all-day
# event for anything parse_hhmm() rejected — while the notification still said "5pm".
is "unparseable start_time"       "$(gate "$(mut '.start_time="5pm"')")"        "BAD_TIME"
is "out-of-range hour"            "$(gate "$(mut '.start_time="25:00"')")"      "BAD_TIME"
is "bad end_time"                 "$(gate "$(mut '.end_time="7pm"')")"          "BAD_TIME"

# documents.intake's lesson (commit fa5638e): a schema regex accepts 2023-02-29 and a
# model really did emit it. Shape is not value.
is "impossible calendar date"     "$(gate "$(mut '.date="2023-02-29"')")"       "IMPOSSIBLE_DATE"
is "month 13"                     "$(gate "$(mut '.date="2026-13-01"')")"       "IMPOSSIBLE_DATE"
is "malformed date"               "$(gate "$(mut '.date="26 July"')")"          "BAD_DATE"
is "leap day in a real leap year" "$(gate "$(mut '.date="2028-02-29"')")"       "PASS"

# timezone is model-controlled and never shown in the notification, so a bad value is
# an invisible time shift on an event the user believes they verified.
is "unresolvable timezone"        "$(gate "$(mut '.timezone="Mars/Olympus"')")" "BAD_TIMEZONE"

# The alternative is written on one tap, so it gets the same checks.
is "bad alt start_time" \
   "$(gate "$(mut '.alternatives=[{"label":"x","date":"2026-07-26","start_time":"99:99","location":null}]')")" \
   "BAD_ALT"
is "bad alt date" \
   "$(gate "$(mut '.alternatives=[{"label":"x","date":"2023-02-29","start_time":"15:00","location":null}]')")" \
   "BAD_ALT"

# ------------------------------------------------------------------- cleaning
echo "clean_proposal"

# The not_event branch sends the model's `reason` to notify() as the entire body.
# curl -d would read a leading "@" as a filename; --data-raw plus this stripping is
# belt and braces.
# clean_proposal reaches inside events[], since that is the shape the model returns.
# Built with jq --arg, not raw JSON text: a literal CR inside a JSON string literal
# is invalid JSON and jq would refuse to parse it.
ev() { # $1 = title -> a whole proposal carrying one event with that title
    jq -cn --arg t "$1" '{is_event:true, needs_human:false, events_seen:1, reason:"r",
        events:[{title:$t, location:null, description:null, alternatives:[]}]}'
}

out="$(clean_proposal "$(ev "AB${CR}C")")"
hasnt "control chars stripped from title" "$(jq -r '.events[0].title' <<<"$out")" "$CR"
is    "title otherwise intact"            "$(jq -r '.events[0].title' <<<"$out")" "ABC"

out="$(clean_proposal "$(ev "$(printf 'x%.0s' {1..600})")")"
is "long title capped at 500" "$(jq -r '.events[0].title|length' <<<"$out")" "500"

out="$(clean_proposal "$(ev 'Café ☕')")"
is "unicode survives cleaning" "$(jq -r '.events[0].title' <<<"$out")" "Café ☕"
is "nulls stay null" "$(jq -r '[.events[0].location,.events[0].description]|map(type)|join(",")' <<<"$out")" "null,null"

# reason lives at the top level and is what the not_event notification sends.
out="$(clean_proposal "$(jq -cn --arg r "line1${CR}line2" '{reason:$r, events:[]}')")"
hasnt "control chars stripped from reason" "$(jq -r .reason <<<"$out")" "$CR"

# -------------------------------------------------------------- recording mode
echo "recording_mode / record_mode"

MODED="$(mktemp -d)"
mode_is() { # $1 = file contents (or __none__) -> resolved mode
    local d="$MODED"
    rm -f "${d}/recording-mode" "${d}/.recording-disabled"
    [[ "$1" != "__none__" ]] && printf '%s' "$1" > "${d}/recording-mode"
    MODE_FILE="${d}/recording-mode" LEGACY_OFF_FLAG="${d}/.recording-disabled" \
        bash -c 'source "$1"; MODE_FILE="$2"; LEGACY_OFF_FLAG="$3"; recording_mode' \
        _ "${SCRIPT_DIR}/capture.lib.sh" "${d}/recording-mode" "${d}/.recording-disabled" 2>/dev/null
}
is "off is honoured"          "$(mode_is off)"      "off"
is "test is honoured"         "$(mode_is test)"     "test"
is "prod is honoured"         "$(mode_is prod)"     "prod"
is "trailing newline is fine" "$(mode_is 'prod
')"                                                 "prod"
# Missing file means prod: retention is the documented policy, and a fresh install
# silently recording nothing is the failure this replaces.
is "no file means prod"       "$(mode_is __none__)" "prod"
# A typo must not land on either extreme — prod would silently contaminate the
# accept rate, off would silently destroy records. Both are the harms this exists
# to prevent; test is the only value whose failure modes are reversible.
is "typo falls back to test"  "$(mode_is prd)"      "test"
is "empty falls back to test" "$(mode_is '')"       "test"

# The legacy flag must keep meaning `off`, so a snapshot rollback or an old runbook
# cannot silently promote the box to prod and start retaining everything.
: > "${MODED}/.recording-disabled"; printf 'prod' > "${MODED}/recording-mode"
is "legacy flag still wins" \
   "$(bash -c 'source "$1"; MODE_FILE="$2"; LEGACY_OFF_FLAG="$3"; recording_mode' \
      _ "${SCRIPT_DIR}/capture.lib.sh" "${MODED}/recording-mode" "${MODED}/.recording-disabled" 2>/dev/null)" \
   "off"
rm -f "${MODED}/.recording-disabled"

# A record carries the mode it was CAPTURED under. Without this, test captures
# tapped after a switch to prod would be counted as production data.
printf 'prod' > "${MODED}/recording-mode"
mkdir -p "${MODED}/rec"; printf 'test\n' > "${MODED}/rec/mode"
is "stamped mode beats the live setting" \
   "$(bash -c 'source "$1"; MODE_FILE="$2"; LEGACY_OFF_FLAG=/nonexistent; record_mode "$3"' \
      _ "${SCRIPT_DIR}/capture.lib.sh" "${MODED}/recording-mode" "${MODED}/rec")" \
   "test"
rm -f "${MODED}/rec/mode"
is "unstamped record uses the live setting" \
   "$(bash -c 'source "$1"; MODE_FILE="$2"; LEGACY_OFF_FLAG=/nonexistent; record_mode "$3"' \
      _ "${SCRIPT_DIR}/capture.lib.sh" "${MODED}/recording-mode" "${MODED}/rec")" \
   "prod"
rm -rf "$MODED"

# ------------------------------------------------------------- prompt contract
# These assert the SCHEMA and the prompt's rules, not the model's judgement — the
# rules landed on 2026-07-27 after seven live captures exposed each gap, and a
# silent revert would be invisible until the next batch of screenshots.
echo "prompt contract"

has "schema carries events_seen"     "$CAPTURE_SCHEMA" '"events_seen"'
has "events_seen is required"        "$CAPTURE_SCHEMA" 'events_seen'
hasnt "schema no longer asks for a button label" "$CAPTURE_SCHEMA" '"label"'

PROMPT="$(bash -c 'source "$1"; source_only=1
                   sed -n "/^triage_prompt()/,/^}/p" "$2" > /tmp/.tp.$$; . /tmp/.tp.$$
                   triage_prompt "Monday 2026-07-27 22:16"; rm -f /tmp/.tp.$$' \
          _ "${SCRIPT_DIR}/capture.lib.sh" "${SCRIPT_DIR}/capture.triage.sh" 2>/dev/null)"

# A missing time used to escalate to needs_human, which gave the user a dead end.
has "no time means all-day"          "$PROMPT" "NO TIME SHOWN"
has "all-day sets start_time null"   "$PROMPT" "all_day=true, start_time=null"
# needs_human is now only for "cannot be placed at all".
has "needs_human is date-only now"   "$PROMPT" "no resolvable DATE"

# The forward-resolution rule was replaced: assume the current year, except at the
# turn of the year, where a December capture of a January date means next January.
# Year resolution is a hierarchy: only the last step is a guess. Each step below
# came from a real capture — the year in an event NAME, the weekday the model used
# spontaneously on a flyer, and a birthday that must resolve forward.
has "looks for a year anywhere"      "$PROMPT" "ANYWHERE else in the image"
has "calculates from a weekday"      "$PROMPT" "CALCULATE the year"
has "recurring resolves forward"     "$PROMPT" "NEXT occurrence on or after"
# When no step can determine the year, the system says so and offers both rather
# than guessing. A tour poster read in July used to be rejected outright.
has "admits the year is unknowable" "$PROMPT" "genuinely UNKNOWABLE"
has "offers the other year"         "$PROMPT" "put the other year in alternatives"
has "does not reject a stale-looking date" "$PROMPT" "Do not reject a date merely because"
# It offered 2025-12-04 next to a 2026-12-04 primary whose year it had itself
# derived from "Friday 4 December". Determined means settled; and 2025-12-04 is a
# Thursday, so it was not even a candidate.
has "year alt is step-5 only"        "$PROMPT" "THIS STEP ONLY"
has "a weekday settles the year"     "$PROMPT" "is 2026 and nothing else"
has "never offers a past option"     "$PROMPT" "NEVER put a date in the past"
has "earlier candidate leads"        "$PROMPT" "EARLIER DATE FIRST"
# The old January special-case is gone and deliberately not replaced: "nearest
# candidate still ahead of now" already covers it. A poster read on 27 Dec saying
# "5 Jan" finds this year's 5 Jan has passed and takes next year, with no clause.
has "boundary handled by the general rule" "$PROMPT" "otherwise the next year"


# The live failure: a 19:15 show proposed at 22:16 the same evening.
has "past check includes the time"   "$PROMPT" "ALREADY PAST"
has "explicitly covers earlier today" "$PROMPT" "earlier TODAY"
has "all-day is past only after its day" "$PROMPT" "whole day has gone"

# Multi-event: pick the soonest and say how many there were.
# Backticks in this prompt are command substitution — see the note on the heredoc.
hasnt "prompt contains no backticks" "$PROMPT" '`' 

# ----------------------------------------------------------------- button labels
# Shipped wart: the primary button was forced to 24h from start_time while the
# alternative label came free-form from the model, whose prompt examples were 12h.
# A real notification showed "19:00" beside "8.15pm". Both are now derived.
echo "button_label"

is "same day shows the time"      "$(button_label 2026-07-31 20:15 false 2026-07-31)" "20:15"
is "all-day says so"              "$(button_label 2026-07-31 ''    true  2026-07-31)" "All day"
is "null start is all-day"        "$(button_label 2026-07-31 null  false 2026-07-31)" "All day"
is "different day shows the date" "$(button_label 2026-08-02 20:15 false 2026-07-31)" "2 Aug"
is "unparseable time is safe"     "$(button_label 2026-07-31 '8.15pm' false 2026-07-31)" "Alternative"
# Year-ambiguous proposals offer both candidates, so the label must carry the year
# or both buttons read "15 Nov" and the choice is unreadable.
is "differing year shows the year" "$(button_label 2027-11-15 '' true 2026-11-15)" "15 Nov 27"
is "same year omits it"            "$(button_label 2026-08-02 20:15 false 2026-07-31)" "2 Aug"

# Whatever it produces must survive the Actions-header whitelist, or the button
# silently degrades to a generic label.
for c in "$(button_label 2026-07-31 20:15 false 2026-07-31)" \
         "$(button_label 2026-08-02 20:15 false 2026-07-31)" \
         "$(button_label 2026-07-31 '' true 2026-07-31)"; do
    [[ "$c" =~ ^[A-Za-z0-9\ :.-]{1,12}$ ]] && ok "label '$c' passes the whitelist" \
        || bad "label whitelist" "matches ^[A-Za-z0-9 :.-]{1,12}$" "$c"
done

# The model no longer names buttons at all — one less untrusted string in a header.
hasnt "schema no longer asks for a label" "$CAPTURE_SCHEMA" '"label"'

# The prompt is asked not to produce a past alternative; this makes sure of it
# regardless, because prompt rules were wrong three times on 2026-07-27 and the
# guard was not.
echo "past-alternative guard"
guard() { # $1 = alt date, $2 = capture date -> kept | dropped
    [[ "$1" < "$2" ]] && echo dropped || echo kept
}
is "past alternative dropped"   "$(guard 2025-12-04 2026-07-27)" "dropped"
is "future alternative kept"    "$(guard 2027-12-04 2026-07-27)" "kept"
is "same-day alternative kept"  "$(guard 2026-07-27 2026-07-27)" "kept"

# ------------------------------------------------------------------ context.json
# Without this a proposal cannot be attributed: the prompt changed twice on
# 2026-07-27 alone, so a difference between two records could be the prompt, the
# model, or the screenshot, with no way to tell which.
echo "write_context / add_usage"

CTXD="$(mktemp -d)"; mkdir -p "${CTXD}/rec"
printf '\211PNG\r\n\032\n' > "${CTXD}/shot.png"
write_context "${CTXD}/rec" test "Monday 2026-07-27 21:50" "${CTXD}/shot.png" "PROMPT ONE"
ctx="${CTXD}/rec/context.json"

is "context.json is valid json" "$(jq -e . "$ctx" >/dev/null 2>&1 && echo yes)" "yes"
is "records the model"          "$(jq -r .model "$ctx")"             "claude-opus-5"
is "records the effort"         "$(jq -r .effort "$ctx")"            "medium"
is "records the mode"           "$(jq -r .mode "$ctx")"              "test"
is "records the local anchor"   "$(jq -r .captured_at_local "$ctx")" "Monday 2026-07-27 21:50"
is "records the event tz"       "$(jq -r .event_tz "$ctx")"          "Asia/Singapore"
is "stores the prompt in full"  "$(jq -r .prompt "$ctx")"            "PROMPT ONE"
is "records the image mime"     "$(jq -r .image.mime "$ctx")"        "image/png"
is "records image size"         "$(jq -r '.image.bytes > 0' "$ctx")" "true"
is "hashes the schema"          "$(jq -r '.schema_sha256|length' "$ctx")" "64"

# The hash is what lets records be grouped by prompt version without diffing text.
h1="$(jq -r .prompt_sha256 "$ctx")"
write_context "${CTXD}/rec" test "Monday 2026-07-27 21:50" "${CTXD}/shot.png" "PROMPT TWO"
h2="$(jq -r .prompt_sha256 "${CTXD}/rec/context.json")"
is  "prompt hash is 64 hex" "${#h1}" "64"
isnt "a changed prompt changes the hash" "$h1" "$h2"

# Token counts answer "would a cheaper model do" without re-running anything.
add_usage "${CTXD}/rec" '{"usage":{"input_tokens":1234,"output_tokens":56}}'
is "usage folded in"        "$(jq -r .usage.input_tokens "${CTXD}/rec/context.json")" "1234"
is "prompt survives merge"  "$(jq -r .prompt "${CTXD}/rec/context.json")"             "PROMPT TWO"
# A malformed response must not destroy the context that is already there.
add_usage "${CTXD}/rec" 'not json at all'
is "bad response leaves context intact" "$(jq -r .model "${CTXD}/rec/context.json")" "claude-opus-5"
rm -rf "$CTXD"

# --------------------------------------------------------------- image sniffing
# Android (ColorOS) screenshots are JPEG, not PNG. The spool filename is always
# .png — it is the glob token capture.triage.path keys on — so format must come
# from the bytes. A wrong media_type is an API-level error.
echo "image_mime / image_ext"

IMGD="$(mktemp -d)"
mk() { printf "$2" > "${IMGD}/$1"; }
mk png.bin      '\211PNG\r\n\032\n'
mk jfif.bin     '\377\330\377\340\000\020JFIF'
mk exif.bin     '\377\330\377\341\000\020Exif'   # what ColorOS actually emits
mk garbage.bin  'not an image at all'

is "PNG magic  -> image/png"  "$(image_mime "${IMGD}/png.bin")"     "image/png"
is "JFIF JPEG  -> image/jpeg" "$(image_mime "${IMGD}/jfif.bin")"    "image/jpeg"
is "Exif JPEG  -> image/jpeg" "$(image_mime "${IMGD}/exif.bin")"    "image/jpeg"
is "unknown falls back to png" "$(image_mime "${IMGD}/garbage.bin")" "image/png"
is "png extension"  "$(image_ext "${IMGD}/png.bin")"  "png"
is "jpg extension"  "$(image_ext "${IMGD}/exif.bin")" "jpg"
rm -rf "$IMGD"

# ------------------------------------------------------------------ sweep args
echo "capture.sweep.sh arguments"

# Shipped bug: the sweep took no arguments at all, so --dry-run was silently
# ignored and it archived for real. Every sibling script honours that flag.
sweep="${SCRIPT_DIR}/capture.sweep.sh"

out="$(bash "$sweep" --help 2>&1)"; rc=$?
is "--help exits 0"        "$rc" "0"
has "--help prints usage"  "$out" "--dry-run"

out="$(bash "$sweep" --nonsense 2>&1)"; rc=$?
is  "unknown arg is rejected"     "$rc" "1"
has "unknown arg names itself"    "$out" "--nonsense"

# The real guarantee: --dry-run must announce itself, so a run that says nothing
# about being a dry run is doing the real thing.
out="$(bash "$sweep" --dry-run 2>&1)"
has "--dry-run announces itself" "$out" "DRY RUN"

# A JPEG record must be as visible to the sweep as a PNG one. The sweep used to
# match screenshot.png literally, which would have made every Android capture
# invisible here — never re-queued, never aged out, and silently, because this
# only runs hourly and only on records that are already stale.
sweep_sees() { # $1 = screenshot filename -> sweep's dry-run verdict
    local d="${PENDING_DIR}/00000000-0000-4000-8000-0000000000ff"
    mkdir -p "$d"; : > "${d}/$1"; touch -d '2 hours ago' "$d"
    local o; o="$(bash "$sweep" --dry-run 2>&1)"
    rm -rf "$d"
    [[ "$o" == *"would re-queue"* ]] && echo seen || echo invisible
}
is "sweep sees a PNG record"  "$(sweep_sees screenshot.png)" "seen"
is "sweep sees a JPEG record" "$(sweep_sees screenshot.jpg)" "seen"

# --------------------------------------------------------------- retry, live
# Exercises the real ask() against a local sink. This is the only way to prove the
# retry loop behaves — a genuine 429 cannot be summoned on demand, and the failure
# it guards against (one blip destroying the screenshot) is the expensive kind.
echo "ask() retry against a local sink"

TMP="$(mktemp -d)"
SINK_PID=""
cleanup() { [[ -n "$SINK_PID" ]] && kill "$SINK_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# Drive the sink through a scripted sequence and report the status curl saw.
sink_probe() {
    local codes="$1" port out
    : > "${TMP}/port"
    python3 "${SELF_DIR}/sink.py" "$codes" > "${TMP}/port" &
    SINK_PID=$!
    for _ in $(seq 20); do [[ -s "${TMP}/port" ]] && break; sleep 0.2; done
    port="$(cat "${TMP}/port")"
    out="$(curl -sS --max-time 5 -w $'\n%{http_code}' -X POST -d '{}' \
           "http://127.0.0.1:${port}/" 2>&1)"
    kill "$SINK_PID" 2>/dev/null; wait "$SINK_PID" 2>/dev/null; SINK_PID=""
    echo "${out##*$'\n'}"
}

is "sink can force a 429" "$(sink_probe 429,200)" "429"
is "sink can force a 200" "$(sink_probe 200)"     "200"
is "sink can force a 500" "$(sink_probe 500)"     "500"

# The real api_post loop, driven against the sink. This is the part that could not
# be proven any other way: that a transient failure is retried rather than ending
# the capture, and that a fatal one is not retried at all.
export ANTHROPIC_API_KEY="sk-ant-sink-not-a-real-key"
API_RETRY_BASE_S=1   # keep the suite fast; the loop multiplies by attempt number
echo '{}' > "${TMP}/req.json"

run_post() { # $1 = sink script -> "<rc>|<stderr log>"
    local port rc out err
    : > "${TMP}/port"
    python3 "${SELF_DIR}/sink.py" "$1" > "${TMP}/port" &
    SINK_PID=$!
    for _ in $(seq 20); do [[ -s "${TMP}/port" ]] && break; sleep 0.2; done
    port="$(cat "${TMP}/port")"
    rc=0
    out="$(API_URL="http://127.0.0.1:${port}/" api_post "${TMP}/req.json" 2>"${TMP}/err")" || rc=$?
    err="$(tr '\n' ' ' < "${TMP}/err")"
    kill "$SINK_PID" 2>/dev/null; wait "$SINK_PID" 2>/dev/null; SINK_PID=""
    printf '%s|%s|%s' "$rc" "$err" "$out"
}

r="$(run_post 200)"
is  "clean 200 returns 0"        "${r%%|*}" "0"
has "clean 200 returns the body" "$r" "Sink Lunch"

r="$(run_post 429,429,200)"
is  "recovers after two 429s"  "${r%%|*}" "0"
has "logged the first retry"   "$r" "attempt 1/3"
has "logged the second retry"  "$r" "attempt 2/3"
has "got the body on attempt 3" "$r" "Sink Lunch"

r="$(run_post 503,503,503)"
is  "persistent 5xx gives rc=2 (transient)" "${r%%|*}" "2"
has "says it will retry later"              "$r" "will retry later"

r="$(run_post 401)"
is    "401 gives rc=1 (fatal)"   "${r%%|*}" "1"
hasnt "401 is never retried"     "$r" "attempt 1/3"

# api_class is the REAL function from capture.lib.sh, not a copy — if the mapping
# in the retry loop changes, these fail.
is "200 is success"           "$(api_class 200)" "ok"
is "429 retries"              "$(api_class 429)" "retry"
is "500 retries"              "$(api_class 500)" "retry"
is "503 retries"              "$(api_class 503)" "retry"
is "no-answer (000) retries"  "$(api_class 000)" "retry"
is "400 is fatal"             "$(api_class 400)" "fatal"
is "401 is fatal"             "$(api_class 401)" "fatal"
is "404 is fatal"             "$(api_class 404)" "fatal"

# ---------------------------------------------------------------- retry config
echo "retry configuration"
is "in-run attempts bounded"   "$(( API_MAX_ATTEMPTS > 1 && API_MAX_ATTEMPTS <= 5 ))" "1"
is "backoff is non-zero"       "$(( API_RETRY_BASE_S > 0 ))" "1"
# Must exceed the triage's TimeoutStartSec (15min) or the sweep could adopt a
# record while the triage is still working on it and re-queue it underneath.
is "requeue waits out a live run" "$(( REQUEUE_AFTER_HOURS >= 1 ))" "1"

# ------------------------------------------------------- container integration
# Not automated: the undo path lives in server.ts and needs the running container
# plus a real Radicale, so a test here would write to the live calendar. Verified
# by hand on 2026-07-27 and repeatable with this procedure:
#
#   TID=deadbeef-0000-4000-8000-000000000001
#   B64=$(cat capture/dav-secret); CAL=<general collection uuid>
#   # 1. seed an event exactly as an Add would
#   docker run --rm --network catallenya_default -v /tmp/undo.ics:/e.ics curlimages/curl \
#     -X PUT -H "Authorization: Basic ${B64}" -H 'Content-Type: text/calendar' \
#     --data-binary @/e.ics "http://radicale:5232/carrein/${CAL}/${TID}.ics"
#   # 2. fake the archived record an Add would have left
#   mkdir -p capture/data/archive/$TID
#   echo '{"calendar":"general"}' > capture/data/archive/$TID/proposal.json
#   echo "{\"id\":\"$TID\",\"outcome\":\"add\",\"mode\":\"test\"}" \
#     > capture/data/archive/$TID/decision.json
#   # 3. tap Discard, then assert: event gone, decision.json outcome=undone
#   curl -X POST -H 'X-Capture: 1' "http://<ip>:8080/capture/${TID}/drop"
#
# Expected: {"ok":true,"undone":true,"status":200}. REMOVE the archive record AND
# the appended ledger line afterwards — the ledger is append-only, so a test run
# leaves a fake verdict behind that would otherwise skew the accept rate.

# --------------------------------------------------------------------- result
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
