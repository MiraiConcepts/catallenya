#!/bin/bash
# documents.intake.apply.sh — phase 3 of 3. Reads the adjudicated manifest on stdin.
#
#   --dry-run   report what would happen, touch nothing
#   --yes       execute
#
# CODE assembles the filename from the enum fields. The model never emits a string that
# becomes a path. This deletes the path-traversal and filename-disclosure surface rather
# than sanitising it — cf. CVE-2023-37274, where AutoGPT was induced into writing
# ../../main.py: schema valid, type correct, the VALUE was traversal.
#
# READ BACK AFTER WRITING. Gemini CLI (Jul 2025) was asked to do exactly this operation,
# a mkdir silently failed, it never re-read the filesystem, hallucinated the state, and
# destroyed data using entirely legitimate commands. No allowlist would have caught it.
# A read-back would have.

set -uo pipefail
# shellcheck source=/zpool/catallenya/syncthing/scripts/documents.lib.sh
source "$(cd "$(dirname "$0")" && pwd)/documents.lib.sh"

MODE="dry-run"
case "${1:-}" in
    --yes)     MODE="apply" ;;
    --dry-run) MODE="dry-run" ;;
    *)         die "usage: $0 --dry-run|--yes" ;;
esac

FILED=0; REMOVED=0; FLAGGED=0; FAILED=0
ACTIONS='[]'

record() { # $1=action $2=file $3=detail $4=reason
    ACTIONS="$(jq --arg a "$1" --arg f "$2" --arg d "$3" --arg r "$4" \
        '. + [{action:$a, file:$f, detail:$d, reason:$r}]' <<<"$ACTIONS")"
}

# Filename per FILING-SCHEME 3: YYYY-MM-DD_description[_qualifier][_owner].ext
# Assembled here, from enums, by code.
build_name() { # $1=proposal $2=ext
    local p="$1" ext="$2" date type qual owner name
    date="$(jq -r .date      <<<"$p")"
    type="$(jq -r .doc_type  <<<"$p")"
    qual="$(jq -r .qualifier <<<"$p")"
    owner="$(jq -r .owner    <<<"$p")"
    name="${date}_${type}"
    [[ "$qual"  != "none" ]] && name="${name}_${qual}"
    [[ "$owner" != "self" ]] && name="${name}_${owner}"
    printf '%s.%s' "$name" "${ext,,}"
}

# The eight-point gate. Mechanical — never self-reported confidence. All must hold.
gate() { # $1=candidate json -> echoes failing reason, or nothing on pass
    local c="$1" p v t f
    p="$(jq -c '.proposal // empty' <<<"$c")"
    v="$(jq -c '.verdict  // empty' <<<"$c")"
    [[ -n "$p" ]] || { echo "NO_PROPOSAL"; return 1; }
    [[ -n "$v" ]] || { echo "NO_VERDICT";  return 1; }

    # 2. the adversarial pass must not have refuted it
    [[ "$(jq -r .refuted <<<"$v")" == "false" ]] || { echo "REFUTED_$(jq -r .reason_code <<<"$v")"; return 1; }
    # 6. the classifier itself must not have asked for a human
    [[ "$(jq -r .needs_human <<<"$p")" == "false" ]] || { echo "$(jq -r .reason_code <<<"$p")"; return 1; }
    # 3. every enum resolved, nothing unknown or out-of-vocabulary
    t="$(jq -r .doc_type <<<"$p")"; f="$(jq -r .folder <<<"$p")"
    [[ "$(jq -r .owner <<<"$p")" != "unknown" ]] || { echo "OWNER_UNKNOWN"; return 1; }
    vocab_has folder    "$f"                        || { echo "FOLDER_NOT_IN_VOCAB"; return 1; }
    vocab_has doc_type  "$t"                        || { echo "TYPE_NOT_IN_VOCAB"; return 1; }
    vocab_has qualifier "$(jq -r .qualifier <<<"$p")" || { echo "QUALIFIER_NOT_IN_VOCAB"; return 1; }
    # 4. the date must be printed on the document, not inferred
    [[ "$(jq -r .date_source <<<"$p")" == "printed_on_document" ]] || { echo "DATE_NOT_PRINTED"; return 1; }
    # 8. lookalike families never auto-file, however confident
    ! is_lookalike "$t" "$f" || { echo "LOOKALIKE_FAMILY"; return 1; }
    return 0
}

