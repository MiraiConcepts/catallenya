#!/bin/bash
# ebooks.apply.sh — perform the move a button tap asked for.
#
# Fired by ebooks.apply.path when the ebooks-approve container writes a marker. A marker is
# {"action":…,"at":…} and carries NO PATH: the container names an id and a verb, and where
# the book is and where it may go are read from the record the triage wrote. This script is
# the only thing that writes to the shelf on a tap, and it re-verifies everything.
#
# Markers are DELETED BEFORE they are acted on. ebooks.apply.path re-fires while one remains;
# deleting first is the only version of that invariant that cannot be forgotten in a later edit.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/zpool/catallenya/ebooks/scripts/ebooks.lib.sh
source "${SELF_DIR}/ebooks.lib.sh"

command -v jq >/dev/null || die "jq not found"
mkdir -p "$APPROVALS_DIR" "$PROPOSALS_DIR" "$STAGING_DIR" "$BIN_DIR" "$COVERS_DIR" "$WORK_DIR"

exec 9>"${STATE_DIR}/.apply.lock"
flock -n 9 || { log "another apply holds the lock; exiting"; exit 0; }

FILED=0; BINNED=0; DELETED=0; REFUSED=0
REFUSALS=""

# A move that is not verified is not a move. mv across filesystems is copy-then-delete.
move_verified() { # $1=src $2=dst $3=expected sha ('' skips)
    local src="$1" dst="$2" want="$3"
    mv -n -- "$src" "$dst" 2>/dev/null || return 1
    [[ -f "$dst" && ! -e "$src" ]] || return 1
    [[ -z "$want" || "$(sha256_of "$dst")" == "$want" ]]
}

where_is() { # $1 = record JSON -> the path the book is at now
    local r="$1" at sp
    at="$(jq -r '.at // empty' <<<"$r")"
    sp="$(jq -r '.staged_path // empty' <<<"$r")"
    case "$(jq -r '.state' <<<"$r")" in
        staged) [[ -n "$sp" ]] && printf '%s' "${STAGING_DIR}/${sp}" ;;
        binned) [[ -n "$at" ]] && printf '%s' "${BIN_DIR}/${at}" ;;
        filed)  [[ -n "$at" ]] && printf '%s' "${SHELF}/${at}" ;;
    esac
}

refuse() { # $1=id $2=name $3=reason
    REFUSED=$((REFUSED+1)); REFUSALS+="$2"$'\t'"$3"$'\n'
    log "  REFUSE ${1:0:8} — ${2:+${2}: }$3"
}

