#!/bin/bash
# ebooks.sweep.sh — nightly: nudge a staged book at 24h, bin it at 7d, withdraw stale notes.
#
# Makes no network calls except ntfy, and holds no secrets. Fails the unit on ANY failure:
# a sweep notifies per nothing, so a night where every bin failed must not look like a
# night where everything worked (the afterimage sweep learned this in 2026-08).
#
#   staged 24h -> re-notify once (retract the original, publish the nudge)
#   staged 7d  -> move to bin/. Accept still files it from there; the sweep NEVER deletes.
#   binned 7d  -> withdraw the NOTE only. The book is untouched; only a Delete tap removes it.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/zpool/catallenya/ebooks/scripts/ebooks.lib.sh
source "${SELF_DIR}/ebooks.lib.sh"

RENOTIFY_AFTER_HOURS=24
BIN_AFTER_DAYS=7
BIN_NOTE_DAYS=7

DRY=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        -h|--help) printf 'usage: %s [--dry-run]\n' "${0##*/}" >&2; exit 0 ;;
        *) printf 'usage: %s [--dry-run]\n' "${0##*/}" >&2; die "unknown argument: ${arg}" ;;
    esac
done
(( DRY )) && log "DRY RUN — nothing will be moved or notified"

command -v jq >/dev/null || die "jq not found"
mkdir -p "$PROPOSALS_DIR" "$STAGING_DIR" "$BIN_DIR"

exec 9>"${STATE_DIR}/.sweep.lock"
flock -n 9 || { log "another sweep holds the lock; exiting"; exit 0; }

# shellcheck disable=SC2034  # BASE is read by buttons()/bin_buttons() in ebooks.lib.sh
if ! BASE="$(ebooks_base_url)"; then
    log "  !! no base URL — cannot renotify or bin; failing loudly rather than"
    log "     reporting a sweep that did not happen"
    exit 1
fi

now=$(date +%s)
renotified=0; binned=0; FAILED=0
batch_members=(); batch_oldest_h=0

stamp() { # $1=record file, rest = jq args
    local rf="$1"; shift
    local tmp="${rf}.tmp"
    jq -c "$@" "$rf" > "$tmp" && mv "$tmp" "$rf"
}

