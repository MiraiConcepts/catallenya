#!/bin/bash
# documents.intake.classify.sh — RETIRED FROM THE PIPELINE, kept as a test fixture.
#
# The nightly scan -> classify -> apply job it belonged to was replaced on 2026-07-31
# by documents.triage.sh, which classifies and stages a proposal you approve from a
# notification. Nothing schedules this any more; scan.sh, apply.sh and daily.sh are
# gone.
#
# It survives for exactly one reason: documents.intake.score.sh drives it to measure
# classification accuracy, and that harness is the only way to tell whether a prompt
# or model change made things worse. Both should go together once the scorer is
# rebuilt on the triage — at which point the enum-constrained schema below stops
# matching what production actually sends, which is free text.
#
# Reads a scan-shaped manifest on stdin, emits an adjudicated manifest on stdout.
#
# CONTAINMENT. This used to run through `claude -p`, and most of what lived here was
# a list of flags and traps needed to strip an agent harness back down to a pure
# function: --tools "StructuredOutput", --setting-sources '', --strict-mcp-config, and
# four undocumented ways the CLI could silently no-op or lie about its exit code.
#
# It now posts to /v1/messages directly (ai/scripts/ai.lib.sh, shared with capture).
# A plain Messages request has NO `tools` key, so there is no tool surface to lock
# down — no Read, no Bash, no Write, no filesystem, no MCP. Containment stopped being
# something this script arranges and became a property of the endpoint. The one rule
# that still needs stating: never add a `tools` key to ai_build_request.
#
# The schema is still enum-only by construction. There is no free-text field, so an
# injected document has no channel to write into. See build_schema below.
#
# Two calls per document, deliberately: classify, then an adversarial verify pass with
# a SEPARATE schema. A re-run would share the first pass's blind spots; handing the
# second pass the answer and asking it to find a contradiction does not.

set -uo pipefail
# shellcheck source=/zpool/catallenya/syncthing/scripts/documents.lib.sh
source "$(cd "$(dirname "$0")" && pwd)/documents.lib.sh"

# Opus: 2026-07-18 battery scored opus 24/24 (discounting one defensible qualifier),
# sonnet 23/24, haiku 19/24 incl. an INVENTED 2023-02-29. ~24 calls/year in anger —
# take the best. At ~6k input tokens per call that is well under $2/year, so cost is
# not a reason to move. Held at 4-8 through the API migration on purpose: the battery
# measured the model, and changing model and transport together would measure neither.
MODEL="claude-opus-4-8"
# The API default, set explicitly so it is visible and tunable rather than implied.
# A sweep down to "medium" is worth doing, but only against the scoring harness —
# accuracy here is the whole product.
EFFORT="high"
# Replaces the old --max-budget-usd 1.50 ceiling, which has no API equivalent. Input
# is bounded by MAX_PAGES (3) and MAX_PER_RUN (20); this bounds output. Adaptive
# thinking counts against it, and both schemas are tiny, so 4096 is generous.
# Truncation surfaces as stop_reason=max_tokens, which ai_extract rejects -> the
# document lands as CLASSIFY_FAILED and is retried tomorrow rather than misfiled.
MAX_TOKENS=4096

# Fail loudly and up front. Without this a missing binary fails every document
# individually — each flagged NEEDS_HUMAN, each notified — while the unit still exits
# 0. Same gate capture.triage.sh and immich.lib.sh use.
for _bin in jq curl base64 od; do
    command -v "$_bin" >/dev/null || die "missing required command: ${_bin}"
done
: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY not set (EnvironmentFile=/etc/ai.env)}"

# --- schema ----------------------------------------------------------------
# Enum-only by construction. `date` is the one string field and it is regex-bound:
# a date cannot traverse a path. The filename is assembled by apply.sh from these
# fields — the model never emits a string that becomes a path.

