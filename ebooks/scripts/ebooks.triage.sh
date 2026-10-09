#!/bin/bash
# ebooks.triage.sh — drop a book in stories/inbox/, get a proposal you can approve.
#
# Fired by ebooks.triage.path the moment a file lands in the inbox. Drains the whole
# inbox serially, then exits.
#
# HARD INVARIANT — every file MUST leave the inbox before this script exits, on every
# branch, success or failure. PathExistsGlob re-fires for as long as a match remains, so a
# book left in place hot-loops systemd. Nothing below returns without having moved the
# file to staging/. This is pigeonhole.triage.sh's invariant, learned there the hard way.
#
# NO MODEL. Everything is decided by ebooks.inspect.py (integrity, metadata, name rules,
# duplicate check, cover lookup against free public sources). What the rules cannot be
# sure of becomes a FLAG, which gets its own message; the tap is the verifier.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/zpool/catallenya/ebooks/scripts/ebooks.lib.sh
source "${SELF_DIR}/ebooks.lib.sh"

for _bin in jq python3 sha256sum pdfinfo; do
    command -v "$_bin" >/dev/null || die "missing required command: ${_bin}"
done

mkdir -p "$STATE_DIR" "$WORK_DIR" "$PROPOSALS_DIR" "$APPROVALS_DIR" "$STAGING_DIR" "$BIN_DIR" "$COVERS_DIR"

# Serialise. A cover lookup is slow; it must not overlap the next .path fire.
exec 9>"$LOCK_FILE"
flock -n 9 || { log "another triage holds the lock; exiting"; exit 0; }

