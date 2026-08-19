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

t="$(sync_trace pause-1 Document "Out of credits" "moved to bin/ in 7 days" a.pdf b.pdf)"
is  "retract fires first, before any publish" "$(head -n1 <<<"$t")" "RETRACT pause-1"
has "then the summary, count and noun threaded" "$t" "title=[Paused: 2 Documents]"
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