shopt -s nullglob
for f in "${PROPOSALS_DIR}"/*.json; do
    rec="$(cat "$f")"
    [[ "$(jq -r '.state // ""' <<<"$rec")" == "staged" ]] || continue
    [[ "$(jq -r '.kind  // ""' <<<"$rec")" == "batch"  ]] && continue
    id="$(basename "$f" .json)"
    age_h=$(( (now - $(stat -c %Y "$f" 2>/dev/null || echo "$now")) / 3600 ))

    sp="$(jq -r '.staged_path // empty' <<<"$rec")"
    cur="${STAGING_DIR}/${sp}"
    [[ -n "$sp" && -f "$cur" ]] || continue      # not there any more; nothing to nudge
    sha="$(jq -r '.sha256 // empty' <<<"$rec")"
    if [[ -n "$sha" && "$(sha256_of "$cur")" != "$sha" ]]; then
        log "  !! ${sp}: contents changed since proposed — leaving for a human"
        continue
    fi

    orig="$(jq -r '.original_name // "?"' <<<"$rec")"
    bl="$(jq -r '.blocked // "null"' <<<"$rec")"
    fl="$(jq -r '.flags[]?' <<<"$rec" | flags_sentence)"

    if (( age_h >= BIN_AFTER_DAYS * 24 )); then
        dest="$(bin_dest "$cur")"
        if (( DRY )); then log "would bin ${sp} (${age_h}h staged)"; continue; fi
        if mv -n -- "$cur" "$dest" 2>/dev/null && [[ -f "$dest" && ! -e "$cur" ]]; then
            stamp "$f" --arg at "$(basename "$dest")" '. + {state:"binned", at:$at}'
            binned=$((binned + 1)); log "binned ${sp} (${age_h}h staged)"
            offer_accept=1; [[ "$bl" != "null" ]] && offer_accept=0
            binnote="In bin/ after $(( age_h / 24 )) days with no decision."
            (( offer_accept )) && binnote+=" Accept still files it."
            binnote+=" Delete removes it for good."
            notify_resolved "$(title_count Binned 1 Book)" \
                "$(body_join "$(body_list "$orig")" \
                    "$( [[ "$bl" != "null" ]] && reason_text "$bl" )" "$binnote")" \
                "$id" "$(bin_buttons "$id" "$offer_accept")"
        else
            FAILED=$((FAILED + 1)); log "  !! could not bin ${sp}"
        fi
        continue
    fi

    if (( age_h >= RENOTIFY_AFTER_HOURS )) && [[ "$(jq -r '.renotified_at // ""' <<<"$rec")" == "" ]]; then
        if (( DRY )); then log "would re-notify ${sp} (${age_h}h)"; continue; fi
        if [[ "$bl" != "null" ]]; then
            notify_nudge "$(title_count "Still Blocked" 1 Book "" "$(title_age "$age_h")")" \
                "$(body_join "$(body_list "$sp")" "$(reason_text "$bl")")" \
                "$id" "$(buttons "$id" 0)"
        elif [[ -n "$fl" ]]; then
            notify_nudge "$(title_count "Still Flagged" 1 Book "" "$(title_age "$age_h")")" \
                "$(body_join "$(batch_list "$f")" "$fl")" \
                "$id" "$(buttons "$id" 1)"
        else
            batch_members+=("$id")                 # clean ones re-batch below, as one message
            (( age_h > batch_oldest_h )) && batch_oldest_h=$age_h
        fi
        stamp "$f" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '. + {renotified_at:$t}'
        renotified=$((renotified + 1)); log "re-notified ${sp} (${age_h}h)"
    fi
done

if (( ${#batch_members[@]} )); then
    rebatch=()
    for f in "${PROPOSALS_DIR}"/*.json; do
        [[ -f "$f" ]] || continue
        [[ "$(staged_class "$f")" == "clean" ]] || continue
        rebatch+=("$(basename "$f" .json)")
    done
    retire_batches
    bid="$(new_uuid)"
    bfiles=()
    for rid in "${rebatch[@]}"; do bfiles+=("${PROPOSALS_DIR}/${rid}.json"); done
    jq -nc --arg i "$bid" \
        --argjson m "$(printf '%s\n' "${rebatch[@]}" | jq -R -s -c 'split("\n")|map(select(length>0))')" \
        --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{id:$i, kind:"batch", state:"staged", members:$m, staged_at:$t}' > "${PROPOSALS_DIR}/${bid}.json"
    notify_nudge "$(title_count "Still Staged" "${#rebatch[@]}" Book "" "$(title_age "$batch_oldest_h")")" \
        "$(batch_list "${bfiles[@]}")" \
        "$BATCH_NTFY_ID" "$(buttons "$bid" 1)"
fi

# A binned note is withdrawn after its own clock. The BOOK is untouched.
for f in "${PROPOSALS_DIR}"/*.json; do
    rec="$(cat "$f")"
    [[ "$(jq -r '.state // ""' <<<"$rec")" == "binned" ]] || continue
    [[ "$(jq -r '.note_withdrawn // false' <<<"$rec")" == "true" ]] && continue
    age_d=$(( (now - $(stat -c %Y "$f" 2>/dev/null || echo "$now")) / 86400 ))
    (( age_d >= BIN_NOTE_DAYS )) || continue
    id="$(basename "$f" .json)"
    if (( DRY )); then log "would withdraw the binned note for ${id:0:8}"; continue; fi
    retract "$id"
    stamp "$f" '. + {note_withdrawn:true}'
    log "withdrew the binned note for ${id:0:8} (${age_d}d in bin/) — book untouched"
done

# A batch whose members are all resolved leaves a notification whose buttons answer nothing.
for b in "${PROPOSALS_DIR}"/*.json; do
    [[ "$(jq -r '.kind  // ""' "$b")" == "batch"  ]] || continue
    [[ "$(jq -r '.state // ""' "$b")" == "staged" ]] || continue
    live=0
    while read -r m; do
        [[ -n "$m" ]] || continue
        [[ "$(jq -r '.state // ""' "${PROPOSALS_DIR}/${m}.json" 2>/dev/null)" == "staged" ]] && { live=1; break; }
    done < <(jq -r '.members[]?' "$b")
    (( live )) && continue
    if (( DRY )); then log "would withdraw the batch notification"; continue; fi
    retract "$BATCH_NTFY_ID"
    stamp "$b" '. + {state:"superseded"}'
    log "withdrew the batch notification (no members still staged)"
done

(( renotified || binned || FAILED )) && \
    log "sweep: ${renotified} re-notified, ${binned} binned, ${FAILED} failed"

(( FAILED == 0 )) || exit 1
exit 0
