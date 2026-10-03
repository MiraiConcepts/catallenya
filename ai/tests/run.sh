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
# always .png — it is the glob token afterimage.triage.path keys on — so format must
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

# --------------------------------------------------------------- out of credits
# The state this layer was missing. An account that cannot pay is neither of the two
# things the loop already knew about: it is not `retry`, because no amount of waiting
# fixes it, and it is not `fatal`, because the request was never wrong — it becomes
# runnable again the moment the balance is topped up. Calling it fatal is what makes
# capture archive a perfectly good screenshot and prune the image a week later.
r="$(run_post 403:billing_error)"
is    "403 billing_error gives rc=3 (paused)" "${r%%|*}" "3"
hasnt "out of credits is never retried"       "$r" "attempt 1/3"
has   "the log names the reason"              "$r" "billing_error"

r="$(run_post 402)"
is "402 gives rc=3 (paused)" "${r%%|*}" "3"

# THE DISCRIMINATOR IS THE BODY, NOT THE STATUS. A revoked key and an empty balance
# both arrive as 403; collapsing them is what sends you off to check an API key that
# is perfectly fine while the real fix is a billing page.
r="$(run_post 403:permission_error)"
is "403 permission_error stays rc=1 (fatal)" "${r%%|*}" "1"

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

# The body is an OPTIONAL second argument, so every call above keeps working. These
# pin the cases where it changes the answer.
is "402 is paused"                   "$(api_class 402)" "paused"
is "403 + billing_error is paused"   \
   "$(api_class 403 '{"error":{"type":"billing_error"}}')"    "paused"
is "403 + permission_error is fatal" \
   "$(api_class 403 '{"error":{"type":"permission_error"}}')" "fatal"
is "403 with no body stays fatal"    "$(api_class 403)" "fatal"

# Anthropic has also reported an exhausted balance as a 400 invalid_request_error
# whose MESSAGE carries the reason. Matching prose is not something to be happy
# about, but the phrase is specific and the cost of missing it is a destroyed item,
# so it is worth a narrow substring. The pair below is what stops it over-matching.
is "400 about the credit balance is paused" \
   "$(api_class 400 '{"error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API."}}')" \
   "paused"
is "400 for a genuinely bad request stays fatal" \
   "$(api_class 400 '{"error":{"type":"invalid_request_error","message":"messages: roles must alternate"}}')" \
   "fatal"

# A body must never perturb a code the loop already classifies on its own.
is "body does not disturb a retryable code" \
   "$(api_class 429 '{"error":{"type":"rate_limit_error"}}')" "retry"
is "body does not disturb a success"        \
   "$(api_class 200 '{"stop_reason":"end_turn"}')" "ok"

# ------------------------------------------------------------ model selection
# The model is resolved per run (owner, 2026-10-03): newest Opus by created_at,
# falling back to the last model that answered. Every case here drives the REAL
# ai_resolve_model / api_post against the sink, with the state files in scratch —
# the defaults point at systemd/state/, which a test must never write.
echo "model selection"

AI_MODEL_STATE="${TMP}/ai-model"
AI_MODEL_REJECTED_STATE="${TMP}/ai-model-rejected"

# The real kinds, so the titles and bodies are the ones the phone would get, with
# notify() replaced by a recorder. Defined after sourcing, so ours wins.
# shellcheck source=../../ntfy/ntfy.lib.sh
source "${SELF_DIR}/../../ntfy/ntfy.lib.sh"
NOTES="${TMP}/notes"
notify() { printf '%s|%s\n' "$1" "$(tr '\n' ' ' <<<"$2")" >> "$NOTES"; }

# A listing shaped like /v1/models: deliberately NOT in created_at order, plus a
# newer non-Opus and a newer Opus that cannot take images — neither may be chosen.
cap() { # $1 images $2 AI_EFFORT $3 schema
    printf '{"image_input":{"supported":%s},"effort":{"%s":{"supported":%s}},"structured_outputs":{"supported":%s}}' "$1" "$AI_EFFORT" "$2" "$3"
}
MODELS="$(jq -nc --argjson y "$(cap true true true)" --argjson noimg "$(cap false true true)" '{data:[
  {id:"claude-opus-5",      created_at:"2026-05-01T00:00:00Z", capabilities:$y},
  {id:"claude-opus-5-5",    created_at:"2026-08-01T00:00:00Z", capabilities:$y},
  {id:"claude-opus-4-8",    created_at:"2026-02-01T00:00:00Z", capabilities:$y},
  {id:"claude-sonnet-9",    created_at:"2027-01-01T00:00:00Z", capabilities:$y},
  {id:"claude-opus-text",   created_at:"2027-02-01T00:00:00Z", capabilities:$noimg},
  {id:"claude-opus-nocaps", created_at:"2027-03-01T00:00:00Z"}]}')"

start_sink() { # $1 = codes; SINK_* come from the caller's environment
    : > "${TMP}/port"
    python3 "${SELF_DIR}/sink.py" "$1" > "${TMP}/port" &
    SINK_PID=$!
    for _ in $(seq 20); do [[ -s "${TMP}/port" ]] && break; sleep 0.2; done
    SINK_URL="http://127.0.0.1:$(cat "${TMP}/port")/"
}
stop_sink() { kill "$SINK_PID" 2>/dev/null; wait "$SINK_PID" 2>/dev/null; SINK_PID=""; }

