#!/bin/bash
# documents.sweep.sh — nightly lifecycle for staged proposals. Run at 07:45 SGT by
# documents.sweep.timer — morning-side, because everything it does ends in a phone
# notification, and fifteen minutes after capture's so the two bursts stay
# distinguishable.
#
# The triage only runs when a document arrives, so it cannot manage the life of a
# proposal that is sitting in staging unanswered. This does, mirroring
# capture.sweep.sh:
#
#   1. RE-NOTIFY once at RENOTIFY_AFTER_HOURS. "No tap" is ambiguous — ignored, or
#      never seen (phone off, ntfy's 12h cache expired). One nudge separates the
#      two. Clean proposals re-batch into one message, exactly as the triage first
#      sent them; flagged and blocked ones re-send individually, with the same
#      buttons (no Accept on a blocked one).
#   2. BIN at BIN_AFTER_DAYS: a proposal untouched for a week moves to bin/ with a
#      final note. The record is updated the way a Discard tap would update it, so
#      every button keeps working — Accept on the final note (or on the original,
#      still-live notification) files the document straight out of bin/.
#   3. NEVER empties bin/. Nothing in this pipeline destroys a document without a
#      tap, and the sweep taps nothing.
#
# Ages are measured from the record file's mtime — the time of the last state
# change, which apply rewrites on every tap — so a document you skipped back to
# staging gets a fresh week, and the re-notify itself resets the clock (a bin
# lands ~a day after the nudge, not the same morning).
#
# Makes no API calls and holds no API key — pure filesystem + ntfy.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/zpool/catallenya/documents/scripts/documents.lib.sh
source "${SELF_DIR}/documents.lib.sh"

RENOTIFY_AFTER_HOURS=24
BIN_AFTER_DAYS=7

DRY=0
usage() { printf 'usage: %s [--dry-run]\n' "${0##*/}" >&2; }
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown argument: ${arg}" ;;
    esac
done
(( DRY )) && log "DRY RUN — nothing will be moved or notified"

command -v jq >/dev/null || die "jq not found"
mkdir -p "$PROPOSALS_DIR" "$STAGING_DIR" "$BIN_DIR"

# Own lock, so a slow sweep never blocks a triage or an apply — and flock rather
# than nothing, so two sweeps (timer + a manual run) cannot bin the same file.
exec 9>"${STATE_DIR}/.sweep.lock"
flock -n 9 || { log "another sweep holds the lock; exiting"; exit 0; }

# shellcheck disable=SC2034  # BASE is consumed by buttons() in documents.lib.sh
if ! BASE="$(documents_base_url)"; then
    # Without a base URL every button would be dead on arrival. Renotifying with
    # dead buttons is worse than staying quiet a day; binning still needs the
    # final note's buttons, so it waits too.
    log "  !! no base URL — leaving everything for the next run"
    exit 0
fi

now=$(date +%s)
renotified=0; binned=0; batch_members=()