while IFS= read -r c; do
    name="$(jq -r .file   <<<"$c")"
    sha="$(jq -r .sha256  <<<"$c")"
    status="$(jq -r .status <<<"$c")"
    src="${DOCS}/${name}"

    case "$status" in
      SKIP_SEEN) continue ;;

      DUPE)
        keeper="$(jq -r .keeper <<<"$c")"
        # Decided by jdupes/sha256, never by the model. Both copies live inside the same
        # restic target, so the "kept the copy outside the backup set" hazard can't apply.
        # ZFS + sanoid + restic make this recoverable regardless.
        if [[ "$MODE" == "apply" ]]; then
            if rm -- "$src" 2>/dev/null && [[ ! -e "$src" ]]; then   # read back
                REMOVED=$((REMOVED+1)); record removed "$name" "${keeper##*/}" "EXACT_SHA256_MATCH"
                log "  REMOVED ${name} (identical to ${keeper##*/})"
            else
                FAILED=$((FAILED+1)); record failed "$name" "" "RM_FAILED"
            fi
        else
            REMOVED=$((REMOVED+1)); record would-remove "$name" "${keeper##*/}" "EXACT_SHA256_MATCH"
            log "  WOULD REMOVE ${name} (identical to ${keeper##*/})"
        fi
        ;;

      NEEDS_HUMAN)
        reason="$(jq -r '.reason_code // "UNKNOWN"' <<<"$c")"
        FLAGGED=$((FLAGGED+1)); record flagged "$name" "" "$reason"
        [[ "$MODE" == "apply" ]] && seen_put "$sha" flagged "$reason"
        log "  FLAG    ${name} (${reason})"
        ;;

      READY)
        if ! reason="$(gate "$c")"; then
            FLAGGED=$((FLAGGED+1)); record flagged "$name" "" "$reason"
            [[ "$MODE" == "apply" ]] && seen_put "$sha" flagged "$reason"
            log "  FLAG    ${name} (${reason})"
            continue
        fi
        p="$(jq -c .proposal <<<"$c")"
        folder="$(jq -r .folder <<<"$p")"
        newname="$(build_name "$p" "$(jq -r .ext <<<"$c")")"
        dst="${DOCS}/${folder}/${newname}"

        # 5. never clobber. A collision is the scheme's 4.4 versioning case
        # (-previous marker) and that is the owner's call, not ours.
        if [[ -e "$dst" ]]; then
            FLAGGED=$((FLAGGED+1)); record flagged "$name" "$folder/$newname" "DESTINATION_EXISTS"
            [[ "$MODE" == "apply" ]] && seen_put "$sha" flagged "DESTINATION_EXISTS"
            log "  FLAG    ${name} (destination exists: ${folder}/${newname})"
            continue
        fi

        if [[ "$MODE" == "apply" ]]; then
            if mv -n -- "$src" "$dst" 2>/dev/null \
               && [[ -f "$dst" && ! -e "$src" ]] \
               && [[ "$(sha256_of "$dst")" == "$sha" ]]; then   # read back: exists, source gone, content intact
                FILED=$((FILED+1)); record filed "$name" "$folder/$newname" "OK"
                log "  FILED   ${name} -> ${folder}/${newname}"
            else
                FAILED=$((FAILED+1)); record failed "$name" "$folder/$newname" "MV_VERIFY_FAILED"
                log "  FAIL    ${name} -> ${folder}/${newname} (read-back failed)"
            fi
        else
            FILED=$((FILED+1)); record would-file "$name" "$folder/$newname" "OK"
            log "  WOULD FILE ${name} -> ${folder}/${newname}"
        fi
        ;;
    esac
done < <(jq -c '.candidates[]' <<<"$(cat)")

[[ "$MODE" == "apply" ]] && seen_gc

jq -n --arg mode "$MODE" --argjson filed "$FILED" --argjson removed "$REMOVED" \
      --argjson flagged "$FLAGGED" --argjson failed "$FAILED" --argjson actions "$ACTIONS" \
      '{mode:$mode, filed:$filed, removed:$removed, flagged:$flagged, failed:$failed, actions:$actions}'
