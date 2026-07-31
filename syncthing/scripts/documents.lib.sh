#!/bin/bash
# shellcheck disable=SC2034  # config vars are consumed by the scripts that source this
# Shared helpers for the documents pipeline.
# Sourced by documents.{triage,apply}.sh — not executable on its own.
#
# Scope is ROOT FILES ONLY. The numbered folders are the filed corpus and are only
# ever hashed for duplicate detection, never read, renamed or moved — so a nightly
# re-audit can never churn a decision you made by hand.

set -uo pipefail

# Everything that talks to api.anthropic.com lives in ai.lib.sh, shared with the
# capture pipeline: transport + retry (api_post/api_class), request construction
# (ai_build_request) and the response gate (ai_extract). Sourced FIRST, before the
# log()/die() below, so this file's identical definitions stay authoritative.
# shellcheck source=/zpool/catallenya/ai/scripts/ai.lib.sh
source "/zpool/catallenya/ai/scripts/ai.lib.sh"

# Overridable ONLY so the pipeline can be exercised against a scratch tree without
# touching the real corpus — same seam as API_URL in ai.lib.sh. Never set in
# production; the defaults are the only values systemd ever runs with.
DOCS="${DOCS:-/zpool/catallenya/syncthing/data/master/documents}"
STATE_DIR="${STATE_DIR:-/zpool/catallenya/syncthing/intake-state}"
LOCK_FILE="${STATE_DIR}/.intake.lock"
# Scratch for rasterised pages. Under STATE_DIR because that is writable as carrein
# without root (a manual run must work too), is NOT a restic target (restic takes
# syncthing/data, not syncthing/), and is not synced to peers. Wiped on exit.
WORK_DIR="${STATE_DIR}/work"
VOCAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/documents.vocab.json"

# --- propose-and-approve ---------------------------------------------------
# State is the FILESYSTEM, not a state file: a document is wherever it currently
# sits, so `ls` answers "what is the system doing" and nothing can desync from
# anything else. root -> staging -> (numbered folder | bin).
#
# staging/ and bin/ are INSIDE the synced folder deliberately (owner, 2026-07-31):
# a staged document is visible on every paired device with the name it is about to
# be given, and a discarded one stays recoverable everywhere. The cost is that each
# state change propagates. Neither directory is picked up by list_candidates (root
# FILES only) or list_corpus (globs [0-9][0-9]_*), so no scan needed changing.
STAGING_DIR="${DOCS}/staging"
BIN_DIR="${DOCS}/bin"
# The records stay OUT of the synced folder — they are machinery, not documents,
# and STATE_DIR is not a restic target. approvals/ is the only directory the
# approval container can write, and it holds nothing but zero-byte markers.
PROPOSALS_DIR="${STATE_DIR}/proposals"
APPROVALS_DIR="${STATE_DIR}/approvals"

# Path safety. The closed vocabulary used to guarantee that a model-chosen value
# could never become a path; with free text that guarantee has to be enforced here
# instead, and it is the single most load-bearing check in the pipeline.
#
# The charset is what makes traversal impossible: no slash, no leading dot, and
# `..` cannot be spelled without one. Length is bounded so a pathological name
# cannot blow past NAME_MAX and get silently truncated into a different file.
SEGMENT_RE='^[a-z0-9][a-z0-9._-]{0,63}$'
valid_segment() { # $1 = one path component proposed by the model
    # LC_ALL=C is load-bearing, not tidiness. Bash's =~ honours LC_COLLATE, and under
    # en_US.UTF-8 the range [a-z] collates to include accented letters — "café"
    # MATCHES, while under C it does not. A vendor name with an accent is entirely
    # plausible, so this was reachable; worse, the function would have accepted it in
    # an interactive shell and rejected it under systemd, which sets no locale. A
    # validation result that depends on the caller's environment is a bug whichever
    # way it errs. Caught by the test suite 2026-07-31.
    local LC_ALL=C
    [[ "$1" =~ $SEGMENT_RE ]] && [[ "$1" != *".."* ]]
}

# Belt to valid_segment's braces: resolve the assembled path and require it to land
# under DOCS. valid_segment should already make this impossible, so a failure here
# means the charset check was bypassed or a component was assembled from somewhere
# it should not have been. -m so a not-yet-existing destination still resolves.
under_docs() { # $1 = candidate absolute path
    local real
    real="$(realpath -m -- "$1" 2>/dev/null)" || return 1
    [[ "$real" == "${DOCS}/"* ]]
}

new_uuid() { cat /proc/sys/kernel/random/uuid; }

# A real calendar date, at any of the three precisions the schema admits. The regex
# alone is not enough: it accepts 2023-02-29, which the 2026-07-18 battery actually
# produced, and it accepts year 0000, which shipped as a silent gap until 2026-07-30.
#
# `date -d` cannot carry the year-only case — it parses a bare "0000" as a TIME and
# returns success — so that arm is an explicit range. 10# forces base ten, or an
# unprefixed 0009 is invalid octal and aborts the arithmetic instead of failing the
# check. Upper bound allows next year: renewals and policies are dated ahead.
valid_date() { # $1 = YYYY | YYYY-MM | YYYY-MM-DD
    local dt="$1"
    case "${#dt}" in
        10) date -d "$dt" >/dev/null 2>&1 ;;
        7)  [[ "${dt:5:2}" =~ ^(0[1-9]|1[0-2])$ ]] ;;
        4)  (( 10#$dt >= 1900 && 10#$dt <= $(date +%Y) + 1 )) ;;
        *)  return 1 ;;
    esac
}

