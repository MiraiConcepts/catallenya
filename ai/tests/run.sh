#!/usr/bin/env bash
# Regression tests for the shared Anthropic API layer (ai/scripts/ai.lib.sh).
#
# Everything here runs offline and free. The transport cases drive the real
# api_post loop against a local sink (sink.py) rather than the real endpoint, so a
# 429 can be summoned on demand; the request/response cases are pure bash+jq.
#
# These were capture's tests until documents.intake became the second consumer.
# They live here now because the code does — a copy in each consumer's suite is
# exactly the drift this extraction removes. Run before commit:
#   bash ai/tests/run.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SELF_DIR}/../scripts" && pwd)"
# shellcheck source=../scripts/ai.lib.sh
source "${LIB_DIR}/ai.lib.sh"

PASS=0 FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$3" "$2"; }
has()  { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "contains $3" "$2"; }
hasnt(){ [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "must not contain $3" "$2"; }

TMP="$(mktemp -d)"
SINK_PID=""
cleanup() { [[ -n "$SINK_PID" ]] && kill "$SINK_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# --------------------------------------------------------------- image sniffing
# Android (ColorOS) screenshots are JPEG, not PNG, and capture's spool filename is
# always .png — it is the glob token capture.triage.path keys on — so format must
# come from the bytes. A wrong media_type is an API-level error.
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

# ------------------------------------------------------------ request building
echo "ai_build_request"

SCHEMA='{"type":"object","additionalProperties":false,
         "properties":{"ok":{"type":"boolean"}},"required":["ok"]}'
REQ="${TMP}/req.json"

# Single image — capture's shape.
ai_build_request "$REQ" "test-model" "medium" 4096 "$SCHEMA" "the prompt" \
    "${IMGD}/png.bin" 2>/dev/null
is "single image: valid JSON"   "$(jq -e . "$REQ" >/dev/null 2>&1; echo $?)" "0"
is "single image: 1 image block" \
   "$(jq '[.messages[0].content[] | select(.type=="image")] | length' "$REQ")" "1"
is "model passed through"       "$(jq -r .model "$REQ")"                  "test-model"
is "effort passed through"      "$(jq -r .output_config.effort "$REQ")"   "medium"
is "max_tokens is a number"     "$(jq -r '.max_tokens | type' "$REQ")"    "number"
is "thinking is adaptive"       "$(jq -r .thinking.type "$REQ")"          "adaptive"
is "format is json_schema"      "$(jq -r .output_config.format.type "$REQ")" "json_schema"
is "schema is embedded"         "$(jq -r '.output_config.format.schema.properties.ok.type' "$REQ")" "boolean"
# No tools key, ever. This is what makes the containment argument true rather than
# arranged: a plain /v1/messages request has no tool surface to lock down.
is "no tools key"               "$(jq -r 'has("tools")' "$REQ")"          "false"

# Multi-image — documents' shape (up to MAX_PAGES rasterised pages). Page order
# must survive, and the prompt must come LAST: a cover sheet on page 1 is the
# reason documents sends three pages at all, so ordering is load-bearing.
ai_build_request "$REQ" "test-model" "high" 2048 "$SCHEMA" "the prompt" \
    "${IMGD}/png.bin" "${IMGD}/exif.bin" "${IMGD}/jfif.bin" 2>/dev/null
is "three images: 3 image blocks" \
   "$(jq '[.messages[0].content[] | select(.type=="image")] | length' "$REQ")" "3"
is "text block is last" \
   "$(jq -r '.messages[0].content[-1].type' "$REQ")" "text"
is "prompt text survives" \
   "$(jq -r '.messages[0].content[-1].text' "$REQ")" "the prompt"
# media_type comes from magic bytes per image, NOT from one sniff reused for all.
is "per-image media_type: page 1 png" \
   "$(jq -r '.messages[0].content[0].source.media_type' "$REQ")" "image/png"
is "per-image media_type: page 2 jpeg" \
   "$(jq -r '.messages[0].content[1].source.media_type' "$REQ")" "image/jpeg"

# Unreadable paths are skipped, not fatal — but an all-empty list must fail rather
# than POST a request with no images and burn a call on nothing.
ai_build_request "$REQ" "m" "low" 512 "$SCHEMA" "p" \
    "${IMGD}/png.bin" "/nonexistent/page2.png" 2>/dev/null
is "missing page is skipped" \
   "$(jq '[.messages[0].content[] | select(.type=="image")] | length' "$REQ")" "1"
ai_build_request "$REQ" "m" "low" 512 "$SCHEMA" "p" "/nonexistent/x.png" 2>/dev/null
is "no readable images is an error" "$?" "1"

# THE ARG_MAX TRAP. Linux caps a single argv entry at MAX_ARG_STRLEN (128KB),
# far below the 2MB total. Passing base64 via --arg blew up three times during
# documents.intake's original build; --rawfile is why it doesn't now. 512KB of
# source is ~700KB of base64, comfortably past the ceiling.
head -c 524288 /dev/urandom > "${IMGD}/big.bin"
printf '\211PNG\r\n\032\n' | dd of="${IMGD}/big.bin" conv=notrunc status=none
ai_build_request "$REQ" "m" "low" 512 "$SCHEMA" "p" "${IMGD}/big.bin" 2>/dev/null
is "700KB payload builds (ARG_MAX)" "$?" "0"
is "700KB payload is intact" \
   "$(jq -r '.messages[0].content[0].source.data | length > 600000' "$REQ")" "true"
rm -rf "$IMGD"

# ---------------------------------------------------------- response extraction
echo "ai_extract"

body() { jq -nc --arg t "$1" '{stop_reason: $t, content: [{type:"text", text:"{\"ok\":true}"}]}'; }

out="$(ai_extract "$(body end_turn)" 2>/dev/null)"
is "end_turn yields the object" "$(jq -r .ok <<<"$out")" "true"

ai_extract "$(body refusal)" >/dev/null 2>&1
is "refusal is rejected" "$?" "1"
ai_extract "$(body max_tokens)" >/dev/null 2>&1
is "truncation is rejected" "$?" "1"
ai_extract "$(body pause_turn)" >/dev/null 2>&1
is "unknown stop_reason is rejected" "$?" "1"

# A stop_reason of end_turn is not enough: the text block still has to parse. This
# is the difference between "the API succeeded" and "we got an answer".
err="$(ai_extract '{"stop_reason":"end_turn","content":[{"type":"text","text":"sorry, no"}]}' 2>&1 >/dev/null)"
is  "non-JSON text is rejected"      "$?" "1"
has "non-JSON says why"              "$err" "no structured object"
ai_extract '{"stop_reason":"end_turn","content":[]}' >/dev/null 2>&1
is "empty content is rejected" "$?" "1"

# Thinking blocks precede the answer on an adaptive-thinking reply. The extractor
# must take the first TEXT block, not content[0].
out="$(ai_extract '{"stop_reason":"end_turn","content":[
        {"type":"thinking","thinking":""},
        {"type":"text","text":"{\"ok\":true}"}]}' 2>/dev/null)"
