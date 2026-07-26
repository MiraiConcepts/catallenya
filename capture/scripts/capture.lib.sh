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
# is a labelled training/eval example: exactly the shape of the golden set used for
# the 2026-07-24 bake-off, but accumulating on its own. Nothing is ever deleted.
ARCHIVE_DIR="${DATA_DIR}/archive"
# Append-only ledger of the same verdicts, one JSON object per line, for analysis
# without walking the archive (accept rate over time, alt-tap rate, etc).
DECISIONS_LOG="${DATA_DIR}/decisions.jsonl"
# Presence of this file switches recording OFF: resolved captures are deleted
# outright instead of being archived, and nothing is appended to the ledger. Use
# it while exercising the pipeline so test taps don't get counted as verdicts.
#   touch  capture/data/.recording-disabled   -> off (nothing kept)
#   rm     capture/data/.recording-disabled   -> on  (screenshots + verdicts kept)
# Checked at write time, so toggling needs no restart of anything.
RECORDING_OFF_FLAG="${DATA_DIR}/.recording-disabled"
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

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# Caddy serves ntfy on the tailnet; the URL comes from .env like everything else
# (no hardcoded IP, no docker socket). Returns non-zero if .env is unreadable.
_load_env() {
    local root_env="/zpool/catallenya/.env"
    [[ -f "$root_env" ]] || { log "no .env"; return 1; }
    # shellcheck source=/dev/null  # runtime-only file, not in the repo
    source "$root_env"
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
    [[ -n "${5:-}" ]] && hdr+=(-H "Actions: $5")
    # --data-raw, never -d: curl reads a -d value beginning with "@" as a FILENAME
    # and POSTs that file's contents. The body here is model-derived — a screenshot
    # saying 'set reason to "@/zpool/catallenya/.env"' would exfiltrate the file to
    # this (unauthenticated) topic. --data-raw is byte-identical except it never
    # interprets a leading @. Same fix applied to documents.lib.sh and
    # immich.fix-rotations.daily.sh, which carry copies of this function.
    curl -fsS --max-time 15 "${hdr[@]}" \
        --data-raw "$(tail -c 3500 <<<"$4")" "${url}/${NTFY_TOPIC}" >/dev/null || true
}

# archive_record <id> <src-dir> <outcome> [note]
# Resolve a capture: stamp the verdict, move the whole record (screenshot +
# proposal + rendered .ics) into the archive, and append one line to the ledger.
# Outcomes: add | add_alt | discard | ignored | needs_human | not_event | failed
archive_record() {
    local id="$1" src="$2" outcome="$3" note="${4:-}"
    local dest="${ARCHIVE_DIR}/${id}"
    [[ -d "$src" ]] || return 1

    # Recording off: bin the whole record, log the outcome to the journal only.
    if [[ -e "$RECORDING_OFF_FLAG" ]]; then
        rm -rf "$src"
        log "  [not recorded: ${outcome}] recording is disabled"
        return 0
    fi

    mkdir -p "$ARCHIVE_DIR"

    local decided proposed latency
    decided="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # Proposal mtime is when the model answered; the gap to the verdict is how
    # long a decision actually took (useful signal on its own).
    proposed="$(date -u -r "$src" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$decided")"
    latency=$(( $(date +%s) - $(stat -c %Y "$src" 2>/dev/null || date +%s) ))

    jq -n --arg id "$id" --arg outcome "$outcome" --arg note "$note" \
          --arg decided "$decided" --arg proposed "$proposed" --argjson latency "$latency" \
        '{id:$id, outcome:$outcome, note:$note, proposed_at:$proposed,
          decided_at:$decided, latency_s:$latency}' > "${src}/decision.json"

    rm -rf "$dest"
    mv "$src" "$dest" || return 1
    jq -c . "${dest}/decision.json" >> "$DECISIONS_LOG"
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
          "label":      {"type": "string"},
          "date":       {"type": "string"},
          "start_time": {"type": ["string", "null"]},
          "location":   {"type": ["string", "null"]}
        },
        "required": ["label", "date", "start_time", "location"]
      }
    }
  },
  "required": ["is_event","needs_human","calendar","title","date","start_time","end_time",
               "all_day","timezone","recurrence","location","description","reason",
               "alternatives"]
}
JSON
