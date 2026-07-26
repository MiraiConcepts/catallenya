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
out="$(clean_proposal "$(mut ".title=\"AB${CR}C\" | .reason=\"line1${CR}line2\"")")"
hasnt "control chars stripped from title"  "$(jq -r .title  <<<"$out")" "$CR"
hasnt "control chars stripped from reason" "$(jq -r .reason <<<"$out")" "$CR"
is    "title otherwise intact"             "$(jq -r .title  <<<"$out")" "ABC"

out="$(clean_proposal "$(mut '.title="'"$(printf 'x%.0s' {1..600})"'"')")"
is "long title capped at 500" "$(jq -r '.title|length' <<<"$out")" "500"

out="$(clean_proposal "$(mut '.title="Café ☕"')")"
is "unicode survives cleaning" "$(jq -r .title <<<"$out")" "Café ☕"

out="$(clean_proposal "$(mut '.location=null|.description=null')")"
is "nulls stay null" "$(jq -r '[.location,.description]|map(type)|join(",")' <<<"$out")" "null,null"

# --------------------------------------------------------------------- result
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
