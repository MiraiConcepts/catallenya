#!/bin/bash
# shellcheck disable=SC2034  # config vars are consumed by the scripts that source this
# Shared helpers for the ebooks intake pipeline.
# Sourced by ebooks.{triage,apply,sweep}.sh — not executable on its own.
#
# THE SHAPE IS PIGEONHOLE'S, with two deliberate differences:
#   1. No model. Every decision here is a rule (ebooks.inspect.py); the human tap is the
#      only judgement. There is no API key anywhere in this pipeline.
#   2. The inbox is a SUBFOLDER of the shelf. Pigeonhole drops at a folder's root because
#      filing moves a document DOWN into a subfolder; here finished books stay at the
#      shelf root, so the root cannot also be the place new ones wait.
#
# State is the filesystem, as in pigeonhole: inbox/ -> staging/ -> (shelf | bin/).
# staging/ and bin/ live in intake-state/, NOT in the synced folder, so an e-reader
# never sees a book that has not been approved. The only moment a raw file is visible
# to a paired device is the few seconds between the drop and the triage moving it.

set -uo pipefail

# shellcheck source=/zpool/catallenya/ntfy/ntfy.lib.sh
source "/zpool/catallenya/ntfy/ntfy.lib.sh"

# Notification vocabulary, declared per feature (see ntfy/MESSAGES.md). Past participles.
# `Stuck`, `Flagged`, `Refused`, `Binned` and `Blocked` are shared with pigeonhole because the
# SITUATIONS match, not because a rule forces it.
# shellcheck disable=SC2034  # consumed by systemd/contract.sh
NTFY_VERBS=(Staged Blocked Flagged Refused Binned Stuck)
# shellcheck disable=SC2034  # consumed by systemd/contract.sh
NTFY_NOUNS=(Book)

# The Syncthing quiet gate. The shared library hardcodes the `master` folder id; the shelf
# belongs to `library`, so point the gate at it.
# shellcheck source=/zpool/catallenya/syncthing/syncthing.lib.sh
source "/zpool/catallenya/syncthing/syncthing.lib.sh"
SYNCTHING_FOLDER_ID="mefya-cbcqq"   # label "library"

# Overridable ONLY so the pipeline can be exercised against a scratch tree. Never set in
# production — the defaults are the only values systemd ever runs with.
SHELF="${SHELF:-/zpool/catallenya/syncthing/data/library/stories}"
INBOX="${INBOX:-${SHELF}/inbox}"
STATE_DIR="${STATE_DIR:-/zpool/catallenya/ebooks/intake-state}"
LOCK_FILE="${STATE_DIR}/.intake.lock"
PROPOSALS_DIR="${STATE_DIR}/proposals"
APPROVALS_DIR="${STATE_DIR}/approvals"
STAGING_DIR="${STATE_DIR}/staging"
BIN_DIR="${STATE_DIR}/bin"
COVERS_DIR="${STATE_DIR}/covers"
WORK_DIR="${STATE_DIR}/work"

export PYTHONDONTWRITEBYTECODE=1   # the units are read-only outside ReadWritePaths; never litter scripts/ with __pycache__
INSPECT="${INSPECT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ebooks.inspect.py}"

NTFY_TOPIC="ebooks"
MAX_PER_RUN="${MAX_PER_RUN:-10}"   # a cover lookup sleeps ~3s per book; cap and say so

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

new_uuid() { cat /proc/sys/kernel/random/uuid; }
sha256_of() { sha256sum -- "$1" 2>/dev/null | cut -d' ' -f1; }

# --- path safety ------------------------------------------------------------
# A book name reaches a filesystem path twice: staged, then filed. The draft comes from
# metadata this box does not author, so it is untrusted text.
#
# A filename is one path component. No slash, no NUL, no leading dot (a dotfile is
# invisible to the glob AND to the e-reader), no `..`, bounded bytes, a known extension.
valid_book_name() { # $1 = a proposed filename
    local n="$1" LC_ALL=C
    [[ -n "$n" ]] || return 1
    [[ "$n" != */* && "$n" != .* && "$n" != *".."* ]] || return 1
    (( ${#n} <= 200 )) || return 1
    [[ "$n" == *.epub || "$n" == *.pdf ]] || return 1
    return 0
}

# Resolved destination must be a DIRECT child of the shelf. Directly under the shelf, not
# merely beneath it: the shelf contains inbox/, and a name that walked into inbox/ would be
# re-triaged by the path unit forever.
under_shelf() { # $1 = candidate absolute path
    local real
    real="$(realpath -m -- "$1" 2>/dev/null)" || return 1
    [[ "$real" == "${SHELF}/"* && "$real" != "${SHELF}/"*/* ]]
}

