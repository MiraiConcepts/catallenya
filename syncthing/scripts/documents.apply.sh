#!/bin/bash
# documents.apply.sh — perform the move a button tap asked for.
#
# Fired by documents.apply.path whenever the approve container drops a marker in
# intake-state/approvals/. Drains every marker, then exits.
#
# HARD INVARIANT — every marker MUST be deleted before this script exits, on every
# branch. PathExistsGlob re-fires for as long as a file remains, so a marker left in
# place spins systemd. Unlike the triage this costs no API calls, but a unit
# restarting forever is still a unit nobody can read the logs of.
#
# WHY THE MOVE LIVES HERE AND NOT IN THE CONTAINER. The container is long-lived,
# reachable by anything on the tailnet, and gated by ntfy, which has no
# authentication. This is a oneshot with ProtectSystem=strict that runs for a second
# and is unreachable. So the container writes "proposal <uuid> was accepted" and
# this decides what that means — reading the destination from the record the TRIAGE
# wrote, never from anything the container could influence. A compromised container
# can replay an approval; it cannot invent one, redirect one, or name a path.
#
# THE STATE RULE. Each action means "put this document into the state that action
# names, from wherever it is now" — which is what makes undo fall out rather than
# being built:
#
#            accept              discard          skip
#   staged   -> dest             -> bin/          stays
#   filed    no-op               -> bin/          -> staging/
#   binned   -> dest             no-op            -> staging/
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/zpool/catallenya/syncthing/scripts/documents.lib.sh
source "${SELF_DIR}/documents.lib.sh"

command -v jq >/dev/null || die "jq not found"
mkdir -p "$APPROVALS_DIR" "$PROPOSALS_DIR" "$STAGING_DIR" "$BIN_DIR"

exec 9>"${STATE_DIR}/.apply.lock"
flock -n 9 || { log "another apply holds the lock; exiting"; exit 0; }

FILED=0; BINNED=0; RETURNED=0; REFUSED=0
REFUSALS=""

# move_verified <src> <dst> <expected-sha> -> 0 on success
# The move half is apply.sh's, unchanged and for the same reasons: mv -n never
# clobbers, and the read-back is what turns "mv returned 0" into "the document is
# actually there and is actually the document". A rename that half-succeeds across
# a full disk is exactly the case a bare exit code misses.
move_verified() {
    local src="$1" dst="$2" want="$3"
    mkdir -p "$(dirname "$dst")" || return 1
    mv -n -- "$src" "$dst" 2>/dev/null || return 1
    [[ -f "$dst" && ! -e "$src" ]] || return 1
    [[ -z "$want" || "$(sha256_of "$dst")" == "$want" ]]
}

# where_is <record-json> -> absolute path of the document right now, or empty.
#
# Reads `at`, which every move below WRITES. An earlier version derived the path
# from the state instead — staging_path when staged, dest_path when filed, and for
# binned it reconstructed ${BIN_DIR}/$(basename staged_path). That last one is
# wrong: the discard arm adds a timestamp prefix when bin/ already holds that name,
# so a document binned through the collision path could never be found again and
# both un-discard paths refused with "no longer where it was". Recording where a
# file actually landed beats deriving where it probably went.
where_is() {
    local r="$1" at sp dp
    at="$(jq -r '.at // empty' <<<"$r")"
    [[ -n "$at" ]] && { printf '%s' "${DOCS}/${at}"; return; }
    # Fallback for the initial staged record, which has no `at` yet, and for any
    # record written before this field existed. Derives by state exactly as the old
    # version did — including the bin guess that motivated the change, since a wrong
    # guess only costs a refusal, whereas no guess at all costs one for every legacy
    # record.
    sp="$(jq -r '.staged_path // empty' <<<"$r")"
    dp="$(jq -r '.dest_path   // empty' <<<"$r")"
    case "$(jq -r '.state' <<<"$r")" in
        staged) [[ -n "$sp" ]] && printf '%s' "${DOCS}/${sp}" ;;
        filed)  [[ -n "$dp" ]] && printf '%s' "${DOCS}/${dp}" ;;
        binned) [[ -n "$sp" ]] && printf '%s' "${BIN_DIR}/$(basename "$sp")" ;;
    esac
}

refuse() { # $1=id $2=reason
    REFUSED=$((REFUSED+1)); REFUSALS+="$2
"
    log "  REFUSE ${1:0:8} — $2"
}