resolve() { # -> the model chosen; resets the once-per-run guard
    unset _AI_MODEL_RESOLVED
    AI_MODEL="$AI_MODEL_DEFAULT"
    MODELS_URL="$SINK_URL" ai_resolve_model 2>/dev/null
    printf '%s' "$AI_MODEL"
}

SINK_MODELS="$MODELS" start_sink 200
is "picks the newest capable Opus by created_at" "$(resolve)" "claude-opus-5-5"
_AI_MODEL_RESOLVED=1; AI_MODEL="sentinel"; MODELS_URL="$SINK_URL" ai_resolve_model 2>/dev/null
is "resolves once per run"                       "$AI_MODEL" "sentinel"
stop_sink

start_sink 200   # no SINK_MODELS: the listing answers 404
rm -f "$AI_MODEL_STATE"
is "lookup failed, nothing remembered -> default" "$(resolve)" "$AI_MODEL_DEFAULT"
echo "claude-opus-remembered" > "$AI_MODEL_STATE"
is "lookup failed -> the last model that worked"  "$(resolve)" "claude-opus-remembered"
stop_sink
SINK_MODELS='{"data":[]}' start_sink 200
is "no candidate at all -> remembered, not empty"  "$(resolve)" "claude-opus-remembered"
stop_sink
echo 'bad name; rm -rf /' > "$AI_MODEL_STATE"
unset _AI_MODEL_RESOLVED; MODELS_URL="http://127.0.0.1:9/" ai_resolve_model 2>/dev/null
is "a corrupt memory is ignored, never sent"       "$AI_MODEL" "$AI_MODEL_DEFAULT"

post_model() { # $1 model $2 codes, SINK_REJECT_MODEL from env -> "<rc>|<answering model>"
    local rc=0 out
    start_sink "$2"
    jq -nc --arg m "$1" '{model:$m}' > "${TMP}/m.json"
    out="$(API_URL="$SINK_URL" api_post "${TMP}/m.json" 2>"${TMP}/err")" || rc=$?
    stop_sink
    printf '%s|%s' "$rc" "$(jq -r '.model // ""' <<<"$out" 2>/dev/null)"
}

# First success with nothing remembered: recorded, and silent — nothing to compare.
rm -f "$AI_MODEL_STATE" "$AI_MODEL_REJECTED_STATE" "$NOTES"
is "first success answers"              "$(post_model claude-opus-5-5 200)" "0|claude-opus-5-5"
is "first success is remembered"        "$(cat "$AI_MODEL_STATE")" "claude-opus-5-5"
is "first success is silent"            "$(cat "$NOTES" 2>/dev/null)" ""

# A different model answering: remembered, and announced once.
post_model claude-opus-6 200 >/dev/null
is "a new model is remembered"          "$(cat "$AI_MODEL_STATE")" "claude-opus-6"
has "and announced"                     "$(cat "$NOTES")" "Model: Changed|• Now claude-opus-6 • Was claude-opus-5-5"
post_model claude-opus-6 200 >/dev/null
is "announced once, not per item"       "$(wc -l < "$NOTES")" "1"

# THE FALLBACK. The newest model rejects the format; the remembered one is tried
# once, answers, and the item survives instead of being archived as failed.
echo "claude-opus-6" > "$AI_MODEL_STATE"; rm -f "$NOTES"
r="$(SINK_REJECT_MODEL=claude-opus-7 post_model claude-opus-7 200)"
is  "rejected by the newest -> answered by the remembered" "$r" "0|claude-opus-6"
has "the fallback is logged"            "$(cat "${TMP}/err")" "claude-opus-7 rejected the request — retrying once on claude-opus-6"
has "the rejection is notified"         "$(cat "$NOTES")" "claude-opus-7: Rejected|• Using claude-opus-6 instead"
is  "the memory stays on the model that works" "$(cat "$AI_MODEL_STATE")" "claude-opus-6"
SINK_REJECT_MODEL=claude-opus-7 post_model claude-opus-7 200 >/dev/null
is  "rejection notified once per model" "$(wc -l < "$NOTES")" "1"

# The guards that keep a genuinely bad request failing exactly as before.
r="$(SINK_REJECT_MODEL=claude-opus-6 post_model claude-opus-6 200)"
is  "the remembered model itself rejected -> fatal, no retry" "$r" "1|"
hasnt "and nothing was retried"         "$(cat "${TMP}/err")" "retrying once"
r="$(post_model claude-opus-7 401)"
is  "a fatal both models share stays fatal" "${r%%|*}" "1"
r="$(post_model claude-opus-7 503,503,503)"
is  "a parked request never falls back" "${r%%|*}" "2"
hasnt "parked: no fallback attempted"   "$(cat "${TMP}/err")" "retrying once"
rm -f "$AI_MODEL_STATE"
r="$(SINK_REJECT_MODEL=claude-opus-7 post_model claude-opus-7 200)"
is  "nothing remembered -> nothing to fall back to" "$r" "1|"

# High, deliberately: a misread costs a human round-trip.
is "effort default is high"             "$AI_EFFORT" "high"
is "default model is an Opus"           "${AI_MODEL_DEFAULT#"$AI_MODEL_FAMILY"}" "5-5"

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
