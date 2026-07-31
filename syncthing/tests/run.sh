#!/usr/bin/env bash
# Regression tests for the documents propose-and-approve pipeline.
#
# Everything here runs offline and free: the model half is driven against
# ai/tests/sink.py, which serves scripted payloads, so a full triage costs nothing
# and a 429 can be summoned on demand.
#
# TWO CLASSES OF CASE DOMINATE, and both are here because they are the failures that
# actually cost something:
#
#   Path safety. The closed vocabulary used to guarantee that a model-chosen value
#   could never become a path. With free text that guarantee lives in valid_segment()
#   and under_docs(), so those are tested against traversal, absolute paths, casing
#   and length rather than trusted.
#
#   The drain invariants. Both .path units re-fire while their glob matches, so a
#   branch that returns without moving a file (triage) or deleting a marker (apply)
#   spins systemd — and the triage spends an opus call per spin. Every failure branch
#   is asserted to drain.
#
#   bash syncthing/tests/run.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "${SELF_DIR}/../scripts" && pwd)"
SINK="$(cd "${SELF_DIR}/../../ai/tests" && pwd)/sink.py"

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$3" "$2"; }
has()  { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "contains $3" "$2"; }

TMP="$(mktemp -d)"
SINK_PID=""
cleanup() { [[ -n "$SINK_PID" ]] && kill "$SINK_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# Source the library against a scratch tree so nothing here can touch the real corpus.
export DOCS="${TMP}/docs" STATE_DIR="${TMP}/state"
# shellcheck source=../scripts/documents.lib.sh
source "${SCRIPT_DIR}/documents.lib.sh"

fresh() { # rebuild the scratch tree
    rm -rf "${TMP}/docs" "${TMP}/state"
    mkdir -p "${TMP}/docs/09_receipts-and-purchases" "${TMP}/docs/staging" \
             "${TMP}/docs/bin" "${TMP}/state/proposals" "${TMP}/state/approvals"
}

# ------------------------------------------------------------------ path safety
echo "valid_segment"

for good in invoice anthropic 09_receipts-and-purchases a a1 x.y-z_2 acme-physiotherapy; do
    valid_segment "$good" && ok "accepts ${good}" || bad "accepts ${good}" ok reject
done

# Each of these is a way a free-text field becomes a path. The enum used to make
# them unrepresentable; now this function does.
for evil in '..' '../etc' 'a/b' '/etc/passwd' '.hidden' '' 'Anthropic' 'a..b' \
            'a b' 'café' '-leading-hyphen' '.'; do
    valid_segment "$evil" && bad "rejects '${evil}'" reject ok || ok "rejects '${evil}'"
done
long="$(printf 'a%.0s' {1..64})"
valid_segment "$long"  && ok "accepts 64 chars"        || bad "accepts 64 chars" ok reject
valid_segment "${long}a" && bad "rejects 65 chars" reject ok || ok "rejects 65 chars"

echo "under_docs"
fresh
is "a normal destination is inside"  "$(under_docs "${DOCS}/09_receipts-and-purchases/x.pdf" && echo in)" "in"
is "traversal is outside"            "$(under_docs "${DOCS}/../../../etc/passwd" && echo in)" ""
is "an absolute path is outside"     "$(under_docs "/etc/passwd" && echo in)" ""
is "DOCS itself is not 'under' DOCS" "$(under_docs "${DOCS}" && echo in)" ""

# ------------------------------------------------------------------- valid_date
# The schema regex accepts 2023-02-29 (the 2026-07-18 battery produced exactly
# that) and year 0000, which filed silently until 2026-07-30.
echo "valid_date"
for d in 2021 2027 2024-02-29 2021-09-20 2021-01 2021-12; do
    valid_date "$d" && ok "accepts ${d}" || bad "accepts ${d}" ok reject
done
for d in 0000 9999 1899 2023-02-29 2021-13 2021-00 abc '' 202 20211; do
    valid_date "$d" && bad "rejects ${d}" reject ok || ok "rejects ${d}"
done

# --------------------------------------------------------------------- triage
# Driven against the sink: two payloads per document, classify then verify.
echo "triage — staging and the drain invariant"

OKPROP='{"folder":"09_receipts-and-purchases","folder_is_new":false,"doc_type":"invoice","qualifier":"anthropic","owner":"self","date":"2026-07-08","date_source":"printed_on_document","needs_human":false,"reason_code":"OK"}'
VERIFY='{"refuted":false,"reason_code":"CONFIRMED"}'

triage() { # $1=sink codes; $2..=payloads -> runs the triage over the scratch tree
    local codes="$1"; shift
    : > "${TMP}/port"
    python3 "$SINK" "$codes" "$@" > "${TMP}/port" &
    SINK_PID=$!
    for _ in $(seq 20); do [[ -s "${TMP}/port" ]] && break; sleep 0.2; done
    DOCS="${TMP}/docs" STATE_DIR="${TMP}/state" SKIP_SYNCTHING_GATE=1 \
      API_URL="http://127.0.0.1:$(cat "${TMP}/port")/" ANTHROPIC_API_KEY=sink \
      API_RETRY_BASE_S=1 DOCUMENTS_REVERSE_PROXY_PORT=1 \
      bash "${SCRIPT_DIR}/documents.triage.sh" >"${TMP}/out" 2>&1
    kill "$SINK_PID" 2>/dev/null; wait "$SINK_PID" 2>/dev/null; SINK_PID=""
}
mkpdf() { convert -size 400x500 xc:white -pointsize 20 -annotate +20+40 "$2" "${DOCS}/$1" 2>/dev/null; }
rootn()  { find "${DOCS}" -maxdepth 1 -type f | wc -l; }
propfield() { jq -r "$1" "${TMP}"/state/proposals/*.json 2>/dev/null | grep -v '^null$' | head -1; }

fresh; mkpdf doc.pdf Invoice; triage 200 "$OKPROP" "$VERIFY"
is "happy path drains root"        "$(rootn)" "0"
is "staged under the proposed name" "$(ls "${DOCS}/staging")" "2026-07-08_invoice_anthropic.pdf"
is "destination recorded"          "$(propfield .dest_path)" "09_receipts-and-purchases/2026-07-08_invoice_anthropic.pdf"

# THE EXPENSIVE FAILURE. Each of these left a file at root in an earlier draft, and
# a file at root means the .path unit fires again and buys another opus call.
for case in "401:fatal API" "503,503,503:exhausted API"; do
    codes="${case%%:*}"; label="${case#*:}"
    fresh; mkpdf doc.pdf Invoice; triage "$codes" "$OKPROP" "$VERIFY"
    is "${label} still drains root" "$(rootn)" "0"
    is "${label} is recorded blocked" "$(propfield .blocked)" "CLASSIFY_FAILED"
done

fresh; mkpdf doc.pdf Invoice
triage 200 "$(jq -c '.folder="../../../etc"' <<<"$OKPROP")" "$VERIFY"
is "traversal drains root"     "$(rootn)" "0"
is "traversal is blocked"      "$(propfield .blocked)" "BAD_SEGMENT"

fresh; mkpdf doc.pdf Invoice
triage 200 "$(jq -c '.date="0000"' <<<"$OKPROP")" "$VERIFY"
is "year 0000 is blocked"      "$(propfield .blocked)" "IMPOSSIBLE_DATE"

fresh; printf 'not a pdf' > "${DOCS}/doc.pdf"; triage 200 "$OKPROP" "$VERIFY"
is "unopenable drains root"    "$(rootn)" "0"
is "unopenable never transmitted" "$(propfield .blocked)" "PDF_UNREADABLE_OR_ENCRYPTED"
is "unopenable keeps its name" "$(ls "${DOCS}/staging")" "doc.pdf"

fresh; mkpdf doc.pdf Invoice; cp "${DOCS}/doc.pdf" "${DOCS}/09_receipts-and-purchases/old.pdf"
triage 200 "$OKPROP" "$VERIFY"
is "duplicate drains root"     "$(rootn)" "0"
is "duplicate goes to bin"     "$(ls "${DOCS}/bin")" "doc.pdf"
is "duplicate is not deleted"  "$([ -f "${DOCS}/bin/doc.pdf" ] && echo kept)" "kept"

fresh; mkpdf doc.pdf Invoice; touch "${DOCS}/09_receipts-and-purchases/2026-07-08_invoice_anthropic.pdf"
triage 200 "$OKPROP" "$VERIFY"
is "collision is blocked"      "$(propfield .blocked)" "DESTINATION_EXISTS"

# A flagged proposal must still be staged and filable — flags route the
# notification, they do not block.
fresh; mkpdf doc.pdf Invoice
triage 200 "$(jq -c '.folder="12_new-thing"|.folder_is_new=true' <<<"$OKPROP")" "$VERIFY"
is "new folder is not blocked" "$(propfield '.blocked // "none"')" "none"
has "new folder is flagged"    "$(propfield '.flags|join(",")')" "NEW_FOLDER"

# --------------------------------------------------------------------- apply
echo "apply — the state machine"

seed() { # one staged document with a known hash
    fresh
    echo "content" > "${DOCS}/staging/a.pdf"
    ID=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
    jq -nc --arg i "$ID" --arg s "$(sha256_of "${DOCS}/staging/a.pdf")" \
      '{id:$i,original_name:"a.pdf",sha256:$s,state:"staged",staged_path:"staging/a.pdf",
        dest_path:"09_receipts-and-purchases/a.pdf",blocked:null,flags:[]}' \
      > "${STATE_DIR}/proposals/${ID}.json"
}
tap() { # $1=action -> run apply
    jq -nc --arg a "$1" '{action:$a,at:"t"}' > "${STATE_DIR}/approvals/${ID}.json"
    DOCS="${TMP}/docs" STATE_DIR="${TMP}/state" bash "${SCRIPT_DIR}/documents.apply.sh" \
      >"${TMP}/aout" 2>&1
}
state() { jq -r .state "${STATE_DIR}/proposals/${ID}.json"; }
markers() { find "${STATE_DIR}/approvals" -name '*.json' | wc -l; }

seed
tap accept;  is "staged -> accept -> filed"   "$(state)" "filed"
is "the document is at the destination" "$([ -f "${DOCS}/09_receipts-and-purchases/a.pdf" ] && echo yes)" "yes"
tap discard; is "filed -> discard -> binned (UNDO)" "$(state)" "binned"
tap skip;    is "binned -> skip -> staged"    "$(state)" "staged"
tap accept;  is "staged -> accept -> filed"   "$(state)" "filed"
tap skip;    is "filed -> skip -> staged"     "$(state)" "staged"
tap discard; is "staged -> discard -> binned" "$(state)" "binned"
tap accept;  is "binned -> accept -> filed"   "$(state)" "filed"
is "every tap drained its marker" "$(markers)" "0"

echo "apply — refusals"
seed; echo tampered > "${DOCS}/staging/a.pdf"; tap accept
is  "changed contents refuse"        "$(state)" "staged"
has "and say so"                     "$(cat "${TMP}/aout")" "contents changed"
is  "refusal still drains marker"    "$(markers)" "0"

seed; rm "${DOCS}/staging/a.pdf"; tap accept
is  "vanished document refuses"      "$(markers)" "0"
has "and says so"                    "$(cat "${TMP}/aout")" "no longer where it was"

seed; touch "${DOCS}/09_receipts-and-purchases/a.pdf"; tap accept
is  "occupied destination refuses"   "$(state)" "staged"
has "and says so"                    "$(cat "${TMP}/aout")" "already at"

seed
jq -c '.blocked="PDF_UNREADABLE_OR_ENCRYPTED"' "${STATE_DIR}/proposals/${ID}.json" > "${TMP}/b" \
  && mv "${TMP}/b" "${STATE_DIR}/proposals/${ID}.json"
tap accept
is  "a blocked record cannot be accepted" "$(state)" "staged"

seed; jq -nc '{}' > "${STATE_DIR}/approvals/${ID}.json"
DOCS="${TMP}/docs" STATE_DIR="${TMP}/state" bash "${SCRIPT_DIR}/documents.apply.sh" >/dev/null 2>&1
is "an unreadable marker is dropped, not retried" "$(markers)" "0"

echo "apply — batches"
fresh
BATCH=99999999-0000-4000-8000-000000000000; MEMBERS=()
for n in 1 2 3; do
    m="1111111${n}-0000-4000-8000-000000000000"; MEMBERS+=("$m")
    echo "doc${n}" > "${DOCS}/staging/doc${n}.pdf"
    jq -nc --arg i "$m" --arg s "$(sha256_of "${DOCS}/staging/doc${n}.pdf")" --arg n "$n" \
      '{id:$i,original_name:("doc"+$n+".pdf"),sha256:$s,state:"staged",
        staged_path:("staging/doc"+$n+".pdf"),
        dest_path:("09_receipts-and-purchases/doc"+$n+".pdf"),blocked:null,flags:[]}' \
      > "${STATE_DIR}/proposals/${m}.json"
done
# doc2 was already filed by an earlier tap — an older batch notification stays
# tappable after a newer one supersedes it, so this must be tolerated silently
# rather than failing the batch.
mv "${DOCS}/staging/doc2.pdf" "${DOCS}/09_receipts-and-purchases/doc2.pdf"
jq -c '.state="filed"' "${STATE_DIR}/proposals/${MEMBERS[1]}.json" > "${TMP}/b" \
  && mv "${TMP}/b" "${STATE_DIR}/proposals/${MEMBERS[1]}.json"
jq -nc --arg i "$BATCH" --argjson m "$(printf '%s\n' "${MEMBERS[@]}" | jq -R -s -c 'split("\n")|map(select(length>0))')" \
  '{id:$i,kind:"batch",state:"staged",members:$m}' > "${STATE_DIR}/proposals/${BATCH}.json"
jq -nc '{action:"accept",at:"t"}' > "${STATE_DIR}/approvals/${BATCH}.json"
DOCS="${TMP}/docs" STATE_DIR="${TMP}/state" bash "${SCRIPT_DIR}/documents.apply.sh" >"${TMP}/bout" 2>&1
is "batch files every member"        "$(ls "${DOCS}/09_receipts-and-purchases" | wc -l)" "3"
is "batch empties staging"           "$(ls "${DOCS}/staging" | wc -l)" "0"
has "a stale member is not an error" "$(cat "${TMP}/bout")" "refused 0"
is "batch drains its marker"         "$(markers)" "0"

# ------------------------------------------------------------------ the units
# Asserting the source lines exist is weak, but these are invariants whose breakage
# is silent and expensive, and each was got wrong at least once during the build.
echo "unit invariants"
UNIT_DIR="$(cd "${SELF_DIR}/../../systemd" && pwd)"
tp="$(cat "${UNIT_DIR}/documents.triage.path")"
# `documents/*` also matches staging/, bin/ and the numbered folders, which always
# exist — so the condition never goes false and the unit fires forever.
is  "triage glob is extension-scoped, never bare *" \
    "$(grep -c 'PathExistsGlob=.*documents/\*$' <<<"$tp")" "0"
is  "triage watches the five supported types" "$(grep -c '^PathExistsGlob=' <<<"$tp")" "5"
has "apply glob matches only finished markers" \
    "$(cat "${UNIT_DIR}/documents.apply.path")" 'approvals/*.json'
has "triage carries a start limit"   "$(cat "${UNIT_DIR}/documents.triage.service")" "StartLimitBurst"
has "apply carries a start limit"    "$(cat "${UNIT_DIR}/documents.apply.service")"  "StartLimitBurst"
# apply moves files but talks to no model; keeping the key out of it is deliberate.
is  "apply has no API key"           "$(grep -c '^EnvironmentFile=' "${UNIT_DIR}/documents.apply.service")" "0"
has "triage has the API key"         "$(cat "${UNIT_DIR}/documents.triage.service")" "EnvironmentFile=/etc/ai.env"

# The container's authority is its mount list. Test the mount, not the code.
echo "container confinement"
compose="$(cat "${SELF_DIR}/../../docker-compose.yml")"
approve="$(awk '/^  documents-approve:/{f=1} f&&/^  [a-z]/&&!/documents-approve/{f=0} f' <<<"$compose")"
is  "approve mounts exactly one path" "$(grep -c '^      - \${ZPOOL_VOLUME}' <<<"$approve")" "1"
has "and it is the approvals dir"     "$approve" "intake-state/approvals:/approvals"
has "approve is read_only"            "$approve" "read_only: true"
has "approve drops all caps"          "$approve" "cap_drop"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
