#!/usr/bin/env bash
# shellcheck disable=SC2034  # config vars are consumed by the scripts that source this
# Shared helpers for the capture triage. Sourced, never executed.
#
# Layout mirrors documents.lib.sh: config at the top, .env sourced at call time
# (it is runtime-only and not in the repo), ntfy addressed through the tailnet
# Caddy URL rather than a container name or a hardcoded IP.

CAPTURE_DIR="/zpool/catallenya/capture"
DATA_DIR="${CAPTURE_DIR}/data"
IN_DIR="${DATA_DIR}/incoming"
PENDING_DIR="${DATA_DIR}/pending"
# Every capture ends here once resolved — accepted, rejected, or ignored — with the
# screenshot, the model's proposal and the recorded verdict side by side. That triple
# is a labelled EVAL example — not training data: these models cannot be fine-tuned
# here, so its uses are replaying a new model against recorded verdicts, iterating
# the prompt against real failures, and few-shot examples. Exactly the shape of the
# golden set used for the 2026-07-24 bake-off, but accumulating on its own.
ARCHIVE_DIR="${DATA_DIR}/archive"
# Append-only ledger of the same verdicts, one JSON object per line, for analysis
# without walking the archive (accept rate over time, alt-tap rate, etc).
DECISIONS_LOG="${DATA_DIR}/decisions.jsonl"
# Test taps land here instead. Kept rather than discarded because while a prompt is
# being iterated on, the test verdicts ARE the signal — "did the year fix work" is
# answered from these. A separate file beats one file plus a filter: there is no
# filter to get wrong later, and the production accept rate cannot be contaminated.
DECISIONS_TEST_LOG="${DATA_DIR}/decisions.test.jsonl"

# --- recording mode --------------------------------------------------------
# One word in one file, rather than a pair of negatively-named flags whose
# combinations nobody can hold in their head:
#
#   off    resolved captures are DELETED; nothing is counted
#   test   captures are KEPT; verdicts go to decisions.test.jsonl
#   prod   captures are KEPT; verdicts go to decisions.jsonl
#
#   printf 'test\n' > capture/data/recording-mode
#   cat capture/data/recording-mode      # answers "what am I in" in one line
#
# Read at use time, so changing it needs no restart of anything.
MODE_FILE="${DATA_DIR}/recording-mode"
# Pre-2026-07-27 flag. Kept as a synonym for `off` so that if it ever reappears —
# from a snapshot rollback, an old runbook — it still does the conservative thing
# rather than silently promoting the box to prod and retaining everything.
LEGACY_OFF_FLAG="${DATA_DIR}/.recording-disabled"

# recording_mode -> off | test | prod
# Missing file means prod: retention is the documented policy (user, 2026-07-25),
# and a fresh install silently recording nothing is exactly the failure this
# replaces. The triage logs the active mode every run so it is never invisible.
#
# An unreadable or misspelt value falls back to TEST, not to either extreme. A typo
# landing on prod would silently contaminate the accept rate — the precise harm this
# exists to prevent — and one landing on off would silently destroy records, which
# is unrecoverable. test is the only value whose failure modes are both reversible:
# you keep more than you meant to, and the metric does not move.
recording_mode() {
    [[ -e "$LEGACY_OFF_FLAG" ]] && { echo off; return; }
    [[ -f "$MODE_FILE" ]] || { echo prod; return; }
    local m
    m="$(tr -d '[:space:]' < "$MODE_FILE" 2>/dev/null)"
    case "$m" in
        off|test|prod) echo "$m" ;;
        *) log "  !! unrecognised recording-mode '${m}' — falling back to test"; echo test ;;
    esac
}

# record_mode <record-dir> -> off | test | prod
# The mode a record was CAPTURED under, not the mode in force when the button was
# finally tapped. Without this, ten test captures tapped after a switch to prod are
# counted as production data. Records predating the stamp fall back to the current
# mode, which is the best available answer for them.
record_mode() {
    local f="${1}/mode"
    [[ -f "$f" ]] && tr -d '[:space:]' < "$f" || recording_mode
}
SCRIPT_DIR="${CAPTURE_DIR}/scripts"

NTFY_TOPIC="capture"
MODEL="claude-opus-5"
EFFORT="medium"          # bake-off winner ran adaptive thinking; medium caps spend
EVENT_TZ="Asia/Singapore" # fallback when the screenshot gives no timezone clue
DURATION_MIN=60           # default length when only a start time is known
# Screenshots are retained indefinitely as dataset material (user, 2026-07-25).
# They stay LOCAL: capture/ is deliberately absent from restic's path allowlist,
# so nothing here is copied off-box. ZFS + sanoid still cover disk failure and
# rollback. Do NOT add capture/ to restic without revisiting that decision — a
# screenshot can contain anything that was on screen.
RENOTIFY_AFTER_HOURS=24   # one nudge, in case the first ntfy was never seen
IGNORE_AFTER_HOURS=168    # 7 days untouched -> archive with outcome "ignored"

