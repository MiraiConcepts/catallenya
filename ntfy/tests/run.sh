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
is "plural by default"   "$(paused_title 3 Document)"   "Paused: 3 Documents"
is "singular at one"     "$(paused_title 1 Document)"   "Paused: 1 Document"
is "zero is plural"      "$(paused_title 0 Document)"   "Paused: 0 Documents"
is "noun is the caller's" "$(paused_title 2 Screenshot)" "Paused: 2 Screenshots"

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

# ------------------------------------------------------------------ mute seam
echo "mute seam"
is "the suite is muted"  "$(ntfy_muted && echo yes)" "yes"
# shellcheck disable=SC2034  # read by notify()/retract() in the sourced lib
NTFY_TOPIC=test-topic
is "notify is a no-op when muted"  "$(notify "t" "" tag "body"; echo rc=$?)" "rc=0"
is "retract is a no-op when muted" "$(retract deadbeef; echo rc=$?)"          "rc=0"
is "retract declines an empty id"  "$(retract ""; echo rc=$?)"                "rc=0"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
