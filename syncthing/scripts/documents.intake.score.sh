#!/bin/bash
# documents.intake.score.sh — measure classification accuracy against known-correct filings.
#
# WHY THIS EXISTS. The 2026-07-18 model battery is not reproducible: its scripts were
# cleaned up and only the result survives as prose ("12 real docs, 2 runs each: opus
# 24/24") in .claude/plans/documents-nightly-intake.md. When classification moved off
# `claude -p` onto the Anthropic API on 2026-07-30 the model stopped receiving ~27k
# tokens of ambient CLAUDE.md + skills context that the CLI had been loading on every
# call, and nothing existing could tell us whether that mattered. This can.
#
# THE ANSWER KEY IS THE FILENAMES — BUT ONLY PARTLY. apply.sh's build_name assembles
# <date>_<doc_type>[_<qualifier>][_<owner>].<ext> from closed enums, so a document the
# job filed is labelled by construction. Documents filed BY HAND before the job existed
# follow FILING-SCHEME §3, whose second field is a free-form *description*: real names in
# the corpus include "receipt_lenskart-spectacles-order" and "label_rtx3080-amazon-shipping"
# where the vocabulary says only "lenskart" and has no "label" at all. Measured on the
# default sample: doc_type is a vocabulary value 9 times in 11, qualifier only 4.
#
# So each field is scored against what the key can actually answer:
#   folder, date   always comparable — folder names ARE the enum, dates are dates.
#   doc_type, qual compared only when the true value is in the vocabulary. Where it is
#                  not, there IS no correct enum, and the right behaviour is to decline:
#                  needs_human=true with TYPE_/QUALIFIER_NOT_IN_VOCAB. That is scored as
#                  the DECL column, and it is not a consolation prize — "Do NOT force a
#                  wrong value to fit" is an explicit instruction in the classify prompt,
#                  and forcing one is how a document gets silently misfiled.
#   DECL           graded in ONE direction only. When every field IS in the vocabulary,
#                  declining is a false alarm and is scored. The reverse is NOT gradable:
#                  the schema enum-constrains doc_type and qualifier, so the model can
#                  only ever answer with a valid enum or decline — and a filename cannot
#                  say which was right. See the block above the DECL logic below.
#
# Scoring a hand-written description against a closed vocabulary would manufacture
# failures and produce a number that means nothing. Do not "fix" that by loosening the
# comparison — fix it by growing the vocabulary, which is a human decision (§8).
#
# WHAT IT SENDS, AND WHY THAT NEEDS SAYING. FILING-SCHEME.md §8 promises the filed
# corpus is "never read" — the nightly job only ever transmits files dropped at the
# root. Scoring breaks that promise on purpose and under supervision, so:
#   - it is NEVER run by a timer, only by hand;
#   - --folders defaults to the three the owner approved on 2026-07-30
#     (receipts, misc-and-reference, education) — no identity, immigration, medical,
#     finance, employment or insurance;
#   - --dry-run lists exactly what would be sent, and sends nothing;
#   - it is strictly read-only on the corpus. Nothing is renamed, moved or written.
# Widening --folders is an owner decision each time, not a default.
#
#   sudo systemd-run --wait --pipe --collect --uid=$(id -u) --gid=$(id -g) \
#     --property=EnvironmentFile=/etc/ai.env --working-directory=/zpool/catallenya \
#     /bin/bash syncthing/scripts/documents.intake.score.sh --sample 12
#
# Cost is two API calls per document (classify + the adversarial verify), ~3c each.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/zpool/catallenya/syncthing/scripts/documents.lib.sh
source "${SCRIPT_DIR}/documents.lib.sh"

# The owner-approved default scope. Deliberately not "everything minus the scary ones":
# an allowlist fails closed when a new folder appears, a denylist fails open.
FOLDERS="09_receipts-and-purchases 11_misc-and-reference 04_education"
SAMPLE=12
DRY_RUN=0
# Runs cost money, so the result has to outlive the terminal that produced it. The
# intended invocation is `systemd-run --pipe`, whose output goes to the caller's screen
# and NOT to the journal — the first real run was unreadable ten seconds after it
# finished. Defaults under intake-state: writable as carrein, not a restic target, not
# synced to peers (same reasoning as WORK_DIR in documents.lib.sh).
OUT="${STATE_DIR}/score.$(date -u +%Y%m%dT%H%M%SZ).txt"