cleanup() { rm -rf "${WORK_DIR:?}"/* 2>/dev/null || true; }
trap cleanup EXIT

# Stage a file under a given name. Verifies the bytes arrived: the staging area can be a
# different filesystem from the inbox, where mv is copy-then-delete.
stage_file() { # $1=src $2=wanted name $3=expected sha
    local src="$1" want="$2" sha="$3" stem ext dest n=2
    stem="${want%.*}"; ext="${want##*.}"
    dest="${STAGING_DIR}/${want}"
    while [[ -e "$dest" ]]; do dest="${STAGING_DIR}/${stem}-${n}.${ext}"; n=$((n+1)); done
    under_staging "$dest" || { log "  !! ${want} does not resolve inside staging/"; return 1; }
    mv -n -- "$src" "$dest" 2>/dev/null || return 1
    [[ -f "$dest" && ! -e "$src" ]] || return 1
    [[ -z "$sha" || "$(sha256_of "$dest")" == "$sha" ]] || return 1
    printf '%s' "$dest"
}

NEW_IDS=()
record() { printf '%s\n' "$2" > "${PROPOSALS_DIR}/${1}.json"; NEW_IDS+=("$1"); }

# A book is only touched once Syncthing has finished with it: acting mid-transfer would
# stage a truncated book.
waited=0
until syncthing_quiet "$INBOX"; do
    (( waited >= QUIET_WAIT_S )) && { log "syncthing still busy after ${waited}s; leaving the inbox for the next fire"; exit 0; }
    sleep "$QUIET_POLL_S"; waited=$((waited + QUIET_POLL_S))
done

mapfile -t CANDS < <(list_candidates)
(( ${#CANDS[@]} )) || { log "nothing in the inbox"; exit 0; }

TRUNCATED=0
if (( ${#CANDS[@]} > MAX_PER_RUN )); then
    TRUNCATED=$(( ${#CANDS[@]} - MAX_PER_RUN ))
    log "CAP: ${#CANDS[@]} in the inbox, taking ${MAX_PER_RUN}, deferring ${TRUNCATED} to the next run"
    CANDS=("${CANDS[@]:0:$MAX_PER_RUN}")
fi
log "draining ${#CANDS[@]} file(s) from the inbox"

STAGED=0; BLOCKED=0; STUCK=0

for name in "${CANDS[@]}"; do
    src="${INBOX}/${name}"
    [[ -f "$src" ]] || continue          # vanished under us; nothing to drain
    id="$(new_uuid)"
    sha="$(sha256_of "$src")"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    base="$(jq -nc --arg i "$id" --arg n "$name" --arg s "$sha" --arg t "$now" \
        '{id:$i, original_name:$n, sha256:$s, staged_at:$t}')"

    # One helper for every "park this and do not offer Accept" branch.
    block() { # $1=reason  $2=optional JSON object to merge into the record
        local staged extra="${2:-{\}}"
        if staged="$(stage_file "$src" "$name" "$sha")"; then
            BLOCKED=$((BLOCKED+1)); log "  BLOCK  ${name} ($1)"
            record "$id" "$(jq -c --argjson b "$base" --arg r "$1" --arg p "$(basename "$staged")" \
                --argjson x "$extra" \
                '$b + {state:"staged", blocked:$r, staged_path:$p, flags:[]} + $x' <<<'{}')"
        else
            STUCK=$((STUCK+1)); log "  !! could not stage ${name} — LEFT IN INBOX, next fire will retry"
        fi
    }

    if ! info="$(python3 -I "$INSPECT" inspect "$src" "$SHELF")"; then
        block INSPECT_FAILED; continue
    fi
    problem="$(jq -r '.problem' <<<"$info")"
    if [[ -n "$problem" ]]; then block "$problem"; continue; fi
    dup="$(jq -r '.duplicate_of' <<<"$info")"
    if [[ -n "$dup" ]]; then
        block DUPLICATE "$(jq -nc --arg d "$dup" '{duplicate_of:$d}')"
        continue
    fi

    draft="$(jq -r '.draft' <<<"$info")"
    blocked=""
    valid_book_name "$draft"                          || blocked="BAD_NAME"
    [[ -z "$blocked" ]] && ! under_shelf "${SHELF}/${draft}" && blocked="ESCAPES_SHELF"
    [[ -z "$blocked" && -e "${SHELF}/${draft}" ]]      && blocked="DESTINATION_EXISTS"
    if [[ -n "$blocked" ]]; then block "$blocked"; continue; fi

    # Cover lookup: EPUB only, network, never modifies the book. A failure here costs the
    # upgrade and nothing else — the book is still filed under its name.
    cover='{"action":"NONE"}'
    if [[ "$name" == *.[eE][pP][uU][bB] ]]; then
        if c="$(python3 -I "$INSPECT" cover "$src" "${WORK_DIR}/${id}")"; then
            cover="$c"
            img="$(jq -r '.image' <<<"$cover")"
            if [[ -n "$img" && -f "$img" ]]; then
                keep="${COVERS_DIR}/${id}.${img##*.}"
                cp -f -- "$img" "$keep" && cover="$(jq -c --arg k "$keep" '.image=$k' <<<"$cover")"
            fi
        else
            log "  !! cover lookup failed for ${name}; filing without an upgrade"
        fi
    fi

    flags="$(jq -c '.flags' <<<"$info")"
    if ! staged="$(stage_file "$src" "$draft" "$sha")"; then
        STUCK=$((STUCK+1)); log "  !! could not stage ${name} — LEFT IN INBOX, next fire will retry"
        continue
    fi
    STAGED=$((STAGED+1))
    log "  STAGE  ${name} -> ${draft}  flags=${flags}"
    record "$id" "$(jq -c --argjson b "$base" --argjson fl "$flags" --argjson cv "$cover" \
        --arg p "$(basename "$staged")" --arg d "$draft" \
        '$b + {state:"staged", staged_path:$p, dest_name:$d, blocked:null, flags:$fl, cover:$cv}' <<<'{}')"
done

log "staged ${STAGED}, blocked ${BLOCKED}, stuck ${STUCK}"

# Invariant check: anything still in the inbox beyond the cap will spin the path unit.
left="$(list_candidates | wc -l)"
(( left <= TRUNCATED )) || log "  !! $(( left - TRUNCATED )) file(s) STILL IN THE INBOX beyond the cap — path unit will spin"
(( TRUNCATED > 0 )) && log "  ${TRUNCATED} deferred; the path unit will re-fire for them"

# shellcheck disable=SC2034  # BASE is read by buttons()/bin_buttons() in ebooks.lib.sh
if ! BASE="$(ebooks_base_url)"; then
    log "  !! no base URL — books are staged but no notification was sent"
    log "     (check TAILNET_DOMAIN, TAILNET_DNS_NAME and EBOOKS_REVERSE_PROXY_PORT in .env)"
    exit 1
fi

# Notify. Clean books batch into one message; a flagged or blocked one gets its own so
# the thing that needs a look is not buried in a list that says "approve all".
clean=(); flagged=(); blocked_ids=()
for f in "${PROPOSALS_DIR}"/*.json; do
    [[ -f "$f" ]] || continue
    rid="$(basename "$f" .json)"
    case "$(staged_class "$f")" in
        blocked) blocked_ids+=("$rid") ;;
        flagged) flagged+=("$rid") ;;
        clean)   clean+=("$rid") ;;
    esac
done

if (( ${#clean[@]} )); then
    retire_batches
    bid="$(new_uuid)"
    cfiles=()
    for rid in "${clean[@]}"; do cfiles+=("${PROPOSALS_DIR}/${rid}.json"); done
    body="$(body_join "$(batch_list "${cfiles[@]}")" \
        "$( (( TRUNCATED > 0 )) && body_aside "${TRUNCATED} more still queued" )")"
    jq -nc --arg i "$bid" --argjson m "$(printf '%s\n' "${clean[@]}" | jq -R -s -c 'split("\n")|map(select(length>0))')" \
        --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{id:$i, kind:"batch", state:"staged", members:$m, staged_at:$t}' > "${PROPOSALS_DIR}/${bid}.json"
    retract "$BATCH_NTFY_ID"
    notify_proposal "$(title_count Staged "${#clean[@]}" Book)" \
        "$body" "$(buttons "$bid" 1)" "$BATCH_NTFY_ID"
    log "  notified batch of ${#clean[@]}"
fi

# Only this run's own flagged/blocked records: the older ones were announced when they
# arrived, and the sweep owns the nudge.
for rid in "${NEW_IDS[@]:-}"; do
    [[ -n "$rid" ]] || continue
    f="${PROPOSALS_DIR}/${rid}.json"
    [[ -f "$f" ]] || continue
    [[ "$(jq -r '.state' "$f")" == "staged" ]] || continue
    bl="$(jq -r '.blocked // "null"' "$f")"
    fl="$(jq -r '.flags[]?' "$f" | flags_sentence)"
    if [[ "$bl" != "null" ]]; then
        dupnote=""
        [[ "$bl" == DUPLICATE ]] && dupnote="$(body_fact "Matches $(jq -r '.duplicate_of' "$f")")"
        notify_proposal "$(title_count Blocked 1 Book)" \
            "$(body_join \
                "$(body_list "$(jq -r .staged_path "$f")")" \
                "$(reason_text "$bl")" "$dupnote")" \
            "$(buttons "$rid" 0)" "$rid"
    elif [[ -n "$fl" ]]; then
        notify_proposal "$(title_count Flagged 1 Book)" \
            "$(body_join "$(batch_list "$f")" "$fl")" \
            "$(buttons "$rid" 1)" "$rid"
    fi
done

if (( STUCK > 0 )); then
    notify_fault "$(title_count Stuck "$STUCK" Book)" \
        "Could not move $( (( STUCK == 1 )) && printf 'a book' || printf '%s books' "$STUCK" ) out of the inbox. The disk may be full, or permissions may have changed. The trigger will keep retrying until this is cleared." \
        "$STUCK_NTFY_ID"
    log "  !! ${STUCK} book(s) STUCK in the inbox"
    exit 1
fi

exit 0
