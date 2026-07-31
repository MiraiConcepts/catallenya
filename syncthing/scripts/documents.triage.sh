#!/bin/bash
# documents.triage.sh — drop a document at the root of master/documents, get a
# proposal you can approve. Replaces the scan/classify/apply nightly.
#
# Fired by documents.triage.path the moment a file lands at the root. Drains the
# whole root serially, then exits.
#
# HARD INVARIANT — every file MUST leave the root before this script exits, on
# every branch, success or failure. PathExistsGlob re-fires for as long as a file
# remains, so a document left in place hot-loops systemd and bills an API call per
# spin. This is the same invariant capture.triage.sh carries, learned the same way.
# Nothing below returns without having moved the file to staging/ or bin/.
#
# WHY THERE IS NO LONGER A VOCABULARY GATE. The old pipeline filed unsupervised, so
# safety came from a closed enum: every field the model could fill was a dropdown,
# and it could never emit a string that becomes a path. That cost a hand-edit of
# documents.vocab.json roughly every other document — 15 of 33 vendors in the corpus
# appear exactly once, and the tail is unbounded. A human tap now sits between the
# model and the filesystem, so the enum's job is done by the human, and the fields
# are free text. What replaces the enum is valid_segment() plus under_docs() in
# documents.lib.sh, and those are the load-bearing checks now. Do not weaken them.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/zpool/catallenya/syncthing/scripts/documents.lib.sh
source "${SELF_DIR}/documents.lib.sh"

MODEL="claude-opus-4-8"
EFFORT="high"
MAX_TOKENS=4096

# How long to wait for Syncthing to go quiet before giving up. The .path unit will
# re-fire while the file remains, so giving up is a retry rather than a loss — but
# waiting in-process turns what would be a spin into one sleeping run, and flock
# keeps the spins from overlapping. The service also carries a start limit as a
# backstop against a Syncthing that never settles.
QUIET_WAIT_S="${QUIET_WAIT_S:-180}"
QUIET_POLL_S=15

for _bin in jq curl base64 od sha256sum pdfinfo pdftoppm identify; do
    command -v "$_bin" >/dev/null || die "missing required command: ${_bin}"
done
: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY not set (EnvironmentFile=/etc/ai.env)}"

mkdir -p "$STATE_DIR" "$WORK_DIR" "$PROPOSALS_DIR" "$APPROVALS_DIR" "$STAGING_DIR" "$BIN_DIR"

# Serialise. A slow classification must not overlap the next .path fire.
exec 9>"$LOCK_FILE"
flock -n 9 || { log "another triage holds the lock; exiting"; exit 0; }

