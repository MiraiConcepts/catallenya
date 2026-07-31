#!/usr/bin/env bash
# shellcheck disable=SC2034  # config vars are consumed by the scripts that source this
# Shared Anthropic Messages API layer. Sourced, never executed.
#
# This is the one place in the repo that talks to api.anthropic.com. Two consumers
# today, both bash, both on this host:
#
#   capture/scripts/capture.triage.sh   screenshot -> proposed calendar event
#   syncthing/scripts/documents.intake.classify.sh   document page -> filing decision
#
# WHY A LIBRARY AND NOT A SERVICE. The capture pipeline splits into a dumb container
# (HTTP + CalDAV PUT) and a host-side triage that holds the intelligence, and the
# split was kept specifically so the API-calling half could serve future non-capture
# consumers. Documents is that consumer — but it is bash on the same box, so the
# cheapest correct boundary is `source`, not a port. Standing up an HTTP service
# instead would put the API key in a container's environment 24/7 (readable via
# `docker inspect`, and to anything with code execution in it) rather than injected
# per-run by systemd into a ProtectSystem=strict oneshot that exits, and it would
# need its own auth gate on an internal port that ~26 containers can reach.
# api_post() is deliberately the single seam: if a non-bash consumer ever appears,
# wrapping THIS function in a container is a contained change, not a rewrite.
#
# CONTRACT for anything sourcing this file:
#   - ANTHROPIC_API_KEY must be set (systemd EnvironmentFile=/etc/ai.env).
#   - jq, curl, base64 and od must exist. Assert that in the entrypoint script, not
#     here — a missing binary should fail the run loudly and once, not per-item.
#   - Source this at the TOP of your own lib, before your own log()/die(). The
#     definitions below are guarded, so yours wins and stays authoritative.
#
# There is no `tools` key in any request built here, so the model has no tool surface
# and no path to the filesystem. That is a property of the plain /v1/messages
# endpoint, not something these scripts have to arrange.

# log/die are guarded: both consumer libs define their own identical versions and
# source this first, so theirs win. The fallbacks exist so a future consumer that
# defines neither still gets sane output out of api_post.
declare -F log >/dev/null || log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
declare -F die >/dev/null || die() { log "FATAL: $*"; exit 1; }

# Transient API failure handling. In-process retries cover a rate limit or a brief
# 5xx; anything longer (an auth outage, a provider incident) outlives the run and is
# the caller's problem: capture leaves the record in pending/ for the sweep to
# re-queue, documents records CLASSIFY_FAILED and declines to memoize it so the next
# nightly run retries (commit 5ab987a).
API_MAX_ATTEMPTS=3        # attempts within one run
API_RETRY_BASE_S=5        # linear backoff: 5s, 10s
# Overridable so the retry path is testable against a local sink without spending an
# API call — same seam as MIN_AGE_SECONDS in documents.lib.sh. Never set in
# production; the default is the only value systemd ever runs with.
API_URL="${API_URL:-https://api.anthropic.com/v1/messages}"

# --- images ----------------------------------------------------------------

# image_mime <file> -> image/png | image/jpeg   (by content, never by filename)
# Callers cannot be trusted about extensions: capture's spool name is always .png
# because that is the glob token capture.triage.path keys on, whatever the bytes
# actually are. A wrong media_type is an API-level error, so this is sniffed.
# Anything unrecognised falls back to image/png.
image_mime() {
    case "$(od -An -tx1 -N3 "$1" 2>/dev/null | tr -d ' \n')" in
        ffd8ff) echo image/jpeg ;;
        *)      echo image/png  ;;
    esac
}

# image_ext <file> -> png | jpg
image_ext() {
    case "$(image_mime "$1")" in image/jpeg) echo jpg ;; *) echo png ;; esac
}

# --- request construction --------------------------------------------------

