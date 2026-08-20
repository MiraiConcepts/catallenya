#!/usr/bin/env bash
# Regression tests for the shared ntfy transport (ntfy/ntfy.lib.sh).
#
# Everything here runs offline and sends nothing: the suite exports NTFY_DISABLE=1,
# and every case below exercises string construction rather than the wire.
#
# This file exists because the transport stopped being four private copies and became
# one shared thing on 2026-08-10. The sanitisers in particular had never had a direct
# test in any of their homes — the pipeline suites only ever grepped the source to
# check they were still being CALLED. Both guard real attacks, so they are tested on
# behaviour here. Run before commit:
#   bash ntfy/tests/run.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NTFY_DISABLE=1
# shellcheck source=../ntfy.lib.sh
source "${SELF_DIR}/../ntfy.lib.sh"
# shellcheck source=../../ai/scripts/ai.lib.sh
source "/zpool/catallenya/ai/scripts/ai.lib.sh"

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$3" "$2"; }
has()  { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "contains $3" "$2"; }
hasnt(){ [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "must not contain $3" "$2"; }

# ------------------------------------------------------------------ sanitisers
# hdr_safe guards an HTTP header. A CR/LF in a title injects a SECOND Actions
# header, and Go's Header.Get returns the FIRST — so the injected buttons REPLACE
# the real ones and a tap POSTs wherever the attacker chose. Titles are untrusted on
# every pipeline: a screenshot can show anything, a filename arrives over Syncthing.
echo "hdr_safe"
is "strips CR"                  "$(hdr_safe $'a\rb')" "ab"
is "strips LF"                  "$(hdr_safe $'a\nb')" "ab"
is "kills a header injection"   "$(hdr_safe $'Title\r\nActions: http, Add, https://evil/')" \
                                "TitleActions: http, Add, https://evil/"
hasnt "no newline survives"     "$(hdr_safe $'x\r\ny')" $'\n'
long="$(hdr_safe "$(printf 'a%.0s' {1..500})")"
is "caps length at 200"         "${#long}" "200"
is "empty input is empty"       "$(hdr_safe "")" ""
is "missing arg is empty"       "$(hdr_safe)" ""

# md_escape guards a RENDERED body. Bodies go out with Markdown on, so a
# [tap here](https://evil.example) lifted from a document or a screenshot would
# become a real link inside a notification the owner already trusts.
echo "md_escape"
is "escapes a link"      "$(md_escape '[tap](https://evil)')" '\[tap\]\(https://evil\)'
is "escapes underscores" "$(md_escape 'photo_2026_08.jpg')"   'photo\_2026\_08.jpg'
is "escapes asterisks"   "$(md_escape '*bold*')"              '\*bold\*'
is "backslash first"     "$(md_escape '\*')"                  '\\\*'
is "leaves plain text"   "$(md_escape 'tax-invoice.pdf')"     'tax-invoice.pdf'
is "empty is empty"      "$(md_escape "")"                    ""

# ntfy_id_safe: the id reaches ntfy as BOTH a header value and a URL path segment.
echo "ntfy_id_safe"
is "keeps a uuid"        "$(ntfy_id_safe '8f3a91c2-0000-4aaa-bbbb-ccccdddd')" '8f3a91c2-0000-4aaa-bbbb-ccccdddd'
is "drops a slash"       "$(ntfy_id_safe 'a/b')"   'ab'
is "bare traversal empties" "$(ntfy_id_safe '..')" ''
is "leading dots go"     "$(ntfy_id_safe '..x')"   'x'

# ------------------------------------------------------------------- the shape
echo "paused_title"
is "plural by default"   "$(paused_title 3 Document)"   "Model Paused: 3 Documents"
is "singular at one"     "$(paused_title 1 Document)"   "Model Paused: 1 Document"
is "zero is plural"      "$(paused_title 0 Document)"   "Model Paused: 0 Documents"
is "noun is the caller's" "$(paused_title 2 Screenshot)" "Model Paused: 2 Screenshots"

echo "paused_body"
b="$(paused_body "Out of credits" "moved to bin/ in 7 days" one two three)"
has "numbers the items"      "$b" '1\. one'
has "and keeps going"        "$b" '3\. three'
hasnt "no summary under cap" "$b" "more"
has "reason then outcome"    "$b" "_Out of credits. Retrying daily — moved to bin/ in 7 days._"
# REGRESSION: `local n=... shown="$n"` reads the OUTER n, because bash expands every
# right-hand side in one `local` before assigning any of them. That shipped for
# exactly one run of this file and printed the summary line with no items at all.
has "items actually render"  "$b" '2\. two'

b8="$(paused_body "Out of credits" "x" a b c d e f g h)"
has "caps the list at five"  "$b8" '5\. e'
hasnt "and stops there"      "$b8" '6\.'
has "counts what it omitted" "$b8" "… and 3 more"

bx="$(paused_body "Out of credits" "x" 'lab_report.pdf' '[tap](https://evil)')"
has "escapes an item"        "$bx" 'lab\_report.pdf'
has "an item cannot inject a link" "$bx" '\[tap\]\(https://evil\)'

# ------------------------------------------------- one outage, one wording
# The point of the shared shape: the same failure must read identically wherever it
# lands. Only the noun and the day-7 clause may differ, and the reason line comes
# from ai_reason() so no consumer can author its own.
echo "identical across pipelines"
r="$(ai_reason 3)"
pig="$(paused_body "$r" "moved to bin/ in 7 days, nothing is deleted" a)"
aft="$(paused_body "$r" "archived in 7 days, and the screenshots go with them" a)"
is "same reason clause" \
   "$(grep -o 'Out of credits\. Retrying daily' <<<"$pig")" \
   "$(grep -o 'Out of credits\. Retrying daily' <<<"$aft")"
is "reason is not the caller's to write" "$r" "Out of credits"
is "a timeout reads differently"         "$(ai_reason 2)" "The API is unreachable"

# ------------------------------------------------- paused_sync choreography
# paused_sync is proven by SHADOWING notify/retract inside a subshell: the shadows
# print the argv they receive, so the assertions read the exact choreography — what
# was retracted, what was published, in what order — with no wire involved. The
# real functions stay muted underneath (NTFY_DISABLE=1) in case a shadow is missed.
echo "paused_sync"
sync_trace() {
    (
        retract() { printf 'RETRACT %s\n' "${1:-}"; }
        notify()  { printf 'NOTIFY title=[%s] prio=[%s] tags=[%s] actions=[%s] id=[%s]\n%s\n' \
                        "${1:-}" "${2:-}" "${3:-}" "${5:-}" "${6:-}" "${4:-}"; }
        paused_sync "$@"
    )
}

# The CAUSE is the fourth argument, between the reason and the outcome clause: it
# becomes the bracket on the title, while the reason stays in the body sentence.
t="$(sync_trace pause-1 Document "Out of credits" Unpaid "moved to bin/ in 7 days" a.pdf b.pdf)"
is  "retract fires first, before any publish" "$(head -n1 <<<"$t")" "RETRACT pause-1"
has "then the summary, count and noun threaded" "$t" "title=[Model Paused: 2 Documents [Unpaid]]"
has "default priority — nothing shouts"  "$t" "prio=[]"
has "the one deliberate glyph"           "$t" "tags=[warning]"
has "no buttons on a summary"            "$t" "actions=[]"
has "replacement rides the SAME id"      "$t" "id=[pause-1]"
has "items reach paused_body"            "$t" '1\. a.pdf'
has "reason and outcome too, in its own arg order" "$t" \
    "_Out of credits. Retrying daily — moved to bin/ in 7 days._"

# The fix itself: the run that finds nothing paused still retracts — this is what
# takes "Paused: N …" off the phone when the outage ends — and publishes nothing.
# Both triages used to skip the retract with the branch, so the summary rotted.
t0="$(sync_trace pause-1 Document "" "")"
is    "resolved outage: retract still happens" "$t0" "RETRACT pause-1"
hasnt "and no replacement is published"        "$t0" "NOTIFY"
is    "a bare id is enough to withdraw"        "$(sync_trace pause-1)" "RETRACT pause-1"

# An empty id would publish a summary nothing can ever withdraw; the call declines.
te="$(sync_trace "" Document "Out of credits" "x" a.pdf 2>/dev/null)"
is "no id: nothing retracted, nothing published" "$te" ""

# ------------------------------------------------------------------- _ntfy_env
# The extractor is shared and the KEY LISTS are not: afterimage and pigeonhole each
# wrap this with the one extra key their own callbacks need. What is pinned here is
# that the wrapping is possible at all — an extra key is read, and an extra key that
# is missing is the caller's problem rather than a failed transport.
#
# It reads the real /zpool/catallenya/.env, which is the file production reads and
# the same one every notify() in the other suites already goes through. Nothing is
# asserted about its CONTENTS beyond the three keys the transport itself requires.
echo "_ntfy_env"
env_probe() { ( unset SYNCTHING_REVERSE_PROXY_PORT; _ntfy_env "$@" >/dev/null 2>&1 \
                && printf '%s' "${SYNCTHING_REVERSE_PROXY_PORT:-unset}" ); }
is "an extra key is extracted" "$(env_probe SYNCTHING_REVERSE_PROXY_PORT)" \
   "$(grep -m1 '^SYNCTHING_REVERSE_PROXY_PORT=' /zpool/catallenya/.env | cut -d= -f2-)"
is "and is not read unless asked for"   "$(env_probe)"                    "unset"
is "an absent extra key is not fatal"   "$(_ntfy_env NO_SUCH_KEY_IN_ENV; echo rc=$?)" "rc=0"
# The trio IS asserted, because notify() builds a URL out of it and an unset
# component yields a syntactically valid but dead "https://host.ts.net:".
fn="$(sed -n '/^_ntfy_env() {/,/^}/p' "${SELF_DIR}/../ntfy.lib.sh")"
has "the caller's keys ride after the trio" "$fn" 'NTFY_REVERSE_PROXY_PORT "$@"'
has "and the trio is still required"        "$fn" 'NTFY_REVERSE_PROXY_PORT:-'
# Both wrappers are one line naming one key. A union list here would be a contract
# nobody wrote, and the next pipeline would silently inherit it.
for w in /zpool/catallenya/afterimage/scripts/afterimage.lib.sh \
         /zpool/catallenya/pigeonhole/scripts/pigeonhole.lib.sh; do
    is "$(basename "$w" .lib.sh) wraps it with its own key" \
       "$(grep -c '^_load_env() { _ntfy_env [A-Z_]* *; *}$' "$w")" "1"
done

# ------------------------------------------------------------------ mute seam
echo "mute seam"
is "the suite is muted"  "$(ntfy_muted && echo yes)" "yes"
# shellcheck disable=SC2034  # read by notify()/retract() in the sourced lib
NTFY_TOPIC=test-topic
is "notify is a no-op when muted"  "$(notify "t" "" tag "body"; echo rc=$?)" "rc=0"
is "retract is a no-op when muted" "$(retract deadbeef; echo rc=$?)"          "rc=0"
is "retract declines an empty id"  "$(retract ""; echo rc=$?)"                "rc=0"

# ------------------------------------------------------------------ constructors
# The SNAPSHOT. There is no `systemctl cat` for a message — nothing can say what a
# title will look like without running the code — so this is the merged view: one
# rendering per shape, asserted byte-for-byte. If a constructor changes, this is what
# tells you which titles moved.
echo "title constructors"
is "count, plural"        "$(title_count Staged 3 Document)"        "Staged: 3 Documents"
is "count, singular"      "$(title_count Blocked 1 Document)"       "Blocked: 1 Document"
is "the digit survives"   "$(title_count Binned 1 Document)"        "Binned: 1 Document"
is "a multi-word verb"    "$(title_count "Model Failed" 1 Screenshot)" "Model Failed: 1 Screenshot"
is "a name replaces the count" "$(title_count Flagged 1 Event Kene)" "Flagged: Kene"
is "a nudge carries its age"   "$(title_count "Still Staged" 3 Document "" "$(title_age 31)")" \
                               "Still Staged: 3 Documents [1d]"
is "state, counted"       "$(title_state Watchdog "3 Findings")"    "Watchdog: 3 Findings"
is "state, bare"          "$(title_state Backup Succeeded)"         "Backup: Succeeded"
is "an identifier keeps its case" "$(title_state zpool "78% Full")" "zpool: 78% Full"
is "state with a mark"    "$(title_state Backup Failed "$(title_mark restic)")" \
                          "Backup: Failed [restic]"
is "a bare quotation"     "$(title_quote Kene)"                     "Kene"
is "a quotation with a position" "$(title_quote Kene "$(title_pos 2 4)")" "Kene [2/4]"
is "a lone event has no position" "$(title_quote Kene "$(title_pos 1 1)")" "Kene"
is "a quotation nudges by age"   "$(title_quote Kene "$(title_age 31)")"  "Kene [1d]"

# The age scale. Coarse because both pipelines nudge exactly once and the nightly
# sweep pins the value between 24h and 48h — a precise number would report sweep
# timing rather than urgency.
echo "title_age"
is "hours below a day"  "$(title_age 6)"   "[6h]"
is "a day at 24h"       "$(title_age 24)"  "[1d]"
is "still days at 47h"  "$(title_age 47)"  "[1d]"
is "weeks past a fortnight" "$(title_age 400)" "[2w]"

# Rule 14: the cap exists so WE choose what survives, and the verb is never it.
echo "truncation"
long_title="$(title_count Finished 1 Track "Godspeed You! Black Emperor - Storm (Live at the Fillmore)")"
has   "the verb survives"        "$long_title" "Finished: "
has   "and the name is cut"      "$long_title" "…"
is    "at the cap"               "${#long_title}" "40"
hasnt "no three-dot ellipsis"    "$long_title" "..."
short="$(title_count Finished 1 Track "Artist - Track")"
is    "a short name is untouched" "$short" "Finished: Artist - Track"
# A bracket must never be what gets cut: it carries the position or the age.
marked="$(title_quote "A Really Very Long Event Title That Overruns" "$(title_pos 2 4)")"
has   "a bracket survives truncation" "$marked" "[2/4]"

# ------------------------------------------------------------------ paused cause
# paused_cause matches ai_reason()'s OUTPUT, which lives in another file. Asserting
# against ai_reason() directly rather than against a copy of its wording is what
# stops the two drifting: change the sentence there and this fails here.
echo "paused cause"
is "rc 3 is unpaid"       "$(paused_cause "$(ai_reason 3)")"                  "Unpaid"
is "rc 2 is unreachable"  "$(paused_cause "$(ai_reason 2)")"                  "Unreachable"
is "both at once is mixed" "$(paused_cause "$(ai_reason 2)" "$(ai_reason 3)")" "Mixed"
is "an unknown reason names nothing" "$(paused_cause "Something else entirely")" ""
is "no reasons name nothing"         "$(paused_cause)"                         ""
is "the title carries the cause" \
   "$(paused_title 3 Document "$(paused_cause "$(ai_reason 3)")")" \
   "Model Paused: 3 Documents [Unpaid]"
is "and reads as the model class"    "$(paused_title 1 Screenshot)" "Model Paused: 1 Screenshot"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