cleanup() { rm -f "${WORK_DIR:?}"/*.png "${WORK_DIR:?}"/*.txt 2>/dev/null || true; }
trap cleanup EXIT

# --- openability -----------------------------------------------------------
# Runs BEFORE rasterisation on purpose: a file locked precisely because it is
# sensitive (SG lab reports are commonly NRIC/DOB-protected) never leaves the
# machine at all. Deciding on metadata rather than content is the only way to get
# that property.
#
# THE IMAGE FORMATS ARE THE ONES THIS BOX CAN ALREADY RENDER. HEIC and HEIF are the
# iPhone defaults, so photographing a document with one was the largest real gap;
# TIFF is what scanners emit and WEBP what a browser saves. All verified to
# round-trip through ImageMagick here on 2026-07-31 — none of them needed a new
# dependency, which is why the list is this long and stops where it does.
#
# Anything NOT here is still staged and reported as UNSUPPORTED_TYPE rather than
# ignored: silence about a file you dropped is the worst outcome, worse than "I
# cannot read this".
openable() { # $1=path -> echoes reason_code on failure
    local f="$1" ext="${1##*.}"
    case "${ext,,}" in
        pdf)       pdfinfo "$f" >/dev/null 2>&1 || { echo "PDF_UNREADABLE_OR_ENCRYPTED"; return 1; } ;;
        zip)       unzip -t "$f" >/dev/null 2>&1 || { echo "ZIP_ENCRYPTED_OR_CORRUPT"; return 1; }
                   echo "ZIP_NEEDS_HUMAN"; return 1 ;;   # archives are never auto-proposed
        jpg|jpeg|png|heic|heif|webp|tiff|tif|avif)
                   identify "$f" >/dev/null 2>&1 || { echo "IMAGE_UNREADABLE"; return 1; } ;;
        *)         echo "UNSUPPORTED_TYPE"; return 1 ;;
    esac
    return 0
}

# Page 1 is often NOT the informative page — the 7-page W-2 opens with a cover
# sheet carrying no year, no employer and no form. Cap at MAX_PAGES: 75 of 96
# filed PDFs are within it, and later pages are boilerplate far more often than
# they are the document's identity.
rasterise() { # $1=src $2=out_prefix -> one png path per line
    local f="$1" out="$2" ext="${1##*.}"
    case "${ext,,}" in
        pdf) pdftoppm -png -r 150 -f 1 -l "$MAX_PAGES" "$f" "$out" >/dev/null 2>&1 || return 1
             local p; p="$(ls "${out}"-*.png 2>/dev/null | sort -V)"
             [[ -n "$p" ]] && { printf '%s\n' "$p"; return 0; }; return 1 ;;
        jpg|jpeg|png|heic|heif|webp|tiff|tif|avif)
             # -flatten collapses transparency and any multi-frame image to one
             # page. Without it a transparent PNG renders as black, and a
             # multi-page TIFF (which is what a sheet-feed scanner produces)
             # silently writes out-0.png, out-1.png and we would send neither.
             convert "$f"[0] -flatten "${out}.png" >/dev/null 2>&1 || return 1
             echo "${out}.png"; return 0 ;;
    esac
    return 1
}

# --- schema ----------------------------------------------------------------
# folder / doc_type / qualifier are free text bounded by SEGMENT_RE. owner stays an
# enum: it is four real people plus "unknown", it is genuinely closed, and it only
# ever becomes a filename suffix. `date` keeps its regex — and note the gate still
# range-checks a year-only value, because the regex happily accepts 0000.
build_schema() {
    jq -n --arg seg "${SEGMENT_RE#^}" --argjson owner "$(jq -c '.owner' "$VOCAB")" \
      '($seg | rtrimstr("$")) as $s |
       {
        type: "object",
        properties: {
          folder:        {type:"string", pattern:("^" + $s + "$")},
          folder_is_new: {type:"boolean"},
          doc_type:      {type:"string", pattern:("^" + $s + "$")},
          qualifier:     {type:"string", pattern:("^" + $s + "$")},
          owner:         {type:"string", enum:$owner},
          date:          {type:"string", pattern:"^[0-9]{4}(-[0-9]{2}(-[0-9]{2})?)?$"},
          date_source:   {type:"string", enum:["printed_on_document","inferred","absent"]},
          needs_human:   {type:"boolean"},
          reason_code:   {type:"string", enum:[
            "OK","AMBIGUOUS_FOLDER","AMBIGUOUS_DATE","NO_DATE_PRINTED",
            "OWNER_UNCLEAR","UNREADABLE","MULTIPLE_DOCUMENTS","LOOKALIKE_FAMILY"]}
        },
        required: ["folder","folder_is_new","doc_type","qualifier","owner","date",
                   "date_source","needs_human","reason_code"],
        additionalProperties: false
      }'
}

VERIFY_SCHEMA='{
  "type":"object",
  "properties":{
    "refuted":{"type":"boolean"},
    "reason_code":{"type":"string","enum":[
      "CONFIRMED","WRONG_FOLDER_BY_PURPOSE","DATE_NOT_PRINTED_ON_DOCUMENT",
      "DATE_IMPRECISE","WRONG_OWNER","LOOKALIKE_FAMILY","TYPE_MISMATCH","UNSURE"]}
  },
  "required":["refuted","reason_code"],
  "additionalProperties":false
}'

# --- model calls -----------------------------------------------------------

ask() { # $1=newline-separated pngs $2=prompt $3=schema
    local pngs="$1" prompt="$2" schema="$3" msgf out pg
    local -a imgs=()
    while IFS= read -r pg; do [[ -n "$pg" ]] && imgs+=("$pg"); done <<<"$pngs"
    msgf="$(mktemp)"
    ai_build_request "$msgf" "$MODEL" "$EFFORT" "$MAX_TOKENS" "$schema" "$prompt" \
        "${imgs[@]}" || { rm -f "$msgf"; return 1; }
    local rc=0
    out="$(api_post "$msgf")" || rc=$?
    rm -f "$msgf"
    (( rc == 0 )) || return "$rc"
    ai_extract "$out"
}

# The vocabulary is now a PREFERENCE, not a constraint. Without it the same vendor
# arrives as anthropic, Anthropic and anthropic-pbc across three years; with it as
# an enum, every new vendor needed a hand-edit. Naming it here gets the consistency
# without the treadmill.
classify_prompt() {
    cat <<EOF
You are naming and filing one personal document. The images are its rendered pages.

Return the folder it belongs in, what kind of document it is, who issued it, whose
it is, and its date. These become the path and filename:
  <folder>/<date>_<doc_type>_<qualifier>.<ext>

FOLDERS THAT EXIST. Use one of these unless the document genuinely belongs nowhere
in them:
$(find "$DOCS" -maxdepth 1 -type d -name '[0-9][0-9]_*' -printf '  %f\n' 2>/dev/null | sort)
If none fits, propose a NEW folder name and set folder_is_new=true. Follow the same
NN_lowercase-with-hyphens shape and pick the next free number. Do this sparingly —
a new folder the owner has to merge later is worse than a slightly loose fit. If an
existing folder is merely imperfect, use it and set folder_is_new=false.

VALUES ALREADY IN USE. Reuse one of these EXACTLY when it fits, so the same thing
is always spelled the same way. Coin a new one only when nothing here matches.
  doc_type:  $(jq -r '.doc_type | join(", ")' "$VOCAB")
  qualifier: $(jq -r '.qualifier | join(", ")' "$VOCAB")

FORMAT. folder, doc_type and qualifier must be lowercase, may contain only letters,
digits, dots, hyphens and underscores, must start with a letter or digit, and must
not contain "..". Use hyphens between words. qualifier is the issuer or vendor —
use "none" when the document has no meaningful issuer.

Rules (from the owner's filing scheme):
- Pick the folder by the document's PURPOSE. Insurance = cards/policies/claims.
  Medical = clinical results and notes. Receipts = purchase invoices/receipts,
  INCLUDING medical ones (an invoice from a clinic is a receipt, not a medical
  record).
- invoice vs receipt: use WHAT THE DOCUMENT CALLS ITSELF. If it is headed "Invoice"
  or "Tax Invoice", doc_type is "invoice". If headed "Receipt", it is "receipt".
  Do not reason about which word fits better — read the heading.
- date: use the MOST PRECISE date PRINTED ON the document itself. Never guess from
  context. Month only -> YYYY-MM. Year only -> YYYY (a tax form's date is its tax
  year). If no date is printed at all, set date_source="absent" and needs_human=true.
- When SEVERAL dates are printed, prefer the report/issue/generated/statement date
  over received, collected, due, delivery or payment dates. (Battery-verified
  2026-07-18: a lab report printing "Received 06 Nov" and "Generated 07 Nov" files
  as 11-07 — the owner adjudicated exactly this class by hand.)
- Singapore documents print dates as DD/MM/YYYY: 08/07/2026 is 8 July, never Aug 7.
- owner: an EMAIL ADDRESS identifies a person just as a name does. A document
  addressed to owner@example.invalid is owner="self" even if no name appears on
  it — online receipts routinely identify the customer only by account email. Match
  the address itself, not the domain: protonmail.com is a mail provider.
  "self" is the repository owner. Other known people are in the schema
  enum: REDACTED-PERSON-B, REDACTED-PERSON-C, REDACTED-PERSON-D.
  Someone not listed -> owner="unknown" and needs_human=true.
- Set needs_human=true when you are unsure of anything. It costs the owner a glance;
  a misfiling costs them a lost document.

Text extracted by OCR from the same pages (may be imperfect; the images are
authoritative):
---
${1:-(no OCR available)}
---
EOF
}

# PROMPT DESIGN — do not "strengthen" this back into an instruction to refute. The
# first version said "your job is to REFUTE that proposal" and it refuted 3/3
# correct proposals with invented reasons. That is instruction-following, not
# verification, and a verifier that always says no has zero specificity. The
# adversarial intent is preserved by "point to a specific contradiction you can
# see", not by telling the model whose side it is on.
verify_prompt() {
    cat <<EOF
Check a proposed filing against the document shown.

Proposed:
  folder:    $(jq -r .folder    <<<"$1")$( [[ "$(jq -r .folder_is_new <<<"$1")" == "true" ]] && printf '  (NEW folder)' )
  doc_type:  $(jq -r .doc_type  <<<"$1")
  qualifier: $(jq -r .qualifier <<<"$1")
  owner:     $(jq -r .owner     <<<"$1")
  date:      $(jq -r .date      <<<"$1")

"owner=self" means the document belongs to the repository owner — if the
document names him as patient, customer or addressee, owner=self is CORRECT. An
EMAIL ADDRESS identifies him too: a document addressed to owner@example.invalid
is owner="self" and must NOT be refuted for lacking a printed name. Do not refute on
the domain alone — protonmail.com is a mail provider, so another address there would
be a different person.

Check each claim against what you can actually see:
- folder matches the document's PURPOSE (a clinic's invoice is a receipt, not a
  medical record)
- the date appears PRINTED on the document and is the most precise one printed. A
  delivery date, a due date or a photo timestamp is not the document's date. When
  several are printed, the report/issue/generated/statement date is the CORRECT
  choice over received/collected/due/payment — do not refute a proposal for
  preferring it. Singapore documents print DD/MM/YYYY.
- owner matches who the document belongs to
- doc_type matches what this actually is

Set refuted=true ONLY if you can point to a specific contradiction you can see in
the image. If every claim is consistent with the document, set refuted=false and
reason_code=CONFIRMED. Do not refute merely because you cannot fully verify
something.
EOF
}

# --- staging ---------------------------------------------------------------

# stage_file <src> <desired-basename> -> echoes the staged path
# Never clobbers: a collision in staging gets -2, -3, ... Two documents can
# legitimately propose the same name (two invoices from one vendor on one day) and
# losing one to a silent overwrite is the outcome this whole pipeline exists to
# avoid.
stage_file() {
    local src="$1" want="$2" stem ext dest n=2
    stem="${want%.*}"; ext="${want##*.}"
    dest="${STAGING_DIR}/${want}"
    while [[ -e "$dest" ]]; do dest="${STAGING_DIR}/${stem}-${n}.${ext}"; n=$((n+1)); done
    mv -n -- "$src" "$dest" 2>/dev/null || return 1
    [[ -f "$dest" && ! -e "$src" ]] || return 1
    printf '%s' "$dest"
}

# record <uuid> <json>  — the proposal file is the durable half of the state.
# It is never deleted, which is what makes undo free: a discard against an already
# accepted record knows where the document went.
NEW_IDS=()
record() { printf '%s\n' "$2" > "${PROPOSALS_DIR}/${1}.json"; NEW_IDS+=("$1"); }

# --- drain the root --------------------------------------------------------

waited=0
until docs_quiet; do
    (( waited >= QUIET_WAIT_S )) && { log "syncthing still busy after ${waited}s; leaving root for the next fire"; exit 0; }
    sleep "$QUIET_POLL_S"; waited=$((waited + QUIET_POLL_S))
done

mapfile -t CANDS < <(list_candidates)
(( ${#CANDS[@]} )) || { log "nothing at root"; exit 0; }

# CAP THE RUN. Two model calls per document, unattended, with no ceiling is a bill
# waiting to happen — dropping a phone's worth of scans in at once would have spent
# hundreds of calls before anyone noticed. The remainder stays at root, so the .path
# unit re-fires and the next run takes the next MAX_PER_RUN. Truncation is logged and
# surfaced in the notification, never silent.
TRUNCATED=0
if (( ${#CANDS[@]} > MAX_PER_RUN )); then
    TRUNCATED=$(( ${#CANDS[@]} - MAX_PER_RUN ))
    log "CAP: ${#CANDS[@]} at root, taking ${MAX_PER_RUN}, deferring ${TRUNCATED} to the next run"
    CANDS=("${CANDS[@]:0:$MAX_PER_RUN}")
fi
log "draining ${#CANDS[@]} file(s) from root"

# The filed corpus, hashed, for duplicate detection. 135 files in well under a
# second, so there is no cache to invalidate and nothing to go stale.
declare -A CORPUS_BY_HASH=()
while IFS= read -r f; do CORPUS_BY_HASH["$(sha256_of "$f")"]="$f"; done < <(list_corpus)

STAGED=0; BINNED=0; BLOCKED=0

for name in "${CANDS[@]}"; do
    src="${DOCS}/${name}"
    [[ -f "$src" ]] || continue          # vanished under us; nothing to drain
    id="$(new_uuid)"
    sha="$(sha256_of "$src")"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    base="$(jq -nc --arg i "$id" --arg n "$name" --arg s "$sha" --arg t "$now" \
        '{id:$i, original_name:$n, sha256:$s, staged_at:$t}')"

    # A byte-identical copy of something already filed. To bin rather than deleted:
    # nothing in this pipeline destroys a document without a tap.
    if [[ -n "${CORPUS_BY_HASH[$sha]:-}" ]]; then
        keeper="${CORPUS_BY_HASH[$sha]#"${DOCS}/"}"
        if mv -n -- "$src" "${BIN_DIR}/${name}" 2>/dev/null; then
            BINNED=$((BINNED+1)); log "  DUPE   ${name} == ${keeper} -> bin/"
            record "$id" "$(jq -c --argjson b "$base" --arg k "$keeper" \
                '$b + {state:"binned", blocked:"DUPLICATE", duplicate_of:$k}' <<<'{}')"
        else
            log "  !! could not bin duplicate ${name}"
        fi
        continue
    fi

    # Unopenable: staged under its ORIGINAL name, never transmitted, no proposal.
    if ! reason="$(openable "$src")"; then
        if staged="$(stage_file "$src" "$name")"; then
            BLOCKED=$((BLOCKED+1)); log "  BLOCK  ${name} (${reason}) — not transmitted"
            record "$id" "$(jq -c --argjson b "$base" --arg r "$reason" --arg p "${staged#"${DOCS}/"}" \
                '$b + {state:"staged", blocked:$r, staged_path:$p}' <<<'{}')"
        else
            log "  !! could not stage ${name}"
        fi
        continue
    fi

    if ! pngs="$(rasterise "$src" "${WORK_DIR}/${sha:0:12}")"; then
        if staged="$(stage_file "$src" "$name")"; then
            BLOCKED=$((BLOCKED+1)); log "  BLOCK  ${name} (RASTERISE_FAILED) — not transmitted"
            record "$id" "$(jq -c --argjson b "$base" --arg p "${staged#"${DOCS}/"}" \
                '$b + {state:"staged", blocked:"RASTERISE_FAILED", staged_path:$p}' <<<'{}')"
        fi
        continue
    fi

    ocr=""
    if command -v tesseract >/dev/null 2>&1; then
        ocr="${WORK_DIR}/${sha:0:12}.txt"; : > "$ocr"
        while IFS= read -r pg; do [[ -n "$pg" ]] && tesseract "$pg" stdout >> "$ocr" 2>/dev/null || true; done <<<"$pngs"
        [[ -s "$ocr" ]] && ocr="$(head -c 4000 "$ocr")" || ocr=""
    fi

    log "  CLASSIFY ${name}"
    if ! prop="$(ask "$pngs" "$(classify_prompt "$ocr")" "$(build_schema)")"; then
        if staged="$(stage_file "$src" "$name")"; then
            BLOCKED=$((BLOCKED+1)); log "  BLOCK  ${name} (CLASSIFY_FAILED)"
            record "$id" "$(jq -c --argjson b "$base" --arg p "${staged#"${DOCS}/"}" \
                '$b + {state:"staged", blocked:"CLASSIFY_FAILED", staged_path:$p}' <<<'{}')"
        fi
        continue
    fi

    log "  VERIFY   ${name}"
    verd="$(ask "$pngs" "$(verify_prompt "$prop")" "$VERIFY_SCHEMA")" \
        || verd='{"refuted":false,"reason_code":"UNSURE"}'

    # --- assemble and validate the destination -----------------------------
    # Everything below is what the closed vocabulary used to guarantee for free.
    folder="$(jq -r .folder <<<"$prop")"; dtype="$(jq -r .doc_type <<<"$prop")"
    qual="$(jq -r .qualifier <<<"$prop")"; owner="$(jq -r .owner <<<"$prop")"
    ddate="$(jq -r .date <<<"$prop")"
    blocked=""; flags=()

    for seg in "$folder" "$dtype" "$qual"; do
        valid_segment "$seg" || { blocked="BAD_SEGMENT"; break; }
    done

    fname="${ddate}_${dtype}"
    [[ "$qual"  != "none" ]] && fname="${fname}_${qual}"
    [[ "$owner" != "self" ]] && fname="${fname}_${owner}"
    fname="${fname}.${name##*.}"
    dest="${DOCS}/${folder}/${fname}"

    [[ -z "$blocked" ]] && ! under_docs "$dest"        && blocked="ESCAPES_DOCS"
    [[ -z "$blocked" ]] && [[ -e "$dest" ]]            && blocked="DESTINATION_EXISTS"
    [[ -z "$blocked" ]] && ! valid_date "$ddate"       && blocked="IMPOSSIBLE_DATE"
    [[ -z "$blocked" ]] && [[ "$(jq -r .refuted <<<"$verd")" == "true" ]] \
        && blocked="REFUTED_$(jq -r .reason_code <<<"$verd")"

    # Flags do NOT block — they route the notification. A flagged document gets its
    # own message explaining why instead of riding in the batch, so "approve all"
    # only ever covers proposals nothing was noticed about.
    [[ "$(jq -r .folder_is_new  <<<"$prop")" == "true" ]] && flags+=("NEW_FOLDER")
    [[ "$(jq -r .needs_human    <<<"$prop")" == "true" ]] && flags+=("$(jq -r .reason_code <<<"$prop")")
    [[ "$(jq -r .date_source    <<<"$prop")" != "printed_on_document" ]] && flags+=("DATE_NOT_PRINTED")
    is_lookalike "$dtype" "$folder" && flags+=("LOOKALIKE_FAMILY")

    # Stage under the proposed name when we have one, so what you see in staging/ is
    # exactly what accepting will call it — and accepting becomes a plain move.
    want="$name"; [[ -z "$blocked" || "$blocked" == "DESTINATION_EXISTS" ]] && want="$fname"
    if ! staged="$(stage_file "$src" "$want")"; then
        log "  !! could not stage ${name} — LEFT AT ROOT, next fire will retry"
        continue
    fi

    record "$id" "$(jq -c --argjson b "$base" --argjson p "$prop" --argjson v "$verd" \
        --arg sp "${staged#"${DOCS}/"}" --arg dp "${folder}/${fname}" \
        --arg bl "$blocked" --argjson fl "$(printf '%s\n' "${flags[@]:-}" | jq -R -s -c 'split("\n")|map(select(length>0))')" \
        '$b + {state:"staged", proposal:$p, verdict:$v, staged_path:$sp,
               dest_path:$dp, blocked:(if $bl=="" then null else $bl end), flags:$fl}' <<<'{}')"

    if [[ -n "$blocked" ]]; then
        BLOCKED=$((BLOCKED+1)); log "  BLOCK  ${name} (${blocked}) -> staging/${staged##*/}"
    else
        STAGED=$((STAGED+1)); log "  STAGE  ${name} -> ${folder}/${fname}${flags[*]:+  [${flags[*]}]}"
    fi