is "skips leading thinking block" "$(jq -r .ok <<<"$out")" "true"

# --------------------------------------------------------------- retry, live
# Drives the real api_post loop against a local sink. This is the only way to prove
# the retry behaves — a genuine 429 cannot be summoned on demand, and the failure it
# guards against (one blip destroying the input) is the expensive kind.
echo "api_post retry against a local sink"

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

export ANTHROPIC_API_KEY="sk-ant-sink-not-a-real-key"
API_RETRY_BASE_S=1   # keep the suite fast; the loop multiplies by attempt number
echo '{}' > "${TMP}/post.json"

run_post() { # $1 = sink script -> "<rc>|<stderr log>|<body>"
    local port rc out err
    : > "${TMP}/port"
    python3 "${SELF_DIR}/sink.py" "$1" > "${TMP}/port" &
    SINK_PID=$!
    for _ in $(seq 20); do [[ -s "${TMP}/port" ]] && break; sleep 0.2; done
    port="$(cat "${TMP}/port")"
    rc=0
    out="$(API_URL="http://127.0.0.1:${port}/" api_post "${TMP}/post.json" 2>"${TMP}/err")" || rc=$?
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

# api_class is the REAL function from ai.lib.sh, not a copy — if the mapping in the
# retry loop changes, these fail.
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
is "in-run attempts bounded" "$(( API_MAX_ATTEMPTS > 1 && API_MAX_ATTEMPTS <= 5 ))" "1"
is "backoff is non-zero"     "$(( API_RETRY_BASE_S > 0 ))" "1"

# ----------------------------------------------------------------- key hygiene
# The key must never reach argv: /proc is mounted without hidepid on this host, so
# /proc/<pid>/cmdline is world-readable for the duration of the call. curl reads it
# from a config on stdin instead. Asserting the source line is weak, but it catches
# a silent rewrite to -H.
src="$(cat "${LIB_DIR}/ai.lib.sh")"
has   "curl reads config from stdin" "$src" 'curl -sS -K -'
hasnt "key is not an -H argument"    "$src" '-H "x-api-key'

# --------------------------------------------------------------------- result
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