# apply_one <uuid> <action>
apply_one() {
    local id="$1" action="$2" rec f cur st sha dest
    f="${PROPOSALS_DIR}/${id}.json"
    [[ -f "$f" ]] || { refuse "$id" "no such proposal"; return; }
    rec="$(cat "$f")"

    # A batch is a list of member ids and nothing else. Members that have already
    # moved are skipped rather than failing the batch: an older notification stays
    # tappable after a newer one supersedes it, and re-verification is exactly the
    # mechanism that makes that harmless.
    if [[ "$(jq -r '.kind // ""' <<<"$rec")" == "batch" ]]; then
        local m
        while IFS= read -r m; do [[ -n "$m" ]] && apply_one "$m" "$action"; done \
            < <(jq -r '.members[]?' <<<"$rec")
        jq -c --arg a "$action" '. + {state:"applied", last_action:$a}' <<<"$rec" > "$f"
        return
    fi

    st="$(jq -r '.state' <<<"$rec")"
    sha="$(jq -r '.sha256 // empty' <<<"$rec")"
    cur="$(where_is "$rec")"

    # TAP-TIME RE-VERIFICATION. Hours pass between the proposal and the tap, and
    # master/documents is a Syncthing folder — the file may have been renamed,
    # replaced or removed from another device in between. Acting on a stale proposal
    # is how the wrong document gets filed under the right name.
    [[ -n "$cur" && -f "$cur" ]] || { refuse "$id" "$(jq -r .original_name <<<"$rec"): document is no longer where it was"; return; }
    if [[ -n "$sha" && "$(sha256_of "$cur")" != "$sha" ]]; then
        refuse "$id" "$(jq -r .original_name <<<"$rec"): contents changed since it was proposed"; return
    fi

    case "$action" in
      accept)
        [[ "$st" == "filed" ]] && return 0                       # already there
        if [[ "$(jq -r '.blocked // "null"' <<<"$rec")" != "null" ]]; then
            refuse "$id" "$(jq -r .original_name <<<"$rec"): $(jq -r .blocked <<<"$rec") — cannot be filed"; return
        fi
        dest="${DOCS}/$(jq -r '.dest_path // empty' <<<"$rec")"
        [[ "$dest" != "${DOCS}/" ]] || { refuse "$id" "no destination recorded"; return; }
        # Re-run the containment check at apply time. The triage already did it, but
        # this is the step that actually writes, and the record is a file on disk
        # that something else could have edited.
        under_docs "$dest" || { refuse "$id" "destination escapes the documents tree"; return; }
        [[ -e "$dest" ]] && { refuse "$id" "$(jq -r .original_name <<<"$rec"): something is already at ${dest#"${DOCS}/"}"; return; }
        if move_verified "$cur" "$dest" "$sha"; then
            FILED=$((FILED+1)); log "  FILED  ${dest#"${DOCS}/"}"
            jq -c --arg at "${dest#"${DOCS}/"}" '. + {state:"filed", at:$at}' <<<"$rec" > "$f"
        else
            refuse "$id" "$(jq -r .original_name <<<"$rec"): move failed verification"
        fi ;;

      discard)
        [[ "$st" == "binned" ]] && return 0
        dest="${BIN_DIR}/$(basename "$cur")"
        [[ -e "$dest" ]] && dest="${BIN_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-$(basename "$cur")"
        if move_verified "$cur" "$dest" "$sha"; then
            BINNED=$((BINNED+1)); log "  BINNED ${dest#"${DOCS}/"}"
            jq -c --arg at "${dest#"${DOCS}/"}" '. + {state:"binned", at:$at}' <<<"$rec" > "$f"
        else
            refuse "$id" "$(jq -r .original_name <<<"$rec"): could not move to bin"
        fi ;;

      skip)
        [[ "$st" == "staged" ]] && return 0                      # already where skip means
        # Restore the name the triage PROPOSED, not whatever the file is called
        # right now. A document binned into a name collision picked up a timestamp
        # prefix, and returning it as 20260731T…-a.pdf would defeat the point of
        # staging — what you see there is meant to be the name accepting will use.
        dest="${STAGING_DIR}/$(basename "$(jq -r --arg b "$(basename "$cur")" '.staged_path // $b' <<<"$rec")")"
        [[ -e "$dest" ]] && { refuse "$id" "$(jq -r .original_name <<<"$rec"): staging already holds that name"; return; }
        if move_verified "$cur" "$dest" "$sha"; then
            RETURNED=$((RETURNED+1)); log "  STAGED ${dest#"${DOCS}/"}"
            jq -c --arg p "staging/$(basename "$dest")" \
               '. + {state:"staged", staged_path:$p, at:$p}' <<<"$rec" > "$f"
        else
            refuse "$id" "$(jq -r .original_name <<<"$rec"): could not return to staging"
        fi ;;

      *) refuse "$id" "unknown action: ${action}" ;;
    esac
}

# --- drain the markers -----------------------------------------------------

shopt -s nullglob
markers=("${APPROVALS_DIR}"/*.json)
(( ${#markers[@]} )) || { log "no markers"; exit 0; }
log "draining ${#markers[@]} marker(s)"

for mk in "${markers[@]}"; do
    id="$(basename "$mk" .json)"
    action="$(jq -r '.action // ""' "$mk" 2>/dev/null)"
    # Delete FIRST. Every branch below must leave the marker gone, and doing it here
    # rather than in each arm is the only version of that which cannot be forgotten
    # in a later edit. The action is already in hand; losing the file loses nothing.
    rm -f "$mk"
    [[ -n "$action" ]] || { log "  !! unreadable marker ${id:0:8} — dropped"; continue; }
    apply_one "$id" "$action"
done

log "filed ${FILED}, binned ${BINNED}, returned ${RETURNED}, refused ${REFUSED}"

# Silent on success — the button clearing is the confirmation, and a ping per tap is
# how a useful topic becomes one you mute. A refusal is the opposite: you tapped,
# nothing happened, and without this you would never know why.
if (( REFUSED > 0 )); then
    notify "$( (( REFUSED == 1 )) && echo "Could not file 1 document" || echo "Could not file ${REFUSED} documents" )" \
        high warning "$REFUSALS"
fi

left="$(find "$APPROVALS_DIR" -maxdepth 1 -name '*.json' | wc -l)"
(( left == 0 )) || log "  !! ${left} marker(s) remain — path unit will re-fire"
exit 0