# A dropped file is only touched once Syncthing has finished with it. Two signals,
# both cheap: no scratch files alongside (Syncthing writes .syncthing.*.tmp then
# renames, so their presence means the folder is mid-work), and the API's own idle
# state. This replaced an hour-long MIN_AGE_SECONDS proxy for "probably finished";
# asking Syncthing directly is both faster and an actual answer.
docs_quiet() {
    compgen -G "${DOCS}/.syncthing.*.tmp" >/dev/null 2>&1 && return 1
    # Test seam, same rationale as DOCS above: a scratch tree has no Syncthing to
    # ask. Never set in production — without the real idle check, a mid-transfer
    # file gets classified truncated.
    [[ "${SKIP_SYNCTHING_GATE:-}" == "1" ]] && return 0
    st_folder_idle
}

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

sha256_of() { sha256sum -- "$1" 2>/dev/null | cut -d' ' -f1; }

# --- seen.json --- REMOVED 2026-07-31
# The whole family (seen_init/get/has/put/gc/age_days) existed because the nightly
# re-scanned a root that kept its files: without memoisation one stuck document cost
# ~60 pointless classifications and 30 identical pings a month. The triage drains the
# root on every run, so nothing is ever re-seen and there is nothing to remember.
# Duplicate detection is by corpus hash, in the triage.

# --- Vocabulary ------------------------------------------------------------

vocab_has()    { jq -e --arg k "$1" --arg v "$2" '.[$k] | index($v)' "$VOCAB" >/dev/null 2>&1; }
is_lookalike() { # $1=doc_type $2=folder
    jq -e --arg t "$1" --arg f "$2" \
       '(._lookalike_families.doc_type | index($t)) or (._lookalike_families.folder | index($f))' \
       "$VOCAB" >/dev/null 2>&1
}

# --- ntfy ------------------------------------------------------------------

# Only the keys this pipeline needs, extracted rather than sourced. `source` on the
# root .env pulled in every database credential and service token the stack has —
# roughly forty values, to use four — and it is arbitrary code execution if that
# file ever grows a $(...), which a data file should never be able to do. capture
# fixed this first; the copy here lagged behind.
# (Deliberately not naming the variables in prose: gitleaks 8.24.3, which CI pins,
# reads a secret-shaped name beside the word "password" as a finding.)
_load_env() {
    local root_env="/zpool/catallenya/.env" k v line
    [[ -f "$root_env" ]] || { log "no .env"; return 1; }
    for k in TAILNET_DOMAIN TAILNET_DNS_NAME NTFY_REVERSE_PROXY_PORT DOCUMENTS_REVERSE_PROXY_PORT; do
        line="$(grep -m1 "^${k}=" "$root_env" 2>/dev/null)" || continue
        v="${line#*=}"; v="${v%\"}"; v="${v#\"}"
        printf -v "$k" '%s' "$v"
    done
}

# Where an ntfy button POSTs. Caddy serves the approval container on the tailnet;
# every component is asserted because an unset var yields a syntactically valid but
# dead URL ("https://host.ts.net:") and the buttons then fail silently on tap —
# exactly the bug capture shipped and caught only in live testing.
documents_base_url() {
    _load_env || return 1
    [[ -n "${TAILNET_DOMAIN:-}" && -n "${TAILNET_DNS_NAME:-}" ]] || {
        log "TAILNET_DOMAIN/TAILNET_DNS_NAME unset in .env"; return 1; }
    [[ -n "${DOCUMENTS_REVERSE_PROXY_PORT:-}" ]] || {
        log "DOCUMENTS_REVERSE_PROXY_PORT unset in .env"; return 1; }
    printf 'https://%s.%s:%s' "$TAILNET_DOMAIN" "$TAILNET_DNS_NAME" "$DOCUMENTS_REVERSE_PROXY_PORT"
}

notify() { # $1=title $2=priority $3=tags $4=body [$5=actions]
    _load_env || { log "skipping notify"; return 0; }
    local url="https://${TAILNET_DOMAIN}.${TAILNET_DNS_NAME}:${NTFY_REVERSE_PROXY_PORT}"
    # Title carries a filename, which is untrusted — it arrives over Syncthing from
    # whatever device wrote it. hdr_safe strips the CR/LF that would otherwise inject
    # a second Actions header and replace the real buttons.
    local -a hdr=(-H "Title: $(hdr_safe "$1")" -H "Tags: $3" -H "Markdown: yes")
    [[ -n "${2:-}" ]] && hdr+=(-H "Priority: $2")
    # Sanitised here rather than left to callers: the URLs are ours, but the labels
    # beside them are not always going to be.
    [[ -n "${5:-}" ]] && hdr+=(-H "Actions: $(tr -d '\r\n' <<<"$5")")
    # --data-raw, never -d: curl reads a -d value beginning with "@" as a FILENAME
    # and POSTs that file's contents. The body starts with a filename from the root
    # of master/documents, so a synced file named "@/zpool/catallenya/.env" would
    # exfiltrate that file to this (unauthenticated) topic. --data-raw is
    # byte-identical except it never interprets a leading @.
    curl -sS "${hdr[@]}" \
         --data-raw "$(tail -c 3500 <<<"$4")" "${url}/${NTFY_TOPIC}" >/dev/null || true
}
