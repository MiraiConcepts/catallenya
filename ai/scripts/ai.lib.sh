#!/usr/bin/env bash
# shellcheck disable=SC2034  # config vars are consumed by the scripts that source this
# Shared Anthropic Messages API layer. Sourced, never executed.
#
# This is the one place in the repo that talks to api.anthropic.com. Three scripts
# source it, all bash, all on this host — but only two of them call the API:
#
#   afterimage/scripts/afterimage.triage.sh   screenshot -> proposed calendar event
#   pigeonhole/scripts/pigeonhole.triage.sh   document page -> filing decision
#   liquidroom/scripts/liquidroom.lib.sh   md_escape/hdr_safe ONLY — no API call
#
# liquidroom needs no key and touches none of the transport surface; it sources
# this file so the two ntfy sanitisers do not exist as a second drifting copy.
# Editing md_escape or hdr_safe has three consumers, not two.
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

# Shared model configuration. Both pipelines converge on one call shape — a batch
# of images, a prompt, a schema — so they run the same model at the same effort,
# and a model bump is one edit here rather than a hunt through consumers. opus-5
# won the 2026-07-24 capture bake-off (and a sonnet-5 replay over 36 archived
# captures was rejected 2026-07-28); high effort because a misread document or a
# wrong year costs a human round-trip that dwarfs the token delta.
AI_MODEL="claude-opus-5"
AI_EFFORT="high"

# Transient API failure handling. In-process retries cover a rate limit or a brief
# 5xx; anything longer (an auth outage, a provider incident) outlives the run and is
# the caller's problem: capture leaves the record in pending/ for the sweep to
# re-queue, documents records CLASSIFY_FAILED and declines to memoize it so the next
# nightly run retries (commit 5ab987a).
API_MAX_ATTEMPTS=3        # attempts within one run
API_RETRY_BASE_S=5        # linear backoff: 5s, 10s
# Overridable so the retry path is testable against a local sink without spending an
# API call — same seam as MIN_AGE_SECONDS in pigeonhole.lib.sh. Never set in
# production; the default is the only value systemd ever runs with.
API_URL="${API_URL:-https://api.anthropic.com/v1/messages}"

# --- images ----------------------------------------------------------------

# image_mime <file> -> image/png | image/jpeg   (by content, never by filename)
# Callers cannot be trusted about extensions: capture's spool name is always .png
# because that is the glob token afterimage.triage.path keys on, whatever the bytes
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

# api_class <http-status> [response-body] -> ok | retry | paused | fatal
# "000" means curl never completed the exchange (DNS, TLS, timeout, reset).
# Lives here rather than inline in api_post so the tests assert the real mapping
# instead of a copy of it that can drift.
#
# THE BODY IS AN OPTIONAL SECOND ARGUMENT, and it exists for exactly one reason:
# the status code cannot separate an unusable ACCOUNT from an unusable REQUEST. An
# empty credit balance and a revoked key both arrive as 403. Collapsing them is what
# made a billing pause look terminal — afterimage archived a perfectly good
# screenshot as failed and pruned the image a week later, and the notification told
# the owner to go and check an API key that was fine.
#
# `paused` is the third thing a failure can be. It is not `retry`, because no amount
# of waiting fixes an empty balance; it is not `fatal`, because the request was never
# wrong and works again the moment the balance is topped up. Callers park the item
# rather than resolving it.
#
# Every call without a body behaves exactly as it did before this argument existed.
api_class() {
    local code="$1" body="${2:-}" etype msg

    # Status alone settles success and everything retryable. Deciding these first is
    # what keeps a body from ever perturbing a code that was already unambiguous.
    case "$code" in
        200)          echo ok;    return ;;
        429|5??|000)  echo retry; return ;;   # rate limited, server-side, or no answer
    esac

    # 402 is unambiguous on its own — payment required is never a malformed request.
    [[ "$code" == 402 ]] && { echo paused; return; }

    [[ -n "$body" ]] || { echo fatal; return; }

    # The documented discriminator. A 403 carrying billing_error is an account that
    # cannot pay; a 403 carrying permission_error is a key that cannot be used, and
    # those want opposite handling.
    etype="$(jq -r '.error.type // ""' <<<"$body" 2>/dev/null || true)"
    [[ "$etype" == "billing_error" ]] && { echo paused; return; }

    # An exhausted balance has also been reported as a 400 invalid_request_error whose
    # MESSAGE carries the reason. Matching prose is not something to be pleased about,
    # but the phrase is specific, and the cost of missing it is a destroyed item rather
    # than a wrong log line. Narrow on purpose: a genuinely malformed request stays fatal.
    if [[ "$code" == 400 ]]; then
        msg="$(jq -r '.error.message // ""' <<<"$body" 2>/dev/null || true)"
        [[ "${msg,,}" == *"credit balance"* ]] && { echo paused; return; }
    fi

    echo fatal   # 400/401/403/404: retrying cannot help
}

# api_post <request-body-file> -> response body on stdout
#   0 = ok | 1 = fatal (do not retry) | 2 = transient, attempts exhausted
#   3 = paused (the account cannot pay; the request was fine — park, do not resolve)
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

        case "$(api_class "$code" "$body")" in
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
            paused)
                # Deliberately NOT retried in-run: the balance will not change inside
                # three attempts. The body is echoed because "which 403 was it" is the
                # first question anyone reading this line will have.
                log "  !! api unusable — account, not request (${code}): $(tail -c 300 <<<"$body")"
                return 3 ;;
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
# --- sanitising what came back ---------------------------------------------
# These live here rather than in a consumer because they belong to the same
# boundary ai_extract does: everything the model returns is derived from input an
# attacker may control — a screenshot of anything, a document someone else wrote —
# and both consumers push that text into a notification. A copy per consumer is
# how one of them silently misses a fix.

# hdr_safe <string> — make a model-derived string safe to put in an HTTP header.
# Strips CR/LF and caps length. curl forwards raw CR/LF in -H verbatim, so a title
# containing "\r\nActions: http, Add, https://evil/" would inject a SECOND Actions
# header — and Go's Header.Get returns the FIRST, so the injected buttons would
# REPLACE the real ones and the user's tap would POST to the attacker.
hdr_safe() {
    tr -d '\r\n' <<<"${1:-}" | cut -c1-200
}

# md_escape <string> — neutralise Markdown in model-derived text.
# Notifications are sent with `Markdown: yes`, so the body is rendered. A
# `[tap here](https://evil.example)` lifted out of a document or a screenshot would
# otherwise become a REAL link inside a notification the user already trusts — the
# same class as the header injection above, arriving through a renderer that was
# switched on for cosmetic reasons. Emphasis leaking is cosmetic; the link is why
# this exists. Backslash is escaped first, or every other escape doubles wrong.
md_escape() {
    sed -e 's/\\/\\\\/g' -e 's/\([][*_`~()#>|]\)/\\\1/g' <<<"${1:-}"
}

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