build_schema() {
    jq -n \
      --argjson folder "$(jq -c '.folder' "$VOCAB")" \
      --argjson doc_type "$(jq -c '.doc_type' "$VOCAB")" \
      --argjson qualifier "$(jq -c '.qualifier' "$VOCAB")" \
      --argjson owner "$(jq -c '.owner' "$VOCAB")" \
      '{
        type: "object",
        properties: {
          folder:      {type:"string", enum:$folder},
          doc_type:    {type:"string", enum:$doc_type},
          qualifier:   {type:"string", enum:$qualifier},
          owner:       {type:"string", enum:$owner},
          date:        {type:"string", pattern:"^[0-9]{4}(-[0-9]{2}(-[0-9]{2})?)?$"},
          date_source: {type:"string", enum:["printed_on_document","inferred","absent"]},
          needs_human: {type:"boolean"},
          reason_code: {type:"string", enum:[
            "OK","AMBIGUOUS_FOLDER","AMBIGUOUS_DATE","NO_DATE_PRINTED",
            "TYPE_NOT_IN_VOCAB","QUALIFIER_NOT_IN_VOCAB","OWNER_UNCLEAR",
            "UNREADABLE","MULTIPLE_DOCUMENTS","LOOKALIKE_FAMILY"]}
        },
        required: ["folder","doc_type","qualifier","owner","date","date_source","needs_human","reason_code"],
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

# --- invocation ------------------------------------------------------------

# $1=newline-separated png paths $2=prompt $3=schema -> schema-conforming JSON, or empty
#
# Thin by design: request construction, transport/retry and the response gate all live
# in ai.lib.sh, shared with capture.triage.sh. What stays here is what is actually
# documents' — which pages, which prompt, which schema.
#
# Send EVERY rasterised page, not just the first. A cover sheet on page 1 otherwise
# gets classified correctly as the wrong page — see the W-2 case in scan.sh. Page order
# is preserved through ai_build_request, and the prompt is appended last.
ask() {
    local pngs="$1" prompt="$2" schema="$3" msgf out pg
    local -a imgs=()
    while IFS= read -r pg; do [[ -n "$pg" ]] && imgs+=("$pg"); done <<<"$pngs"

    msgf="$(mktemp)"
    ai_build_request "$msgf" "$MODEL" "$EFFORT" "$MAX_TOKENS" "$schema" "$prompt" \
        "${imgs[@]}" || { rm -f "$msgf"; return 1; }

    # 0 = ok, 1 = fatal (bad key, bad request), 2 = transient and attempts exhausted.
    # The caller maps any non-zero to CLASSIFY_FAILED / VERIFY_FAILED, which is
    # deliberately NOT memoized in seen.json — so a provider outage costs one night,
    # not a permanently skipped document. What changed with the API move is that a
    # single 429 no longer costs anything at all: api_post rides it out in-run.
    local post_rc=0
    out="$(api_post "$msgf")" || post_rc=$?
    rm -f "$msgf"
    (( post_rc == 0 )) || return "$post_rc"

    ai_extract "$out"
}

# --- prompts ---------------------------------------------------------------

classify_prompt() {
    cat <<EOF
You are classifying one personal document for filing. The image is a rendered page of it.

Rules (from the owner's filing scheme):
- Pick the folder by the document's PURPOSE. Insurance = cards/policies/claims.
  Medical = clinical results and notes. Receipts = purchase invoices/receipts, INCLUDING
  medical ones (an invoice from a clinic is a receipt, not a medical record).
- invoice vs receipt: use WHAT THE DOCUMENT CALLS ITSELF. If it is headed "Invoice" or
  "Tax Invoice", doc_type is "invoice". If it is headed "Receipt", doc_type is "receipt".
  Do not reason about which word fits better — read the heading. (Both terms exist in the
  vocabulary and the distinction is otherwise arbitrary, so anchoring to the printed
  heading is what keeps naming consistent across runs and across years.)
- date: use the MOST PRECISE date PRINTED ON the document itself. Never guess from
  context. If only a month is printed, give YYYY-MM. If only a year, YYYY (a tax form's
  date is its tax year). If no date is printed at all, set date_source="absent" and
  needs_human=true.
- When SEVERAL dates are printed, prefer the report/issue/generated/statement date over
  received, collected, due, delivery, or payment dates. (Battery-verified 2026-07-18: a
  lab report printing "Received 06 Nov" and "Generated 07 Nov" must file as 11-07 — the
  owner adjudicated exactly this class by hand in past intakes.)
- Singapore documents print dates as DD/MM/YYYY: 08/07/2026 is 8 July, never August 7.
- owner: an EMAIL ADDRESS identifies a person just as a name does. A document addressed to
  owner@example.invalid is owner="self" even if no name appears anywhere on it. Online
  receipts and SaaS invoices routinely identify the customer only by the account email, and
  treating that as "no owner shown" would flag every one of them forever. Match the address
  itself, not the domain: protonmail.com is a mail provider, not a person.
- owner: "self" is the repository owner. Other known people are listed in the
  schema enum: REDACTED-PERSON-B, REDACTED-PERSON-C, REDACTED-PERSON-D.
  If the document belongs to someone not listed, set owner="unknown" and needs_human=true.
- Folder purpose guide: invoices/receipts from ANY vendor including clinics and hospitals
  -> 09_receipts-and-purchases. Clinical results, scan reports, discharge summaries,
  prescriptions -> 07_medical. Payslips, tax forms, bank/CPF statements ->
  05_finance-and-tax. Insurance cards/policies -> 06_insurance. Utility/telco/broadband
  bills and leases -> 08_housing-and-utilities.
- If the document type or issuer is not in the enums, set needs_human=true with the
  matching reason_code. Do NOT force a wrong value to fit.
- If unsure about anything, set needs_human=true. Being flagged is cheap; being misfiled
  is not.

Text extracted by OCR from the same page (may be imperfect; the image is authoritative):
---
${1:-(no OCR available)}
---
EOF
}

# PROMPT DESIGN — do not "strengthen" this back into an instruction to refute.
# The first version said "Your job is to REFUTE that proposal" + "default to refuted=true
# if you are unsure". It refuted 3/3 correct proposals with invented reasons (WRONG_OWNER
# on a document plainly reading ADDISON HO BOON WEE). That is instruction-following, not
# verification: told to refute, it refuted. A verifier that always says no has zero
# specificity, so nothing ever auto-files and the whole job is useless.
#
# Neutral, evidence-anchored framing discriminates correctly. Measured 2026-07-16 on the
# acme-physio invoice: correct proposal -> CONFIRMED; grossly wrong -> TYPE_MISMATCH; subtly
# wrong date (the OTHER invoice's real date) -> DATE_NOT_PRINTED_ON_DOCUMENT. That last
# case is the scan-swap class this gate exists for.
#
# The adversarial INTENT is preserved by "point to a specific contradiction you can see",
# not by telling the model whose side it is on.
verify_prompt() {
    cat <<EOF
Check a proposed filing against the document shown.

Proposed:
  folder:    $(jq -r .folder    <<<"$1")
  doc_type:  $(jq -r .doc_type  <<<"$1")
  qualifier: $(jq -r .qualifier <<<"$1")
  owner:     $(jq -r .owner     <<<"$1")
  date:      $(jq -r .date      <<<"$1")

"owner=self" means the document belongs to the repository owner — if the
document names him as the patient, customer, or addressee, then owner=self is CORRECT.
An EMAIL ADDRESS identifies him too: a document addressed to owner@example.invalid is
owner="self" and must NOT be refuted for lacking a printed name. Many online receipts show
only the account email. Do not refute on the domain alone — protonmail.com is a mail
provider, so another address at it would be a different person.

Check each claim against what you can actually see:
- folder matches the document's PURPOSE (a clinic's invoice is a receipt, not a medical
  record)
- the date appears PRINTED on the document and is the most precise one printed. A
  delivery date, a due date, or a photo timestamp is not the document's date. When
  several dates are printed, the report/issue/generated/statement date is the CORRECT
  choice over received/collected/due/payment dates — do not refute a proposal for
  preferring it. Singapore documents print DD/MM/YYYY.
- owner matches who the document belongs to
- doc_type matches what this actually is

Set refuted=true ONLY if you can point to a specific contradiction you can see in the
image. If every claim is consistent with the document, set refuted=false and
reason_code=CONFIRMED. Do not refute merely because you cannot fully verify something.
EOF
}

# --- main ------------------------------------------------------------------

MANIFEST="$(cat)"
SCHEMA="$(build_schema)"
OUT='[]'

while IFS= read -r c; do
    status="$(jq -r .status <<<"$c")"
    name="$(jq -r .file    <<<"$c")"

    if [[ "$status" != "READY" ]]; then
        OUT="$(jq --argjson c "$c" '. + [$c]' <<<"$OUT")"
        continue
    fi

    pngs="$(jq -r ".pngs[]?" <<<"$c")"
    ocrf="$(jq -r .ocr <<<"$c")"
    ocr=""
    [[ -n "$ocrf" && -f "$ocrf" ]] && ocr="$(head -c 4000 "$ocrf")"

    log "  CLASSIFY ${name}"
    prop="$(ask "$pngs" "$(classify_prompt "$ocr")" "$SCHEMA")" || {
        OUT="$(jq --argjson c "$c" '. + [($c + {status:"NEEDS_HUMAN", reason_code:"CLASSIFY_FAILED"})]' <<<"$OUT")"
        continue
    }

    # Adversarial, not a second opinion: a re-run shares the first pass's blind spots
    # (correlated errors, not independence). Hand it the ANSWER and ask it to attack.
    log "  VERIFY   ${name}"
    verd="$(ask "$pngs" "$(verify_prompt "$prop")" "$VERIFY_SCHEMA")" || {
        OUT="$(jq --argjson c "$c" '. + [($c + {status:"NEEDS_HUMAN", reason_code:"VERIFY_FAILED"})]' <<<"$OUT")"
        continue
    }

    OUT="$(jq --argjson c "$c" --argjson p "$prop" --argjson v "$verd" \
        '. + [($c + {proposal:$p, verdict:$v})]' <<<"$OUT")"
done < <(jq -c '.candidates[]' <<<"$MANIFEST")

jq -n --argjson m "$MANIFEST" --argjson c "$OUT" '$m + {candidates: $c}'
