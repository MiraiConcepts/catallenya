#!/bin/bash
# Shared helpers for the documents.intake pipeline.
# Sourced by documents.intake.{scan,classify,apply,daily}.sh — not executable on its own.
#
# Design notes live in .claude/plans/documents-nightly-intake.md. The two that matter
# most here:
#   - ctime, NOT mtime. Syncthing preserves the sender's mtime, so a file that landed
#     ten seconds ago can look days old. ctime is local arrival.
#   - Scope is root files only. The numbered folders are the filed corpus and are only
#     ever hashed, never read or moved.

set -uo pipefail

# Everything that talks to api.anthropic.com lives in ai.lib.sh, shared with the
# capture pipeline: transport + retry (api_post/api_class), request construction
# (ai_build_request) and the response gate (ai_extract). Sourced FIRST, before the
# log()/die() below, so this file's identical definitions stay authoritative.
# shellcheck source=/zpool/catallenya/ai/scripts/ai.lib.sh
source "/zpool/catallenya/ai/scripts/ai.lib.sh"

DOCS="/zpool/catallenya/syncthing/data/master/documents"
STATE_DIR="/zpool/catallenya/syncthing/intake-state"
SEEN_JSON="${STATE_DIR}/seen.json"
# shellcheck disable=SC2034  # consumed by documents.intake.daily.sh (flock)
LOCK_FILE="${STATE_DIR}/.intake.lock"
# Scratch for rasterised pages. Under STATE_DIR because that is writable as carrein
# without root (a manual run must work too), is NOT a restic target (restic takes
# syncthing/data, not syncthing/), and is not synced to peers. Wiped on exit.
# shellcheck disable=SC2034  # consumed by documents.intake.{scan,classify}.sh
WORK_DIR="${STATE_DIR}/work"
VOCAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/documents.vocab.json"

SYNCTHING_CONFIG="/zpool/catallenya/syncthing/data/config/config.xml"
SYNCTHING_FOLDER_ID="3j1oy-9cefl"   # label "master"

# Reaching the Syncthing API from the host is fiddlier than it looks:
#   - :8384 is EXPOSED but NOT PUBLISHED (docker ps shows a bare "8384/tcp"), so
#     127.0.0.1:8384 reaches nothing. Consistent with commit 8051401's tailnet-only posture.
#   - The container IP (172.18.x) works but is dynamic — it moves on `compose up -d`.
#     Resolving it at runtime needs `docker inspect`, i.e. the docker socket, i.e.
#     root-equivalent access for this unit. Not worth it for a health check.
#   - So: go through Caddy on loopback with the correct SNI. Stable, cert validates,
#     no hardcoded IP, no docker socket. Port comes from .env like everything else.
# Sets ST_HOST / ST_PORT / ST_BASE as globals. Must NOT be called via $(...) — a
# subshell would set them and throw them away.
ST_HOST=""; ST_PORT=""; ST_BASE=""
st_api_base() {
    local root_env="/zpool/catallenya/.env"
    [[ -f "$root_env" ]] || { log "no .env"; return 1; }
    # shellcheck source=/dev/null  # runtime-only file, not in the repo
    source "$root_env"
    ST_HOST="${TAILNET_DOMAIN}.${TAILNET_DNS_NAME}"
    ST_PORT="${SYNCTHING_REVERSE_PROXY_PORT}"
    ST_BASE="https://${ST_HOST}:${ST_PORT}"
}

# A candidate must have been on disk (ctime) this long. Overridable so the pipeline is
# testable without waiting an hour — the nightly timer never sets it.
MIN_AGE_SECONDS="${MIN_AGE_SECONDS:-3600}"
MAX_PER_RUN="${MAX_PER_RUN:-20}"   # cap; truncation is logged explicitly, never silent
# Pages rasterised and sent per document. NOT 1: page 1 is often a cover sheet, and
# classifying it reads the wrong page correctly. 3 covers 75 of 96 filed PDFs outright.
MAX_PAGES="${MAX_PAGES:-3}"

NTFY_TOPIC="documents"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# --- Syncthing -------------------------------------------------------------

# The config dir is carrein:carrein 0700 — readable as ourselves, no elevation.
st_apikey() {
    [[ -r "$SYNCTHING_CONFIG" ]] || die "cannot read $SYNCTHING_CONFIG"
    grep -oPm1 '(?<=<apikey>)[^<]+' "$SYNCTHING_CONFIG"
}

# Refuse to touch anything unless Syncthing says the folder is settled. Acting
# mid-transfer files a truncated document, and a move inside a synced folder
# propagates to every peer — a bad move is not local.
st_folder_idle() {
    local key json state need
    key="$(st_apikey)" || return 1
    st_api_base || return 1   # sets globals; NOT $(...) — see st_api_base
    json="$(curl -sS --max-time 15 --resolve "${ST_HOST}:${ST_PORT}:127.0.0.1" \
            -H "X-API-Key: ${key}" \
            "${ST_BASE}/rest/db/status?folder=${SYNCTHING_FOLDER_ID}" 2>/dev/null)" || return 1
    state="$(jq -r '.state // "unknown"' <<<"$json" 2>/dev/null)"
    need="$(jq -r '.needFiles // 1' <<<"$json" 2>/dev/null)"
    [[ "$state" == "idle" && "$need" == "0" ]]
}