# Screenshot retention. Outside `off`, Discard no longer deletes, so every capture
# accumulates — and a screenshot can hold anything that was on screen. The dataset
# is for EVALS, not training, and evals want the failures plus a thin slice of the
# rest, not everything forever. So after this many days the IMAGE is deleted from an
# archived record while the proposal, the rendered .ics, the context and the verdict
# stay: those are small, text-only, and carry the analysis value. Records the model
# got wrong keep their image indefinitely — those are the ones worth re-reading.
# 0 disables pruning entirely.
PRUNE_IMAGE_AFTER_DAYS=90
# Outcomes worth keeping the picture for. An add means the model was right and the
# image adds little; a discard or a failure is a case to look at again.
PRUNE_KEEP_IMAGE_OUTCOMES="discard needs_human not_event failed"

# Transient API failure handling. In-process retries cover a rate limit or a brief
# 5xx; anything longer (an auth outage, a provider incident) outlives the run, so
# the record is left in pending/ without a proposal.json and the sweep re-queues
# the screenshot once before giving up. Mirrors documents.intake, which declines to
# memoize CLASSIFY_FAILED so the next nightly run retries it (commit 5ab987a).
API_MAX_ATTEMPTS=3        # attempts within one triage run
API_RETRY_BASE_S=5        # linear backoff: 5s, 10s
# Overridable so the retry path is testable against a local sink without spending
# an API call — same seam as MIN_AGE_SECONDS in documents.lib.sh. Never set in
# production; the default is the only value systemd ever runs with.
API_URL="${API_URL:-https://api.anthropic.com/v1/messages}"

# image_mime <file> -> image/png | image/jpeg   (by content, never by filename)
# The spool name is always .png — it is the glob token capture.triage.path keys on —
# so the extension says nothing about the bytes. A wrong media_type is an API-level
# error, so this is sniffed. Anything unrecognised falls back to image/png; the
# server has already rejected non-PNG/JPEG uploads by signature before this runs.
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