done

log "staged ${STAGED}, blocked ${BLOCKED}, binned ${BINNED}"

# Assert the invariant rather than trusting it. Files deliberately deferred by the
# cap are EXPECTED to remain — the .path unit re-firing on them is how the next
# batch gets taken, and that loop terminates because each run removes MAX_PER_RUN.
# Anything left OVER that number means a branch above returned without moving its
# file, which is the version that spins forever at an API call per spin.
left="$(list_candidates | wc -l)"
(( left <= TRUNCATED )) \
    || log "  !! $(( left - TRUNCATED )) file(s) STILL AT ROOT beyond the cap — path unit will spin"
(( TRUNCATED > 0 )) && log "  ${TRUNCATED} deferred; the path unit will re-fire for them"

# --- notify ----------------------------------------------------------------
# THE BATCH ACCUMULATES, THE INDIVIDUALS DO NOT. Skip means "leave it in staging",
# so a clean proposal you ignored must reappear alongside the next arrival — that is
# the whole point of the batch and it is built from everything currently staged and
# clean, not from this run. Individual notifications go out once, for documents
# triaged in THIS run only: they each need their own decision, and re-sending three
# unresolved ones every time a fourth document arrives is how a useful notification
# becomes one you swipe away without reading. The batch's tail line names how many
# are sitting there, so nothing is invisible.