# ai_build_request <out-file> <model> <effort> <max-tokens> <schema-json> <prompt> [image...]
#
# Writes a complete /v1/messages body to <out-file>. Images first, prompt text last;
# N images accepted (capture sends 1 screenshot, documents sends up to MAX_PAGES
# rasterised pages).
#
# EVERYTHING carrying base64 goes via a FILE, never a command-line argument. One page
# is ~270KB of base64 and three is ~800KB, well past ARG_MAX; a screenshot is ~1MB.
# This bit documents.intake three times during its original build ("Argument list too
# long"), first on --arg and then on --argjson for the accumulated array. Both the
# per-image blob AND the growing content array must be file-passed; --rawfile and
# --slurpfile are the tools. Do not "simplify" this into a shell variable.
#
# Scratch goes to mktemp's default. Both callers run under PrivateTmp=true, so that
# is a private tmpfs systemd destroys on exit — a stronger guarantee than a directory
# wiped by an EXIT trap. A manual run outside systemd lands in the real /tmp and is
# cleaned below on every path.
ai_build_request() {
    local out="$1" model="$2" effort="$3" max_tokens="$4" schema="$5" prompt="$6"
    shift 6
    local b64f contentf tmpf img n=0 rc
    b64f="$(mktemp)"; contentf="$(mktemp)"; tmpf="$(mktemp)"
    echo '[]' > "$contentf"

    for img in "$@"; do
        [[ -n "$img" && -f "$img" ]] || continue
        base64 -w0 "$img" > "$b64f"
        # -c is REQUIRED throughout: the API is fine either way, but the accumulator
        # below re-reads this file with --slurpfile and jq's default pretty-printing
        # turns a one-object file into something that still parses but costs a
        # needless multi-MB rewrite per page.
        jq -c --rawfile b64 "$b64f" --arg mime "$(image_mime "$img")" \
            '. + [{type: "image",
                   source: {type: "base64", media_type: $mime,
                            data: ($b64 | rtrimstr("\n"))}}]' \
            "$contentf" > "$tmpf" && mv "$tmpf" "$contentf"
        n=$((n + 1))
    done

    if (( n == 0 )); then
        log "  !! ai_build_request: no readable images"
        rm -f "$b64f" "$contentf" "$tmpf"
        return 1
    fi

    # thinking:adaptive + output_config.format json_schema is the shape validated in
    # the 2026-07-24 bake-off: the reply is a schema-constrained object rather than
    # prose to parse, so there is no malformed-JSON retry path to get wrong.
    jq -n --slurpfile c "$contentf" --arg prompt "$prompt" \
          --argjson schema "$schema" --arg model "$model" \
          --arg effort "$effort" --argjson max_tokens "$max_tokens" \
        '{model: $model,
          max_tokens: $max_tokens,
          thinking: {type: "adaptive"},
          output_config: {effort: $effort,
                          format: {type: "json_schema", schema: $schema}},
          messages: [{role: "user",
                      content: ($c[0] + [{type: "text", text: $prompt}])}]}' > "$out"
    rc=$?

    rm -f "$b64f" "$contentf" "$tmpf"
    return "$rc"
}

# --- transport -------------------------------------------------------------

# api_class <http-status> -> ok | retry | fatal
# "000" means curl never completed the exchange (DNS, TLS, timeout, reset).
# Lives here rather than inline in api_post so the tests assert the real mapping
# instead of a copy of it that can drift.
api_class() {
    case "$1" in
        200)          echo ok ;;
        429|5??|000)  echo retry ;;   # rate limited, server-side, or no answer
        *)            echo fatal ;;   # 400/401/403/404: retrying cannot help
    esac
}

# api_post <request-body-file> -> response body on stdout
#   0 = ok | 1 = fatal (do not retry) | 2 = transient, attempts exhausted
#
# ANTHROPIC_API_KEY must be set by the caller.
#
# The key goes via a curl config on stdin, never argv: /proc is mounted without
# hidepid here, so /proc/<pid>/cmdline is world-readable for the whole call.
#
# -f is deliberately NOT used. It collapses every failure into exit 22 and throws
# away the response body, which makes a rate limit indistinguishable from a bad
# API key — and a caller that treats both as terminal destroys the input on a single
# blip. The status code is what decides whether to retry.
api_post() {
    local msgf="$1" out code body attempt=0 delay
    while :; do
        attempt=$((attempt + 1))
        out="$(curl -sS -K - --max-time 180 -w $'\n%{http_code}' 2>&1 <<CURLRC
url = "${API_URL}"
header = "x-api-key: ${ANTHROPIC_API_KEY}"
header = "anthropic-version: 2023-06-01"
header = "content-type: application/json"
data-binary = "@${msgf}"
CURLRC
)"
        code="${out##*$'\n'}"
        body="${out%$'\n'*}"
        # Normalise "curl never completed the exchange" (DNS, TLS, timeout, reset)
        # to 000, which api_class treats as transient.
        [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"

        case "$(api_class "$code")" in
            ok)
                printf '%s' "$body"
                return 0 ;;
            retry)
                if (( attempt >= API_MAX_ATTEMPTS )); then
                    log "  !! api unavailable after ${attempt} attempts (last: ${code}) — will retry later"
                    return 2
                fi
                delay=$(( API_RETRY_BASE_S * attempt ))
                log "  api ${code}, attempt ${attempt}/${API_MAX_ATTEMPTS} — retrying in ${delay}s"
                sleep "$delay"
                ;;
            *)
                log "  !! api rejected the request (${code}): $(tail -c 300 <<<"$body")"
                return 1 ;;
        esac
    done
}

# --- response ---------------------------------------------------------------

# ai_extract <api-response> -> the structured object on stdout, non-zero on failure
#
# A refusal or a truncated reply is not a usable answer — fail loudly rather than
# handing malformed JSON to a renderer or a filing decision. With
# output_config.format the first text block IS the JSON object, so there is nothing
# to scrape out of prose.
ai_extract() {
    local resp="$1" stop
    stop="$(jq -r '.stop_reason // "?"' <<<"$resp" 2>/dev/null)"
    case "$stop" in
        end_turn) ;;
        refusal)    log "  !! model refused"; return 1 ;;
        max_tokens) log "  !! truncated (max_tokens) — raise MAX_TOKENS"; return 1 ;;
        *)          log "  !! unexpected stop_reason=$stop"; return 1 ;;
    esac
    jq -e -c 'first(.content[]? | select(.type=="text") | .text) | fromjson' <<<"$resp" 2>/dev/null \
        || { log "  !! no structured object in reply"; return 1; }
}