under_staging() { # $1 = candidate absolute path
    local real
    real="$(realpath -m -- "$1" 2>/dev/null)" || return 1
    [[ "$real" == "${STAGING_DIR}/"* && "$real" != "${STAGING_DIR}/"*/* ]]
}

# --- candidates -------------------------------------------------------------
# Inbox FILES only. Dotfiles are Syncthing/macOS machinery and the path unit's glob
# cannot see them either.
list_candidates() {
    find "$INBOX" -maxdepth 1 -type f ! -name '.*' -printf '%f\n' 2>/dev/null | sort
}

# bin/ never overwrites: a second discard of the same name gets a timestamp prefix.
bin_dest() { # $1 = current path
    local base dest
    base="$(basename "$1")"
    dest="${BIN_DIR}/${base}"
    [[ -e "$dest" ]] && dest="${BIN_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-${base}"
    printf '%s' "$dest"
}

# --- proposal classes -------------------------------------------------------
# clean   -> rides in the batch
# flagged -> its own message (a rule was not sure of the name)
# blocked -> its own message, no Accept button
staged_class() { # $1 = proposal file; prints a class, or nothing when not staged
    local f="$1"
    [[ "$(jq -r '.state // ""' "$f" 2>/dev/null)" == "staged" ]] || return 0
    [[ "$(jq -r '.kind  // ""' "$f")" == "batch" ]] && return 0
    [[ "$(jq -r '.blocked // "null"' "$f")" != "null" ]] && { printf blocked; return 0; }
    [[ "$(jq -r '.flags | length' "$f")" != "0" ]]       && { printf flagged; return 0; }
    printf clean
}

# One batch notification covers every clean proposal. Mark the old record superseded so
# the apply step cannot honour a stale tap. Records are history, not live state.
retire_batches() {
    local old
    for old in "${PROPOSALS_DIR}"/*.json; do
        [[ -f "$old" ]] || continue
        [[ "$(jq -r '.kind  // ""' "$old")" == "batch"  ]] || continue
        [[ "$(jq -r '.state // ""' "$old")" == "staged" ]] || continue
        jq -c '. + {state:"superseded"}' "$old" > "${old}.tmp" && mv "${old}.tmp" "$old"
    done
}

BATCH_NTFY_ID="ebooks-batch"
STUCK_NTFY_ID="ebooks-stuck"

notif_id() { # $1 = proposal file -> the ntfy sequence id its notification used
    local f="$1"
    [[ "$(jq -r '.kind // ""' "$f" 2>/dev/null)" == "batch" ]] \
        && { printf '%s' "$BATCH_NTFY_ID"; return 0; }
    printf '%s' "$(basename "$f" .json)"
}

# --- notification plumbing --------------------------------------------------
_load_env() { _ntfy_env EBOOKS_REVERSE_PROXY_PORT; }

ebooks_base_url() {
    _load_env || return 1
    [[ -n "${TAILNET_DOMAIN:-}" && -n "${TAILNET_DNS_NAME:-}" ]] || {
        log "TAILNET_DOMAIN/TAILNET_DNS_NAME unset in .env"; return 1; }
    [[ -n "${EBOOKS_REVERSE_PROXY_PORT:-}" ]] || {
        log "EBOOKS_REVERSE_PROXY_PORT unset in .env"; return 1; }
    printf 'https://%s.%s:%s' "$TAILNET_DOMAIN" "$TAILNET_DNS_NAME" "$EBOOKS_REVERSE_PROXY_PORT"
}

reason_text() {
    case "$1" in
        EPUB_CORRUPT)        echo "The EPUB is corrupt or unreadable." ;;
        FILE_TOO_SMALL)      echo "The file is suspiciously small." ;;
        FILE_EMPTY)          echo "The file is empty." ;;
        PDF_UNREADABLE)      echo "The PDF is unreadable." ;;
        PDF_ENCRYPTED)       echo "The PDF is locked." ;;
        UNSUPPORTED_TYPE)    echo "Only EPUB and PDF are supported." ;;
        INSPECT_FAILED)      echo "The book could not be inspected." ;;
        BAD_NAME)            echo "The proposed name is not safe to use." ;;
        ESCAPES_SHELF)       echo "The proposed path leaves the shelf." ;;
        DESTINATION_EXISTS)  echo "Something on the shelf already has that name." ;;
        DUPLICATE)           echo "Already on the shelf." ;;
        *)                   echo "$1" ;;
    esac
}

flag_clause() {
    case "$1" in
        NAME_UNCLEAR) echo "has a title or author that did not clean up" ;;
        NO_AUTHOR)    echo "has no author in its metadata" ;;
        *)            echo "is flagged $1" ;;
    esac
}

flags_sentence() { # stdin: one flag code per line
    local c cl out="" seen=""
    while IFS= read -r c; do
        [[ -n "$c" ]] || continue
        cl="$(flag_clause "$c")"
        [[ "$seen" == *"|${cl}|"* ]] && continue
        seen+="|${cl}|"
        out+="${out:+ and }${cl}"
    done
    [[ -n "$out" ]] && printf 'Book %s.' "$out"
}

# One line per book: the draft name, then (indented) what changes. Two details at most.
batch_list() { # args: proposal files
    local f det cov
    local -a items=()
    for f in "$@"; do
        cov="$(jq -r 'if .cover.action == "UPGRADE" or .cover.action == "ADD"
                      then "Cover: \(.cover.current_w)x\(.cover.current_h) to \(.cover.online_w)x\(.cover.online_h)"
                      elif .cover.action == "REPLACE"
                      then "Cover may be wrong; left as it is"
                      else "" end' "$f")"
        det="was $(jq -r '.original_name // "?"' "$f")"
        [[ -n "$cov" ]] && det+="; ${cov}"
        items+=("$(jq -r '.dest_name // "?"' "$f")"$'\t'"${det}")
    done
    body_list --all "${items[@]}"
}

buttons() { # $1=id $2=1 if Accept should be offered
    local id="$1" b=""
    [[ "$2" == "1" ]] && b="http, Accept, ${BASE}/ebooks/${id}/accept, method=POST, headers.X-Ebooks=1; "
    printf '%shttp, Discard, %s/ebooks/%s/discard, method=POST, headers.X-Ebooks=1' "$b" "$BASE" "$id"
}

bin_buttons() { # $1=id $2=1 if Accept should be offered
    local id="$1" b=""
    [[ "$2" == "1" ]] && b="http, Accept, ${BASE}/ebooks/${id}/accept, method=POST, headers.X-Ebooks=1; "
    printf '%shttp, Delete, %s/ebooks/%s/delete, method=POST, headers.X-Ebooks=1' "$b" "$BASE" "$id"
}