apply_one() {
    local id="$1" action="$2" rec f cur st sha dest name cover img mt final worked cj
    f="${PROPOSALS_DIR}/${id}.json"
    [[ -f "$f" ]] || { refuse "$id" "" "No such proposal"; return; }
    rec="$(cat "$f")"
    name="$(jq -r '.original_name // "?"' <<<"$rec")"

    # A batch tap applies the action to every member that is still staged.
    if [[ "$(jq -r '.kind // ""' <<<"$rec")" == "batch" ]]; then
        local m
        [[ "$(jq -r '.state' <<<"$rec")" == "staged" ]] || { refuse "$id" "" "That batch was replaced by a newer one"; return; }
        while IFS= read -r m; do [[ -n "$m" ]] && apply_one "$m" "$action"; done \
            < <(jq -r '.members[]?' <<<"$rec")
        jq -c --arg a "$action" '. + {state:"applied", last_action:$a}' <<<"$rec" > "$f"
        return
    fi

    st="$(jq -r '.state' <<<"$rec")"
    sha="$(jq -r '.sha256 // empty' <<<"$rec")"
    cur="$(where_is "$rec")"

    [[ -n "$cur" && -f "$cur" ]] || { refuse "$id" "$name" "Book is no longer where it was"; return; }
    if [[ -n "$sha" && "$(sha256_of "$cur")" != "$sha" ]]; then
        refuse "$id" "$name" "Book changed after it was proposed"; return
    fi

    case "$action" in
      accept)
        [[ "$st" == "filed" ]] && return 0                       # already there
        if [[ "$(jq -r '.blocked // "null"' <<<"$rec")" != "null" ]]; then
            refuse "$id" "$name" "$(r="$(reason_text "$(jq -r .blocked <<<"$rec")")"; printf '%s' "${r%.}")"; return
        fi
        dest="${SHELF}/$(jq -r '.dest_name // empty' <<<"$rec")"
        valid_book_name "$(basename "$dest")" || { refuse "$id" "$name" "Proposed name is not safe"; return; }
        under_shelf "$dest" || { refuse "$id" "$name" "Destination leaves the shelf"; return; }
        [[ -e "$dest" ]] && { refuse "$id" "$name" "Something is already at $(basename "$dest")"; return; }

        # Cover first, on a COPY: the staged original stays untouched until the new file is
        # verified and filed, so a failed swap costs the upgrade and never the book.
        final="$cur"; worked=false
        cover="$(jq -c '.cover // {}' <<<"$rec")"
        img="$(jq -r '.image // empty' <<<"$cover")"
        mt="$(jq -r '.media_type // empty' <<<"$cover")"
        case "$(jq -r '.action // "NONE"' <<<"$cover")" in
          # REPLACE is deliberately absent: the scanner raises it when a cover's aspect
          # ratio disagrees with an UNVERIFIED lookup, and the candidate is often SMALLER
          # (Atlas Shrugged: 600x800 offered a 331x500). It is a guess, not an upgrade.
          UPGRADE|ADD)
            if [[ -n "$img" && -f "$img" && "$cur" == *.epub ]]; then
                cp -f -- "$cur" "${WORK_DIR}/${id}.epub" \
                  && cj="$(python3 -I "$INSPECT" apply-cover "${WORK_DIR}/${id}.epub" "$img" "$mt" 2>/dev/null)" \
                  && [[ "$(jq -r '.ok' <<<"$cj")" == "true" ]] \
                  && { final="${WORK_DIR}/${id}.epub"; worked=true; } \
                  || log "  !! cover swap failed for ${name}; filing it with its original cover"
            fi ;;
        esac

        if move_verified "$final" "$dest" ""; then
            FILED=$((FILED+1)); log "  FILED  $(basename "$dest")  cover_applied=${worked}"
            [[ "$final" != "$cur" ]] && rm -f -- "$cur"      # the staged original, now superseded
            rm -f -- "$WORK_DIR/${id}.epub" "$img" 2>/dev/null || true
            jq -c --arg at "$(basename "$dest")" '. + {state:"filed", at:$at}' <<<"$rec" > "$f"
        else
            refuse "$id" "$name" "Move failed verification"
        fi ;;

      discard)
        [[ "$st" == "binned" ]] && return 0
        dest="$(bin_dest "$cur")"
        if move_verified "$cur" "$dest" "$sha"; then
            BINNED=$((BINNED+1)); log "  BINNED $(basename "$dest")"
            jq -c --arg at "$(basename "$dest")" '. + {state:"binned", at:$at}' <<<"$rec" > "$f"
        else
            refuse "$id" "$name" "Could not move to bin"
        fi ;;

      delete)
        # The only destructive arm, and the restriction lives HERE, never in the container:
        # a marker is just a filename the container wrote.
        [[ "$st" == "deleted" ]] && return 0
        [[ "$cur" == "${BIN_DIR}/"* ]] || { refuse "$id" "$name" "Only a book in bin/ can be deleted"; return; }
        if rm -f -- "$cur" && [[ ! -e "$cur" ]]; then
            DELETED=$((DELETED+1)); log "  DELETED $(basename "$cur")"
            jq -c '. + {state:"deleted"} | del(.at)' <<<"$rec" > "$f"
        else
            refuse "$id" "$name" "Could not delete"
        fi ;;

      *) refuse "$id" "$name" "Unknown action: ${action}" ;;
    esac
}

shopt -s nullglob
markers=("${APPROVALS_DIR}"/*.json)
(( ${#markers[@]} )) || { log "no markers"; exit 0; }
log "draining ${#markers[@]} marker(s)"

for mk in "${markers[@]}"; do
    id="$(basename "$mk" .json)"
    action="$(jq -r '.action // ""' "$mk" 2>/dev/null)"
    rm -f "$mk"                                           # delete FIRST
    [[ -n "$action" ]] || { log "  !! unreadable marker ${id:0:8} — dropped"; continue; }
    nid="$(notif_id "${PROPOSALS_DIR}/${id}.json")"
    before=$REFUSED
    apply_one "$id" "$action"
    # Withdraw the notification only when nothing was refused: a refused tap moved nothing,
    # and its buttons are still the way to act. That is what makes a notification vanishing
    # mean "done" rather than "tapped".
    (( REFUSED == before )) && retract "$nid"
done

log "filed ${FILED}, binned ${BINNED}, deleted ${DELETED}, refused ${REFUSED}"

if (( REFUSED > 0 )); then
    items=()
    while IFS= read -r line; do
        [[ -n "${line//[[:space:]]/}" ]] || continue
        [[ "$line" == $'\t'* ]] && line="${line#$'\t'}"
        items+=("$line")
    done <<<"$REFUSALS"
    notify_fault "$(title_count Refused "$REFUSED" Book)" "$(body_list --all "${items[@]}")"
fi

left="$(find "$APPROVALS_DIR" -maxdepth 1 -name '*.json' | wc -l)"
(( left == 0 )) || log "  !! ${left} marker(s) remain — path unit will re-fire"
exit 0