# stamp <record-file> [jq args...] <filter> — rewrite the record in place.
# Values go in via --arg, NEVER interpolated into the filter: staged_path can be an
# ORIGINAL filename off another device, and a quote in it would otherwise become
# jq syntax.
stamp() {
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

    sp="$(jq -r '.at // .staged_path // empty' <<<"$rec")"
    cur="${DOCS}/${sp}"
    [[ -n "$sp" && -f "$cur" ]] || continue      # vanished from another device
    sha="$(jq -r '.sha256 // empty' <<<"$rec")"
    if [[ -n "$sha" && "$(sha256_of "$cur")" != "$sha" ]]; then
        # Same rule as apply: never act on a proposal whose document changed
        # underneath it. A changed staged file has no path back through the
        # pipeline, so this is worth a log line, not silence.
        log "  !! ${sp}: contents changed since proposed — leaving for a human"
        continue
    fi

    orig="$(jq -r '.original_name // "?"' <<<"$rec")"
    bl="$(jq -r '.blocked // "null"' <<<"$rec")"
    fl="$(jq -r '.flags[]?' <<<"$rec" | flags_sentence)"

    # --- a week untouched: move to bin/, with a final note ------------------
    if (( age_h >= BIN_AFTER_DAYS * 24 )); then
        dest="${BIN_DIR}/$(basename "$cur")"
        [[ -e "$dest" ]] && dest="${BIN_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-$(basename "$cur")"
        if (( DRY )); then
            log "would bin ${sp} (${age_h}h staged)"
            continue
        fi
        if mv -n -- "$cur" "$dest" 2>/dev/null && [[ -f "$dest" && ! -e "$cur" ]]; then
            stamp "$f" --arg at "${dest#"${DOCS}/"}" '. + {state:"binned", at:$at}'
            binned=$((binned + 1)); log "binned ${sp} (${age_h}h staged)"
            offer_accept=1; [[ "$bl" != "null" ]] && offer_accept=0
            binbody="1\. $(md_escape "$orig")

"
            [[ "$bl" != "null" ]] && binbody+="$(reason_text "$bl")

"
            if (( offer_accept )); then
                binbody+="_In bin/ after $(( age_h / 24 )) days with no decision. Accept still files it; Skip returns it to staging._"
            else
                binbody+="_In bin/ after $(( age_h / 24 )) days with no decision. Skip returns it to staging._"
            fi
            notify "Binned: 1 Document" "" wastebasket "$binbody" "$(buttons "$id" "$offer_accept")"
        else
            log "  !! could not bin ${sp}"
        fi
        continue
    fi

    # --- one nudge at 24h ---------------------------------------------------
    if (( age_h >= RENOTIFY_AFTER_HOURS )) && [[ "$(jq -r '.renotified_at // ""' <<<"$rec")" == "" ]]; then
        if (( DRY )); then
            log "would re-notify ${sp} (${age_h}h)"
            continue
        fi
        if [[ "$bl" != "null" ]]; then
            notify "Pending Blocked: 1 Document" high warning \
                "1\. $(md_escape "$(basename "$sp")")

$(reason_text "$bl")" "$(buttons "$id" 0)"
        elif [[ -n "$fl" ]]; then
            notify "Pending Review: 1 Document" high question \
                "$(batch_list "$f")

${fl}" "$(buttons "$id" 1)"
        else
            batch_members+=("$id")      # clean ones re-batch below, as one message
        fi
        stamp "$f" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '. + {renotified_at:$t}'
        renotified=$((renotified + 1))
        log "re-notified ${sp} (${age_h}h)"
    fi
done

# Clean proposals renotify as ONE batch, the shape the triage first sent them in —
# with a fresh batch record so its Accept covers exactly these members, and older
# batch snapshots retired the same way the triage retires them.
if (( ${#batch_members[@]} )); then
    for old in "${PROPOSALS_DIR}"/*.json; do
        [[ "$(jq -r '.kind // ""' "$old")" == "batch" ]] || continue
        [[ "$(jq -r '.state // ""' "$old")" == "staged" ]] || continue
        stamp "$old" '. + {state:"superseded"}'
    done
    bid="$(new_uuid)"
    bfiles=()
    for rid in "${batch_members[@]}"; do bfiles+=("${PROPOSALS_DIR}/${rid}.json"); done
    jq -nc --arg i "$bid" \
        --argjson m "$(printf '%s\n' "${batch_members[@]}" | jq -R -s -c 'split("\n")|map(select(length>0))')" \
        --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{id:$i, kind:"batch", state:"staged", members:$m, staged_at:$t}' \
        > "${PROPOSALS_DIR}/${bid}.json"
    notify "Pending Staged: ${#batch_members[@]} Document$( (( ${#batch_members[@]} == 1 )) || printf s )" \
        "" clipboard "$(batch_list "${bfiles[@]}")" \
        "$(buttons "$bid" 1)"
fi

(( renotified || binned )) && log "sweep: ${renotified} re-notified, ${binned} binned"
exit 0