# button_label <date> <start_time> <all_day> <primary-date> -> short button text
# Both buttons are derived from the proposal rather than named by the model. The
# model used to supply the alternative's label, and the prompt's own examples were
# 12-hour ("2:00pm") while the primary is forced to 24-hour from start_time — so a
# notification showed "19:00" next to "8.15pm". Deriving both also removes the last
# model-authored string that reached the ntfy Actions header.
#
# Same date as the primary -> the time is what distinguishes them. Different date ->
# the date is. ntfy truncates long labels, so this stays short by construction.
button_label() {
    local date="$1" start="$2" all_day="$3" primary_date="$4"
    if [[ "$date" != "$primary_date" ]]; then
        date -d "$date" '+%-d %b' 2>/dev/null || printf 'Alternative'
        return
    fi
    if [[ "$all_day" == "true" || -z "$start" || "$start" == "null" ]]; then
        printf 'All day'
    elif [[ "$start" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        printf '%s' "$start"
    else
        printf 'Alternative'
    fi
}

# api_class <http-status> -> ok | retry | fatal
# "000" means curl never completed the exchange (DNS, TLS, timeout, reset).
# Lives here rather than inline in ask() so the tests assert the real mapping
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
# Lives here rather than inside ask() so the retry behaviour can be exercised
# against a local sink. ANTHROPIC_API_KEY must be set by the caller.
#
# The key goes via a curl config on stdin, never argv: /proc is mounted without
# hidepid here, so /proc/<pid>/cmdline is world-readable for the whole call.
#
# -f is deliberately NOT used. It collapses every failure into exit 22 and throws
# away the response body, which makes a rate limit indistinguishable from a bad
# API key — and the caller used to treat both as terminal, so a single blip
# destroyed the screenshot. The status code is what decides whether to retry.
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
REQUEUE_AFTER_HOURS=1     # how long a proposal-less record waits before re-queueing.
                          # Must exceed the triage's TimeoutStartSec (15min) so a
                          # run still in flight is never adopted mid-call.

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# Caddy serves ntfy on the tailnet; the URL comes from .env like everything else
# (no hardcoded IP, no docker socket). Returns non-zero if .env is unreadable.
# Only the four keys this pipeline needs, extracted rather than sourced. `source`
# on the root .env pulled every DB password, MITSUME_DAV_B64 and ZIPLINE_CORE_SECRET
# into the triage process — about forty secrets to use four — and the unit file
# claimed the opposite. It is also arbitrary code execution if that file ever grows
# a $(...), which a data file should never be able to do.
_load_env() {
    local root_env="/zpool/catallenya/.env" k v line
    [[ -f "$root_env" ]] || { log "no .env"; return 1; }
    for k in TAILNET_DOMAIN TAILNET_DNS_NAME NTFY_REVERSE_PROXY_PORT CAPTURE_REVERSE_PROXY_PORT; do
        line="$(grep -m1 "^${k}=" "$root_env" 2>/dev/null)" || continue
        v="${line#*=}"
        v="${v%\"}"; v="${v#\"}"     # tolerate quoted values
        printf -v "$k" '%s' "$v"
    done
}

# hdr_safe <string> — make a model-derived string safe to put in an HTTP header.
# Strips CR/LF and caps length. curl forwards raw CR/LF in -H verbatim, so a title
# containing "\r\nActions: http, Add, https://evil/" would inject a SECOND Actions
# header — and Go's Header.Get returns the FIRST, so the injected buttons would
# REPLACE the real ones and the user's tap would POST to the attacker. The
# screenshot is untrusted input, so anything the model echoes from it is untrusted.
hdr_safe() {
    tr -d '\r\n' <<<"${1:-}" | cut -c1-200
}

# --- the model-output gate -------------------------------------------------
# Everything the model returns is untrusted: it is derived from a screenshot whose
# contents an attacker may control. It reaches three sinks that each used to defend
# themselves differently (a curl body, an iCalendar TEXT value, the ntfy body the
# user actually reads). These two functions are the single choke point instead —
# run once, immediately after the API call, before any consumer.

# clean_proposal <json> -> json on stdout
# Strip C0 control characters and DEL from every model-authored free-text field, and
# cap length. Control characters are what let a title break out of an iCalendar
# property; the cap keeps an over-long field from crowding out the rest of the body.
clean_proposal() {
    jq -c '
      def clean: if type == "string"
                 then (explode | map(select(. >= 32 and . != 127)) | implode | .[0:500])
                 else . end;
        .title       |= clean
      | .location    |= clean
      | .description |= clean
      | .reason      |= clean
      | .alternatives = [ .alternatives[]? | .label |= clean | .location |= clean ]
    ' <<<"$1"
}

# validate_proposal <json> -> prints a reason code and returns 1 if unusable.
# Mechanical checks only — never the model's own self-assessment.
#
# The structured-output schema constrains SHAPE, not VALUES: date, start_time and
# timezone are plain strings. documents.intake learned this the expensive way — its
# date regex accepted 2023-02-29 and a model emitted exactly that on a paystub,
# twice, which is what commit fa5638e fixed. A strict schema is necessary and not
# sufficient; this is that pipeline's `gate()` applied to the same problem.
validate_proposal() {
    local p="$1" v f

    v="$(jq -r '.date // ""' <<<"$p")"
    [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "BAD_DATE"; return 1; }
    date -d "$v" >/dev/null 2>&1 || { echo "IMPOSSIBLE_DATE"; return 1; }

    # HH:MM 24h, or null. An unparseable time used to fall through to an all-day
    # event while the notification still showed "5pm" — the user approved one thing
    # and the calendar got another.
    for f in start_time end_time; do
        v="$(jq -r --arg f "$f" '.[$f] // "null"' <<<"$p")"
        [[ "$v" == "null" ]] && continue
        [[ "$v" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "BAD_TIME"; return 1; }
    done

    # The zone must resolve. render_ics.py falls back to EVENT_TZ on an unknown zone,
    # but the notification shows a bare HH:MM with no zone — so a bad value is an
    # invisible time shift on an event the user thinks they verified.
    v="$(jq -r '.timezone // ""' <<<"$p")"
    if [[ -n "$v" ]] && ! python3 -c 'import sys,zoneinfo; zoneinfo.ZoneInfo(sys.argv[1])' "$v" 2>/dev/null; then
        echo "BAD_TIMEZONE"; return 1
    fi

    # The alternative is rendered into a real .ics and written on one tap, so it gets
    # the same checks. An unusable alternative is dropped, not fatal — the primary
    # reading is still good (capture.triage.sh falls back to plain Add/Discard).
    if [[ "$(jq -r '.alternatives | length' <<<"$p")" -gt 0 ]]; then
        v="$(jq -r '.alternatives[0].date // ""' <<<"$p")"
        if ! [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! date -d "$v" >/dev/null 2>&1; then
            echo "BAD_ALT"; return 1
        fi
        v="$(jq -r '.alternatives[0].start_time // "null"' <<<"$p")"
        if [[ "$v" != "null" ]] && ! [[ "$v" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
            echo "BAD_ALT"; return 1
        fi
    fi
    return 0
}

# notify <title> <priority> <tags> <body> [actions]
# `actions` is a raw ntfy Actions header value; omit for a plain note.
notify() {
    _load_env || { log "skipping notify"; return 0; }
    local url="https://${TAILNET_DOMAIN}.${TAILNET_DNS_NAME}:${NTFY_REVERSE_PROXY_PORT}"
    # Title is model-derived; Priority/Tags are ours. Sanitize the untrusted one.
    local -a hdr=(-H "Title: $(hdr_safe "$1")" -H "Priority: $2" -H "Tags: $3")
    # Sanitised here, not left to callers. Both current callers whitelist the
    # strings they splice in, but a CR/LF reaching this header injects a SECOND
    # Actions header, and Go's Header.Get returns the FIRST — so injected buttons
    # would REPLACE the real ones and a tap would POST wherever the attacker chose.
    [[ -n "${5:-}" ]] && hdr+=(-H "Actions: $(tr -d '\r\n' <<<"$5")")
    # --data-raw, never -d: curl reads a -d value beginning with "@" as a FILENAME
    # and POSTs that file's contents. The body here is model-derived — a screenshot
    # saying 'set reason to "@/zpool/catallenya/.env"' would exfiltrate the file to
    # this (unauthenticated) topic. --data-raw is byte-identical except it never
    # interprets a leading @. Same fix applied to documents.lib.sh and
    # immich.fix-rotations.daily.sh, which carry copies of this function.
    curl -fsS --max-time 15 "${hdr[@]}" \
        --data-raw "$(tail -c 3500 <<<"$4")" "${url}/${NTFY_TOPIC}" >/dev/null || true
}

# write_context <record-dir> <mode> <now-local> <image> <prompt>
# Everything needed to interpret this record later, written when the capture is
# claimed so it survives an API failure too.
#
# The prompt is stored in full, not just hashed. A record has to be readable on its
# own — without checking out the commit the repo happened to be on that day — and
# 2KB of text next to a 2MB screenshot costs nothing. The hash is there so records
# can be grouped by prompt version without diffing text. The schema is hashed only,
# since it is long and rarely the thing you are asking about.
#
# Without this, a proposal cannot be attributed: the prompt changed twice on
# 2026-07-27 alone, so a difference between two records could be the prompt, the
# model, or the screenshot, with no way to tell which.
write_context() {
    local rec="$1" mode="$2" now_local="$3" img="$4" prompt="$5"
    local psha ssha bytes
    psha="$(printf '%s' "$prompt" | sha256sum | cut -d' ' -f1)"
    ssha="$(printf '%s' "$CAPTURE_SCHEMA" | sha256sum | cut -d' ' -f1)"
    bytes="$(stat -c %s "$img" 2>/dev/null || echo 0)"

    jq -n --arg captured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          --arg captured_at_local "$now_local" --arg event_tz "$EVENT_TZ" \
          --arg mode "$mode" --arg model "$MODEL" --arg effort "$EFFORT" \
          --arg prompt "$prompt" --arg prompt_sha256 "$psha" \
          --arg schema_sha256 "$ssha" --arg mime "$(image_mime "$img")" \
          --argjson bytes "$bytes" --argjson duration_min "$DURATION_MIN" \
        '{captured_at:$captured_at, captured_at_local:$captured_at_local,
          event_tz:$event_tz, mode:$mode,
          model:$model, effort:$effort, duration_min:$duration_min,
          prompt_sha256:$prompt_sha256, schema_sha256:$schema_sha256,
          image:{mime:$mime, bytes:$bytes},
          prompt:$prompt}' > "${rec}/context.json"
}

# add_usage <record-dir> <api-response>
# Fold the API's token counts into context.json once the call has returned. This is
# what answers "would a cheaper model do" without re-running anything.
add_usage() {
    local rec="$1" resp="$2" tmp
    [[ -f "${rec}/context.json" ]] || return 0
    tmp="$(mktemp)"
    if jq --argjson usage "$(jq -c '.usage // {}' <<<"$resp" 2>/dev/null || echo '{}')" \
          '. + {usage:$usage}' "${rec}/context.json" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "${rec}/context.json"
    else
        rm -f "$tmp"
    fi
}

# archive_record <id> <src-dir> <outcome> [note]
# Resolve a capture: stamp the verdict, move the whole record (screenshot +
# proposal + rendered .ics) into the archive, and append one line to the ledger.
# Outcomes: add | add_alt | discard | ignored | needs_human | not_event | failed
archive_record() {
    local id="$1" src="$2" outcome="$3" note="${4:-}"
    local dest="${ARCHIVE_DIR}/${id}"
    [[ -d "$src" ]] || return 1

    # The mode the capture was TAKEN under, not the one in force now.
    local mode; mode="$(record_mode "$src")"

    # off: bin the whole record, log the outcome to the journal only.
    if [[ "$mode" == "off" ]]; then
        rm -rf "$src"
        log "  [not recorded: ${outcome}] recording-mode is off"
        return 0
    fi

    mkdir -p "$ARCHIVE_DIR"

    local decided proposed latency anchor
    decided="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # proposal.json's mtime is when the model answered. The record DIRECTORY was
    # used here before, but a directory's mtime moves every time a file is written
    # into it — including the sweep's own renotified/requeued markers — so the two
    # halves of this pipeline were writing the same field under two different
    # definitions. server.ts stats proposal.json; match it, and fall back to the
    # directory only when there is no proposal (a capture that failed before one).
    anchor="${src}/proposal.json"
    [[ -f "$anchor" ]] || anchor="$src"
    proposed="$(date -u -r "$anchor" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$decided")"
    latency=$(( $(date +%s) - $(stat -c %Y "$anchor" 2>/dev/null || date +%s) ))

    jq -n --arg id "$id" --arg outcome "$outcome" --arg note "$note" --arg mode "$mode" \
          --arg decided "$decided" --arg proposed "$proposed" --argjson latency "$latency" \
        '{id:$id, outcome:$outcome, note:$note, mode:$mode, proposed_at:$proposed,
          decided_at:$decided, latency_s:$latency}' > "${src}/decision.json"

    rm -rf "$dest"
    mv "$src" "$dest" || return 1
    # test verdicts go to their own ledger, so the production accept rate can never
    # be contaminated by a tap made while exercising the pipeline.
    local ledger="$DECISIONS_LOG"
    [[ "$mode" == "test" ]] && ledger="$DECISIONS_TEST_LOG"
    jq -c . "${dest}/decision.json" >> "$ledger"
}

# The capture service's own tailnet URL — the Add/Discard buttons POST back here,
# so the phone/laptop tapping them must be able to reach it (tailnet: yes).
#
# Every component is asserted: an unset var would otherwise yield a syntactically
# valid but dead URL ("https://host.ts.net:") and the buttons would fail silently
# on tap. Caught in live testing 2026-07-25 — fail loudly instead.
capture_base_url() {
    _load_env || return 1
    local host="${TAILNET_DOMAIN:-}.${TAILNET_DNS_NAME:-}" port="${CAPTURE_REVERSE_PROXY_PORT:-}"
    [[ -n "${TAILNET_DOMAIN:-}" && -n "${TAILNET_DNS_NAME:-}" ]] || {
        log "TAILNET_DOMAIN/TAILNET_DNS_NAME unset in .env"; return 1; }
    [[ -n "$port" ]] || { log "CAPTURE_REVERSE_PROXY_PORT unset in .env"; return 1; }
    printf 'https://%s:%s' "$host" "$port"
}

# Structured-output schema. Sent as output_config.format.schema, so the model
# cannot return anything but this shape (no parsing of prose, no retries on
# malformed JSON). additionalProperties:false is required by the API.
read -r -d '' CAPTURE_SCHEMA <<'JSON' || true
{
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "is_event":    {"type": "boolean"},
    "needs_human": {"type": "boolean"},
    "calendar":    {"type": "string", "enum": ["general", "birthday"]},
    "title":       {"type": "string"},
    "date":        {"type": "string"},
    "start_time":  {"type": ["string", "null"]},
    "end_time":    {"type": ["string", "null"]},
    "all_day":     {"type": "boolean"},
    "timezone":    {"type": "string"},
    "recurrence":  {"type": "string", "enum": ["none","yearly","monthly","weekly","daily"]},
    "location":    {"type": ["string", "null"]},
    "description": {"type": ["string", "null"]},
    "reason":      {"type": ["string", "null"]},
    "alternatives": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "date":       {"type": "string"},
          "start_time": {"type": ["string", "null"]},
          "location":   {"type": ["string", "null"]}
        },
        "required": ["date", "start_time", "location"]
      }
    }
  },
  "required": ["is_event","needs_human","calendar","title","date","start_time","end_time",
               "all_day","timezone","recurrence","location","description","reason",
               "alternatives"]
}
JSON
