#!/bin/bash
# documents.intake.scan.sh — phase 1 of 3. Fully deterministic: no LLM, no API call.
#
# Emits a JSON manifest of root candidates to stdout. Every status below is decided by
# code, never by a model:
#   READY        rasterised, ready for classification
#   DUPE         byte-identical to a filed document (jdupes) -> root copy dies in apply
#   NEEDS_HUMAN  unopenable/encrypted/unsupported -> flagged WITHOUT ever being transmitted
#   SKIP_SEEN    already adjudicated in a previous run -> silent, no LLM, no re-notify
#
# The openability check runs BEFORE rasterisation on purpose: a file locked precisely
# because it is sensitive (SG lab reports are commonly NRIC/DOB-protected) never leaves
# the machine at all. Deciding on metadata, not content, is the only way to get that.

set -uo pipefail
# shellcheck source=/zpool/catallenya/syncthing/scripts/documents.lib.sh
source "$(cd "$(dirname "$0")" && pwd)/documents.lib.sh"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

mkdir -p "$STATE_DIR" "$WORK_DIR"
seen_init

# --- gates -----------------------------------------------------------------

if ! st_folder_idle; then
    log "syncthing folder not idle; skipping this run (retry tomorrow)"
    echo '{"skipped":"syncthing_not_idle","candidates":[]}'
    exit 0
fi

# Collect stale seen.json entries HERE, not in apply.sh. apply only runs when there ARE
# candidates, so a night with an empty root never collected — and a file that was flagged,
# deleted, then re-uploaded byte-identical would match its own stale hash and be skipped as
# SKIP_SEEN forever: no classification, no ntfy, silent. Verified 2026-07-18.
# Placed AFTER the idle gate (mid-transfer means "absent from root" is unreliable) and
# BEFORE the seen_has lookups below, so stale entries are gone before anything is tested
# against them. Files still at root keep their entries, so flag-once still holds.
seen_gc

