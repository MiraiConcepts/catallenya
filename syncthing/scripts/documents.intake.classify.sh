#!/bin/bash
# documents.intake.classify.sh — phase 2 of 3. The ONLY step that touches a model.
#
# Reads the scan manifest on stdin, emits an adjudicated manifest on stdout.
#
# CONTAINMENT — every line of this is load-bearing, do not "simplify":
#
#   --tools "StructuredOutput"   The model gets exactly ONE tool, and it IS the answer
#                                channel. No Read, no Bash, no Write, no filesystem, no
#                                network. Image in via stream-json, schema-conforming
#                                JSON out. A pure function.
#                                VERIFIED 2026-07-16: system/init reports
#                                tools:['StructuredOutput'], mcp_servers:[].
#   --setting-sources ''         Without it, a claude -p under /zpool/catallenya inherits
#                                that dir's settings.local.json. Permission rules UNION
#                                across scopes — --allowedTools CANNOT narrow them.
#   --strict-mcp-config          -> mcp_servers: []
#   --json-schema                Enum-only. There is NO free-text field, so there is no
#                                channel for an injected document to write into.
#
# TRAPS, all verified, none documented upstream:
#   1. --tools "" and --json-schema are MUTUALLY EXCLUSIVE. --json-schema is implemented
#      AS the StructuredOutput tool, so --tools "" disables it — silently:
#      structured_output:null, is_error:false, terminal_reason:"completed". Name it.
#   2. --allowedTools "" exposes 31 tools (MORE than baseline, incl. Bash/Write/Read).
#      An empty allowlist means "no restriction", not "nothing allowed". Never use it.
#   3. --input-format stream-json requires --output-format stream-json, and the stream
#      MUST be held open: on immediate EOF it silently no-ops (rc=0, zero bytes, no
#      error). Hence the `sleep` in the subshell below.
#   4. A denied tool call exits 0 with is_error:false and subtype:"success". Auth failure
#      also reports subtype:"success". NEVER discriminate on subtype.

set -uo pipefail
# shellcheck source=/zpool/catallenya/syncthing/scripts/documents.lib.sh
source "$(cd "$(dirname "$0")" && pwd)/documents.lib.sh"

CLAUDE_BIN="/home/carrein/.local/bin/claude"
# Opus: 2026-07-18 battery scored opus 24/24 (discounting one defensible qualifier),
# sonnet 23/24, haiku 19/24 incl. an INVENTED 2023-02-29. ~24 calls/year in anger —
# take the best. Quota-weight at this volume is negligible.
MODEL="claude-opus-4-8"
BUDGET="1.50"   # opus per-call cost is higher; 2 passes/doc, 3 pages each

command -v jq >/dev/null || die "jq not found"
[[ -x "$CLAUDE_BIN" ]] || die "claude not found at $CLAUDE_BIN"

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

# $1=newline-separated png paths $2=prompt $3=schema -> structured_output JSON, or empty
ask() {
    local pngs="$1" prompt="$2" schema="$3" out so b64f msgf contentf tmpf pg
    # Send EVERY rasterised page, not just the first. A cover sheet on page 1 otherwise
    # gets classified correctly as the wrong page — see the W-2 case in scan.sh.
    # EVERYTHING carrying base64 goes via a FILE, never a command-line argument. A page is
    # ~270KB of base64 and three of them is ~800KB — well past ARG_MAX. This bit three
    # times during development ("Argument list too long"), on --arg, then on --argjson for
    # the accumulated array. Both the per-page blob AND the growing content array must be
    # file-passed; --rawfile and --slurpfile are the tools.
    b64f="$(mktemp "${WORK_DIR}/b64.XXXXXX")"
    msgf="$(mktemp "${WORK_DIR}/msg.XXXXXX")"
    contentf="$(mktemp "${WORK_DIR}/content.XXXXXX")"
    tmpf="$(mktemp "${WORK_DIR}/tmp.XXXXXX")"
    echo '[]' > "$contentf"
    local n=0
    while IFS= read -r pg; do
        [[ -n "$pg" && -f "$pg" ]] || continue
        base64 -w0 "$pg" > "$b64f"
        jq -c --rawfile b64 "$b64f" \
            '. + [{type:"image", source:{type:"base64", media_type:"image/png", data:($b64|rtrimstr("\n"))}}]' \
            "$contentf" > "$tmpf" && mv "$tmpf" "$contentf"
        n=$((n+1))
    done <<<"$pngs"
    if (( n == 0 )); then
        log "    !! no pages to send"; rm -f "$b64f" "$msgf" "$contentf" "$tmpf"; return 1
    fi
    # -c is REQUIRED: stream-json input is NDJSON, one object per LINE. jq's default
    # pretty-printing splits the object across lines and the CLI rejects each fragment
    # ("Error parsing streaming input line: {").
    jq -nc --slurpfile c "$contentf" --arg t "$prompt" \
        '{type:"user", message:{role:"user", content:($c[0] + [{type:"text", text:$t}])}}' > "$msgf"
    rm -f "$b64f" "$contentf" "$tmpf"

    # Trap 3: the stream must stay open or this silently no-ops.
    out="$( ( cat "$msgf"; sleep 10 ) | timeout 180 "$CLAUDE_BIN" -p \
        --input-format stream-json --output-format stream-json --verbose \
        --tools "StructuredOutput" --json-schema "$schema" \
        --setting-sources '' --strict-mcp-config --no-session-persistence \
        --model "$MODEL" --max-turns 3 --max-budget-usd "$BUDGET" 2>&1 )"
    rm -f "$msgf"

    # A run that produced no result line looks identical to success at the exit code.
    # Assert we actually got one.
    local result_line
    result_line="$(grep -m1 '"type":"result"' <<<"$out")" || { log "    !! no result message"; return 1; }

    # Trap 4: gate on terminal_reason + is_error + permission_denials. Never subtype.
    local is_err term denials tools_used
    is_err="$(jq -r '.is_error'         <<<"$result_line")"
    term="$(jq -r '.terminal_reason'    <<<"$result_line")"
    denials="$(jq -r '.permission_denials | length' <<<"$result_line")"
    so="$(jq -c '.structured_output // empty' <<<"$result_line")"

    if [[ "$is_err" != "false" || "$term" != "completed" || "$denials" != "0" ]]; then
        log "    !! is_error=${is_err} terminal=${term} denials=${denials}"
        return 1
    fi
    # Belt-and-braces on a one-word dependency: if --tools or --setting-sources ever get
    # dropped in an edit, the model has real tools again. Anything beyond the single
    # StructuredOutput call is an anomaly — fail loud rather than proceed.
    tools_used="$(grep -c '"type":"tool_use"' <<<"$out" || true)"
    if (( tools_used > 1 )); then
        log "    !! ${tools_used} tool calls — expected exactly 1 (StructuredOutput). Containment may be broken."
        return 1
    fi
    [[ -n "$so" ]] || { log "    !! structured_output null (--tools/--json-schema collision?)"; return 1; }
    printf '%s' "$so"
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