# --- Candidates ------------------------------------------------------------

# Root files only. CLAUDE.md is documentation, not a document; dotfiles are
# Syncthing/macOS machinery.
list_candidates() {
    find "$DOCS" -maxdepth 1 -type f \
        ! -name 'CLAUDE.md' ! -name '.*' -printf '%f\n' 2>/dev/null | sort
}

# The filed corpus: exactly the numbered folders, any depth (catches
# 03_employment/resumes-and-cover-letters/). Naturally excludes .claude/,
# .stfolder, .stignore without an exclusion list.
list_corpus() {
    find "$DOCS"/[0-9][0-9]_* -type f ! -name '.*' 2>/dev/null | sort
}

# ctime age, not mtime — see header.
file_settled() {
    local f="$1" ctime now
    ctime="$(stat -c %Z "$f" 2>/dev/null)" || return 1
    now="$(date +%s)"
    (( now - ctime >= MIN_AGE_SECONDS )) || return 1
    # Syncthing scratch files sitting alongside mean the folder is mid-work.
    ! compgen -G "${DOCS}/.syncthing.*.tmp" >/dev/null 2>&1
}

sha256_of() { sha256sum -- "$1" 2>/dev/null | cut -d' ' -f1; }

# --- seen.json -------------------------------------------------------------
# Keyed by content hash, not path: a file renamed at root stays skipped, an
# edited file correctly re-adjudicates. Without this, one stuck file costs ~60
# pointless classification passes and 30 identical ntfy pings a month.

seen_init() { [[ -f "$SEEN_JSON" ]] || echo '{}' > "$SEEN_JSON"; }
seen_get()  { jq -r --arg h "$1" '.[$h] // empty' "$SEEN_JSON" 2>/dev/null; }
seen_has()  { [[ -n "$(seen_get "$1")" ]]; }

seen_put() { # $1=sha $2=verdict $3=reason_code
    local tmp; tmp="$(mktemp)"
    jq --arg h "$1" --arg v "$2" --arg r "$3" --arg d "$(date -u +%Y-%m-%d)" \
       '.[$h] = {first_seen: (.[$h].first_seen // $d), verdict: $v, reason_code: $r, notified: true}' \
       "$SEEN_JSON" > "$tmp" && mv "$tmp" "$SEEN_JSON"
}

# Drop entries whose hash no longer sits at root — the human filed it, or we did.
seen_gc() {
    local live tmp; live="$(mktemp)"; tmp="$(mktemp)"
    while IFS= read -r f; do sha256_of "${DOCS}/${f}"; done < <(list_candidates) > "$live"
    jq --slurpfile _ /dev/null --rawfile live "$live" \
       'with_entries(select(.key as $k | ($live | split("\n")) | index($k)))' \
       "$SEEN_JSON" > "$tmp" 2>/dev/null && mv "$tmp" "$SEEN_JSON"
    rm -f "$live"
}

# How long has a flagged file been sitting there? Drives the 7-day nudge.
seen_age_days() {
    local first; first="$(jq -r --arg h "$1" '.[$h].first_seen // empty' "$SEEN_JSON" 2>/dev/null)"
    [[ -n "$first" ]] || { echo 0; return; }
    echo $(( ( $(date +%s) - $(date -d "$first" +%s) ) / 86400 ))
}

# --- Vocabulary ------------------------------------------------------------

vocab_list()   { jq -r --arg k "$1" '.[$k][]' "$VOCAB"; }
vocab_has()    { jq -e --arg k "$1" --arg v "$2" '.[$k] | index($v)' "$VOCAB" >/dev/null 2>&1; }
is_lookalike() { # $1=doc_type $2=folder
    jq -e --arg t "$1" --arg f "$2" \
       '(._lookalike_families.doc_type | index($t)) or (._lookalike_families.folder | index($f))' \
       "$VOCAB" >/dev/null 2>&1
}

# --- ntfy ------------------------------------------------------------------

notify() { # $1=title $2=priority $3=tags $4=body
    local root_env="/zpool/catallenya/.env"
    [[ -f "$root_env" ]] || { log "no .env; skipping notify"; return 0; }
    # shellcheck source=/dev/null  # runtime-only file, not in the repo
    source "$root_env"
    local url="https://${TAILNET_DOMAIN}.${TAILNET_DNS_NAME}:${NTFY_REVERSE_PROXY_PORT}"
    # --data-raw, never -d: curl reads a -d value beginning with "@" as a FILENAME
    # and POSTs that file's contents. The body starts with a filename from the root
    # of master/documents (see documents.intake.daily.sh), so a synced file named
    # "@/zpool/catallenya/.env" would exfiltrate that file to the ntfy topic.
    # --data-raw is byte-identical except it never interprets a leading @.
    curl -sS -H "Title: $1" -H "Priority: $2" -H "Tags: $3" \
         --data-raw "$(tail -c 3500 <<<"$4")" "${url}/${NTFY_TOPIC}" >/dev/null || true
}