while (( $# )); do
    case "$1" in
        --folders) FOLDERS="$2"; shift 2 ;;
        --sample)  SAMPLE="$2";  shift 2 ;;
        --out)     OUT="$2";     shift 2 ;;
        --dry-run) DRY_RUN=1;    shift ;;
        --help)
            printf 'usage: %s [--folders "NN_a NN_b"] [--sample N] [--out FILE] [--dry-run]\n' "${0##*/}"
            printf '  default folders: %s\n' "$FOLDERS"
            printf '  default --out:   %s/score.<timestamp>.txt\n' "$STATE_DIR"
            exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

# Everything from here to the summary goes to the terminal AND the transcript. Only
# enum values, dates and hash prefixes are ever printed — never document text — so this
# is safe to keep around under the same rule the synced intake log follows.
if (( ! DRY_RUN )); then
    mkdir -p "$STATE_DIR"
    exec > >(tee -a "$OUT") 2>&1
    printf '# %s  sample=%s  folders=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SAMPLE" "$FOLDERS"
fi

for _bin in jq pdftoppm; do command -v "$_bin" >/dev/null || die "missing: ${_bin}"; done
(( DRY_RUN )) || : "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY not set — see the systemd-run line in the header}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- corpus selection ------------------------------------------------------
# Only formats rasterise() handles. .docx and .zip are filed documents too, but the
# classifier never sees them either, so excluding them measures the real pipeline
# rather than inventing a harder one.
mapfile -t POOL < <(
    for f in $FOLDERS; do
        find "${DOCS}/${f}" -type f \
             \( -iname '*.pdf' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) \
             ! -name '.*' 2>/dev/null
    done | sort
)
(( ${#POOL[@]} )) || die "no scoreable documents in: ${FOLDERS}"

# Deterministic sample: sort by content hash, not shuf. A re-run after a prompt or model
# change must score the SAME documents, or the delta measures the sample, not the change.
mapfile -t PICKED < <(
    for p in "${POOL[@]}"; do printf '%s  %s\n' "$(sha256_of "$p")" "$p"; done \
        | sort | head -n "$SAMPLE" | cut -d' ' -f3-
)

# --- ground truth ----------------------------------------------------------
# <NN_folder>/[subdir/]<date>_<doc_type>_<qualifier>.<ext>. Files that do not parse to
# all four fields are skipped rather than guessed at — a wrong answer key is worse than
# a smaller sample.
truth() { # $1=abs path -> "folder|date|doc_type|qualifier" or empty
    local rel="${1#"${DOCS}"/}" base folder stem date_f type_f qual_f
    folder="${rel%%/*}"
    base="$(basename "$1")"; stem="${base%.*}"
    IFS='_' read -r date_f type_f qual_f <<<"$stem"
    [[ "$date_f" =~ ^[0-9]{4}(-[0-9]{2}(-[0-9]{2})?)?$ ]] || return 1
    [[ -n "$type_f" && -n "$qual_f" ]] || return 1
    printf '%s|%s|%s|%s' "$folder" "$date_f" "$type_f" "$qual_f"
}

# --- build the scan manifest -----------------------------------------------
# Mirrors documents.intake.scan.sh's READY shape, so the real classify.sh runs
# unmodified. Rasterisation flags are copied from scan.sh's rasterise() and must stay
# in step with it: scoring a different image than production sends measures nothing.
MANIFEST='[]'
declare -A TRUTH=()
SKIPPED=0

for src in "${PICKED[@]}"; do
    t="$(truth "$src")" || { SKIPPED=$((SKIPPED+1)); log "SKIP (unparseable name) ${src##*/}"; continue; }
    id="$(sha256_of "$src")"; id="${id:0:12}"
    TRUTH["$id"]="$t"

    if (( DRY_RUN )); then
        printf '  would send: %-58s [%s]\n' "${src#"${DOCS}"/}" "$t"
        continue
    fi

    case "${src,,}" in
        *.pdf) pdftoppm -png -r 150 -f 1 -l "$MAX_PAGES" "$src" "${WORK}/${id}" >/dev/null 2>&1 ;;
        *)     convert "$src" -flatten "${WORK}/${id}.png" >/dev/null 2>&1 ;;
    esac
    mapfile -t pages < <(ls "${WORK}/${id}"*.png 2>/dev/null | sort -V)
    (( ${#pages[@]} )) || { SKIPPED=$((SKIPPED+1)); log "SKIP (rasterise failed) ${src##*/}"; continue; }

    ocr=""
    if command -v tesseract >/dev/null 2>&1; then
        ocr="${WORK}/${id}.txt"; : > "$ocr"
        for pg in "${pages[@]}"; do tesseract "$pg" stdout >> "$ocr" 2>/dev/null || true; done
        [[ -s "$ocr" ]] || ocr=""
    fi

    MANIFEST="$(jq --arg f "$id" --arg o "$ocr" \
        --argjson p "$(printf '%s\n' "${pages[@]}" | jq -R -s -c 'split("\n")|map(select(length>0))')" \
        '. + [{file:$f, sha256:$f, status:"READY", pngs:$p, ocr:$o}]' <<<"$MANIFEST")"
done

if (( DRY_RUN )); then
    printf '\n%d document(s) would be sent, %d skipped. Nothing was transmitted.\n' \
        "$(( ${#PICKED[@]} - SKIPPED ))" "$SKIPPED"
    exit 0
fi

n_send="$(jq length <<<"$MANIFEST")"
(( n_send )) || die "nothing scoreable after rasterisation"
log "scoring ${n_send} document(s) — $(( n_send * 2 )) API calls"

ADJ="$(jq -n --argjson c "$MANIFEST" '{candidates:$c}' \
       | "${SCRIPT_DIR}/documents.intake.classify.sh")" || die "classify phase errored"

# --- score -----------------------------------------------------------------
# Per-field, with separate denominators: a field whose ground truth is outside the
# vocabulary is not scored for accuracy at all (shown as "-"), because there is no
# right answer to compare against. See the header for why that is not a dodge.
printf '\n%-13s %-4s %-5s %-5s %-5s %-5s  %s\n' DOC FLD DATE TYPE QUAL DECL NOTE
printf '%s\n' "-------------------------------------------------------------------------"

tot=0; ok_f=0; ok_d=0
n_t=0; ok_t=0; n_q=0; ok_q=0
n_decl=0; ok_decl=0; clean=0; ok_clean=0
refuted=0; false_refute=0

while IFS= read -r c; do
    id="$(jq -r .file <<<"$c")"
    # Guard rather than index blind: under `set -u` a missing key aborts the whole
    # scoring pass, and silently scoring against empty ground truth would be worse.
    [[ -n "${TRUTH[$id]:-}" ]] || { log "no ground truth for ${id} — skipping"; continue; }
    IFS='|' read -r g_fld g_dat g_typ g_qua <<<"${TRUTH[$id]}"
    p="$(jq -c '.proposal // empty' <<<"$c")"
    [[ -n "$p" ]] || { printf '%-13s %s\n' "$id" "NO PROPOSAL ($(jq -r '.reason_code // "?"' <<<"$c"))"; continue; }

    tot=$((tot+1))
    m_fld="$(jq -r .folder <<<"$p")"; m_typ="$(jq -r .doc_type  <<<"$p")"
    m_dat="$(jq -r .date   <<<"$p")"; m_qua="$(jq -r .qualifier <<<"$p")"
    m_need="$(jq -r .needs_human <<<"$p")"
    note=""

    # folder + date: always comparable.
    if [[ "$m_fld" == "$g_fld" ]]; then r_f=ok; ok_f=$((ok_f+1))
    else r_f=XX; note+="folder=${m_fld} "; fi
    if [[ "$m_dat" == "$g_dat" ]]; then r_d=ok; ok_d=$((ok_d+1))
    else r_d=XX; note+="date=${m_dat}(want ${g_dat}) "; fi

    # doc_type + qualifier: only where the key holds a vocabulary value.
    t_scoreable=0; q_scoreable=0
    if vocab_has doc_type "$g_typ"; then
        t_scoreable=1; n_t=$((n_t+1))
        if [[ "$m_typ" == "$g_typ" ]]; then r_t=ok; ok_t=$((ok_t+1))
        else r_t=XX; note+="type=${m_typ}(want ${g_typ}) "; fi
    else r_t="-"; fi
    if vocab_has qualifier "$g_qua"; then
        q_scoreable=1; n_q=$((n_q+1))
        if [[ "$m_qua" == "$g_qua" ]]; then r_q=ok; ok_q=$((ok_q+1))
        else r_q=XX; note+="qual=${m_qua}(want ${g_qua}) "; fi
    else r_q="-"; fi

    # DECL — scored in ONE direction only, and the asymmetry is the point.
    #
    # An earlier version scored this both ways and was wrong on the second. It reasoned:
    # "the filename's qualifier is not in the vocabulary, therefore no valid enum exists,
    # therefore the classifier should have declined" — and marked two correct answers as
    # "FORCED a value". But the filename holds a free-form human description while the
    # vocabulary holds the enum: "rtx3080-amazon-shipping" has a perfectly good enum in
    # `amazon`, and "acme-orthopaedics-postop-review" in `acme-orthopaedics`. The
    # model picking those was right, not forced.
    #
    # The deeper reason it can never be scored that way: doc_type and qualifier are
    # ENUM-CONSTRAINED in the schema, so the model *cannot* emit an out-of-vocabulary
    # value. Its only choices are a valid enum or needs_human. Whether declining was
    # correct therefore depends on what the document actually says, which a filename
    # cannot tell us. So it is reported, not graded.
    if (( t_scoreable && q_scoreable )); then
        # The reverse direction IS sound: every field the classifier needs demonstrably
        # exists in the vocabulary, so flagging here is a false alarm that leaves the
        # document sitting at root for a human who has nothing to decide.
        clean=$((clean+1))
        if [[ "$m_need" == "false" ]]; then r_dc=ok; ok_clean=$((ok_clean+1))
        else r_dc=XX; note+="[false flag: $(jq -r .reason_code <<<"$p")] "; fi
    else
        n_decl=$((n_decl+1))
        if [[ "$m_need" == "true" ]]; then r_dc="flag"; ok_decl=$((ok_decl+1))
        else r_dc="ans"; fi
    fi

    # The verify pass refuting a proposal that was in fact correct is a false flag: the
    # document sits at root for a human instead of filing itself. It is the failure mode
    # the neutral verify_prompt wording exists to avoid, so count it separately.
    if [[ "$(jq -r '.verdict.refuted // false' <<<"$c")" == "true" ]]; then
        refuted=$((refuted+1))
        if [[ "$r_f" == ok && "$r_d" == ok && "$r_t" != XX && "$r_q" != XX ]]; then
            false_refute=$((false_refute+1))
            note+="[FALSE REFUTE: $(jq -r .verdict.reason_code <<<"$c")] "
        fi
    fi

    printf '%-13s %-4s %-5s %-5s %-5s %-5s  %s\n' "$id" "$r_f" "$r_d" "$r_t" "$r_q" "$r_dc" "$note"
done < <(jq -c '.candidates[]' <<<"$ADJ")

pct() { (( $2 )) && printf '%d/%d (%d%%)' "$1" "$2" $(( $1 * 100 / $2 )) || printf 'n/a'; }
printf '%s\n' "-------------------------------------------------------------------------"
printf 'scored %d document(s)\n' "$tot"
printf '  folder      %s      (always comparable)\n'            "$(pct "$ok_f" "$tot")"
printf '  date        %s      (always comparable)\n'            "$(pct "$ok_d" "$tot")"
printf '  doc_type    %s      (of those with an in-vocab key)\n' "$(pct "$ok_t" "$n_t")"
printf '  qualifier   %s      (of those with an in-vocab key)\n' "$(pct "$ok_q" "$n_q")"
printf '  did NOT false-flag when everything was in vocab: %s\n' "$(pct "$ok_clean" "$clean")"
printf '  reported only (see header): %d of %d docs whose key is out-of-vocab were flagged\n' \
    "$ok_decl" "$n_decl"
printf 'verify refuted %d; %d of those were FALSE refutes of correct proposals\n' "$refuted" "$false_refute"