mapfile -t CANDS < <(list_candidates)
if (( ${#CANDS[@]} == 0 )); then
    log "no candidates at root"
    echo '{"skipped":"none","candidates":[]}'
    exit 0
fi

TRUNCATED=0
if (( ${#CANDS[@]} > MAX_PER_RUN )); then
    TRUNCATED=$(( ${#CANDS[@]} - MAX_PER_RUN ))
    log "CAP: ${#CANDS[@]} candidates, processing ${MAX_PER_RUN}, deferring ${TRUNCATED}"
    CANDS=("${CANDS[@]:0:$MAX_PER_RUN}")
fi

# --- corpus hash map -------------------------------------------------------
# 131 files / 152 MB hashes in 0.57s (measured 2026-07-16) — no cache, no
# (path,size,mtime) invalidation logic, nothing to go stale. Recompute nightly.

declare -A CORPUS_BY_HASH=()
while IFS= read -r path; do
    h="$(sha256_of "$path")"
    [[ -n "$h" ]] && CORPUS_BY_HASH["$h"]="$path"
done < <(list_corpus)
log "corpus: ${#CORPUS_BY_HASH[@]} files hashed"

# --- openability -----------------------------------------------------------
# Deterministic. A failure here costs no API call and no egress.

openable() { # $1=path -> echoes reason_code on failure
    local f="$1" ext="${1##*.}"
    case "${ext,,}" in
        pdf)
            pdfinfo "$f" >/dev/null 2>&1 || { echo "PDF_UNREADABLE_OR_ENCRYPTED"; return 1; }
            ;;
        zip)
            unzip -t "$f" >/dev/null 2>&1 || { echo "ZIP_ENCRYPTED_OR_CORRUPT"; return 1; }
            echo "ZIP_NEEDS_HUMAN"; return 1   # archives are never auto-filed
            ;;
        jpg|jpeg|png)
            identify "$f" >/dev/null 2>&1 || { echo "IMAGE_UNREADABLE"; return 1; }
            ;;
        *)
            echo "UNSUPPORTED_TYPE"; return 1
            ;;
    esac
    return 0
}

# --- rasterise -------------------------------------------------------------
# Counter-intuitive but well-evidenced: rasterising is a DEFENCE. A PDF text layer
# extracts white-on-white text byte-identically (invisibility is free), whereas in a
# rendered page, text a human can't see is text the model mostly can't see either
# (6px -> near-zero attack success). Measured: GPT-4o 36% attack success on text
# vs 8% on image. So we never touch the text layer.
# Unicode Tags (U+E0000-E007F) are the exception — ASCII smuggling never becomes
# pixels — but they cannot survive rasterisation to PNG either, which is the point.

# Rasterise up to MAX_PAGES pages, not just the first.
#
# Page 1 is often NOT the informative page. Proven case: the 7-page 2023 W-2 opens with a
# the payroll provider "Earning Summary" cover — no year, no employer, no W-2 form anywhere on it; the
# actual W-2 is on pages 2/4/6. Classifying from page 1 alone read "Earning Summary /
# the payroll provider", which is a *correct reading of the wrong page*. 45 of 96 filed PDFs are
# multi-page, so this is not a corner case.
#
# Cap at 3 because 75 of 96 filed PDFs are <= 3 pages, so it covers almost everything while
# bounding cost and CPU on the 90-page outliers. Later pages are boilerplate far more often
# than they are the document's identity.
rasterise() { # $1=src $2=out_prefix -> echoes one png path per line
    local f="$1" out="$2" ext="${1##*.}"
    case "${ext,,}" in
        pdf)
            pdftoppm -png -r 150 -f 1 -l "$MAX_PAGES" "$f" "$out" >/dev/null 2>&1 || return 1
            local p; p="$(ls "${out}"-*.png 2>/dev/null | sort -V)"
            [[ -n "$p" ]] && { printf '%s\n' "$p"; return 0; }
            return 1
            ;;
        jpg|jpeg|png)
            convert "$f" -flatten "${out}.png" >/dev/null 2>&1 || return 1
            echo "${out}.png"; return 0
            ;;
    esac
    return 1
}

# --- main ------------------------------------------------------------------

RESULTS='[]'
for name in "${CANDS[@]}"; do
    path="${DOCS}/${name}"

    if ! file_settled "$path"; then
        log "  DEFER  ${name} (ctime < ${MIN_AGE_SECONDS}s, or syncthing tmp present)"
        continue
    fi

    sha="$(sha256_of "$path")"
    [[ -n "$sha" ]] || { log "  SKIP   ${name} (unhashable)"; continue; }

    if seen_has "$sha"; then
        log "  SEEN   ${name} ($(seen_get "$sha" | jq -r .reason_code))"
        RESULTS="$(jq --arg f "$name" --arg s "$sha" --argjson a "$(seen_age_days "$sha")" \
            '. + [{file:$f, sha256:$s, status:"SKIP_SEEN", age_days:$a}]' <<<"$RESULTS")"
        continue
    fi

    if [[ -n "${CORPUS_BY_HASH[$sha]:-}" ]]; then
        log "  DUPE   ${name} == ${CORPUS_BY_HASH[$sha]##*/}"
        RESULTS="$(jq --arg f "$name" --arg s "$sha" --arg k "${CORPUS_BY_HASH[$sha]}" \
            '. + [{file:$f, sha256:$s, status:"DUPE", keeper:$k}]' <<<"$RESULTS")"
        continue
    fi

    if ! reason="$(openable "$path")"; then
        log "  HUMAN  ${name} (${reason}) — not transmitted"
        RESULTS="$(jq --arg f "$name" --arg s "$sha" --arg r "$reason" \
            '. + [{file:$f, sha256:$s, status:"NEEDS_HUMAN", reason_code:$r}]' <<<"$RESULTS")"
        continue
    fi

    pngs="$(rasterise "$path" "${WORK_DIR}/${sha:0:12}")" || {
        log "  HUMAN  ${name} (RASTERISE_FAILED) — not transmitted"
        RESULTS="$(jq --arg f "$name" --arg s "$sha" \
            '. + [{file:$f, sha256:$s, status:"NEEDS_HUMAN", reason_code:"RASTERISE_FAILED"}]' <<<"$RESULTS")"
        continue
    }

    # OCR every rasterised page and concatenate, so the classifier's text signal covers
    # the same pages as its images.
    ocr=""
    if command -v tesseract >/dev/null 2>&1; then
        ocr="${WORK_DIR}/${sha:0:12}.txt"; : > "$ocr"
        while IFS= read -r pg; do
            [[ -n "$pg" ]] || continue
            tesseract "$pg" stdout >> "$ocr" 2>/dev/null || true
        done <<<"$pngs"
        [[ -s "$ocr" ]] || ocr=""
    fi

    npages="$(grep -c . <<<"$pngs")"
    log "  READY  ${name} (${npages} page(s))"
    RESULTS="$(jq --arg f "$name" --arg s "$sha" --arg o "$ocr" --arg e "${name##*.}" \
        --argjson p "$(jq -R -s -c 'split("\n") | map(select(length>0))' <<<"$pngs")" \
        '. + [{file:$f, sha256:$s, status:"READY", pngs:$p, ocr:$o, ext:$e}]' <<<"$RESULTS")"
done

jq -n --argjson c "$RESULTS" --argjson t "$TRUNCATED" --argjson d "$DRY_RUN" \
      '{dry_run: ($d==1), truncated: $t, candidates: $c}'