# The X-Documents header is required by the container on every route. It is not
# authentication — it forces a CORS preflight so a stray browser tab cannot fire
# these callbacks. clear=true dismisses the notification once the tap lands, which
# for Skip is the entire visible effect.
buttons() { # $1=id $2=1 if the Accept button should be offered
    local id="$1" b=""
    [[ "$2" == "1" ]] && b="http, Accept, ${BASE}/documents/${id}/accept, method=POST, headers.X-Documents=1, clear=true; "
    printf '%shttp, Discard, %s/documents/%s/discard, method=POST, headers.X-Documents=1, clear=true; http, Skip, %s/documents/%s/skip, method=POST, headers.X-Documents=1, clear=true' \
        "$b" "$BASE" "$id" "$BASE" "$id"
}

if ! BASE="$(documents_base_url)"; then
    log "  !! no base URL — proposals are staged but no notification was sent"
    exit 0
fi

# Everything still staged, partitioned. jq per file rather than one slurp: the
# directory is small and a malformed record should cost one document, not the run.
clean=(); flagged=(); blocked_ids=()
for f in "${PROPOSALS_DIR}"/*.json; do
    [[ -f "$f" ]] || continue
    [[ "$(jq -r '.state // ""' "$f")" == "staged" ]] || continue
    [[ "$(jq -r '.kind  // ""' "$f")" == "batch"  ]] && continue
    rid="$(basename "$f" .json)"
    if [[ "$(jq -r '.blocked // "null"' "$f")" != "null" ]]; then blocked_ids+=("$rid")
    elif [[ "$(jq -r '.flags | length' "$f")" != "0" ]];        then flagged+=("$rid")
    else clean+=("$rid"); fi
done

if (( ${#clean[@]} )); then
    # Retire the previous batch records first. A batch is a snapshot of what was
    # staged when the notification went out, so once a newer one exists the old one
    # is only useful if you tap its (still-live) message — which re-verification
    # already handles member by member. Without this they accumulate one per run
    # forever, and nothing distinguishes a live batch from a superseded one.
    for old in "${PROPOSALS_DIR}"/*.json; do
        [[ -f "$old" ]] || continue
        [[ "$(jq -r '.kind // ""' "$old")" == "batch" ]] || continue
        [[ "$(jq -r '.state // ""' "$old")" == "staged" ]] || continue
        jq -c '. + {state:"superseded"}' "$old" > "${old}.tmp" && mv "${old}.tmp" "$old"
    done
    bid="$(new_uuid)"
    body=""
    for rid in "${clean[@]}"; do
        f="${PROPOSALS_DIR}/${rid}.json"
        body+="$(md_escape "$(jq -r .original_name "$f")")
→ \`$(jq -r .dest_path "$f")\`

"
    done
    tail_note=""
    (( ${#flagged[@]} ))     && tail_note+="_${#flagged[@]} need$( (( ${#flagged[@]} == 1 )) && printf s ) a look_
"
    (( ${#blocked_ids[@]} )) && tail_note+="_${#blocked_ids[@]} cannot be filed_
"
    # Never let the cap hide work. Silently processing 20 of 200 reads as "that's
    # everything" and the other 180 look lost until someone opens the folder.
    (( TRUNCATED > 0 ))      && tail_note+="_${TRUNCATED} more still queued_
"
    jq -nc --arg i "$bid" --argjson m "$(printf '%s\n' "${clean[@]}" | jq -R -s -c 'split("\n")|map(select(length>0))')" \
        --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{id:$i, kind:"batch", state:"staged", members:$m, staged_at:$t}' > "${PROPOSALS_DIR}/${bid}.json"
    notify "$( (( ${#clean[@]} == 1 )) && echo "1 document ready" || echo "${#clean[@]} documents ready" )" \
        "" file_folder "${body}${tail_note}" "$(buttons "$bid" 1)"
    log "  notified batch of ${#clean[@]}"
fi

# Individuals, new-this-run only.
for rid in "${NEW_IDS[@]:-}"; do
    [[ -n "$rid" ]] || continue
    f="${PROPOSALS_DIR}/${rid}.json"
    [[ -f "$f" ]] || continue
    [[ "$(jq -r '.state' "$f")" == "staged" ]] || continue
    bl="$(jq -r '.blocked // "null"' "$f")"
    fl="$(jq -r '.flags // [] | join(", ")' "$f")"
    orig="$(md_escape "$(jq -r .original_name "$f")")"
    if [[ "$bl" != "null" ]]; then
        notify "Cannot file — $(jq -r .original_name "$f")" "" warning \
            "\`$(jq -r .staged_path "$f")\`

**${bl}**

Sitting in staging until you decide." "$(buttons "$rid" 0)"
    elif [[ -n "$fl" ]]; then
        notify "Needs a look — $(jq -r .original_name "$f")" "" mag \
            "${orig}
→ \`$(jq -r .dest_path "$f")\`

**${fl}**" "$(buttons "$rid" 1)"
    fi
done

exit 0
