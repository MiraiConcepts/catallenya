#!/bin/bash
# Restore assets from Immich Trash. Inverse of soft-delete.
#
# Reads UUIDs from a file (TSV col 1 or one-UUID-per-line) or stdin and
# batch-calls POST /api/trash/restore/assets. Writes a per-asset log to
# the same directory as the input (or runs/<ts>_restore/ for stdin).
#
# Usage:
#   bash immich/scripts/immich.restore.sh [OPTIONS]
#
# OPTIONS:
#   --from-file=<p>   Read IDs from a file. TSV (col 1) or one UUID per line.
#                     Pass `-` to read from stdin.
#   --yes             Skip the confirmation prompt.
#   --batch=N         IDs per restore call (default: 100).
#   -h, --help        Show this help.
#
# EXIT CODES:
#   0  all batches succeeded
#   1  some batches failed; inspect restored.tsv
#   2  aborted (auth failure, user declined, bad arguments)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=immich.lib.sh
. "${SCRIPT_DIR}/immich.lib.sh"

YES=0
BATCH=100
FROM_FILE=""

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --yes)         YES=1; shift ;;
    --batch=*)     BATCH="${1#*=}"; shift ;;
    --from-file=*) FROM_FILE="${1#*=}"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$FROM_FILE" ]] || { echo "error: --from-file is required (use '-' for stdin)" >&2; exit 2; }
[[ "$BATCH" =~ ^[0-9]+$ && "$BATCH" -ge 1 && "$BATCH" -le 1000 ]] \
  || { echo "error: --batch must be 1..1000" >&2; exit 2; }

imapi_require_cmd curl jq awk sort
imapi_load_key

# ── Resolve input + output paths ──────────────────────────────────────────
TMP_IDS="$(mktemp)"
trap 'rm -f "$TMP_IDS"' EXIT

if [[ "$FROM_FILE" == "-" ]]; then
  RUN_TS="$(date -u +'%Y-%m-%d_%H-%M-%SZ')"
  OUT_DIR="${SCRIPT_DIR}/runs/${RUN_TS}_restore"
  INPUT_DESC="from-file=stdin"
  raw_input="$(cat)"
else
  [[ -r "$FROM_FILE" ]] || { echo "error: cannot read $FROM_FILE" >&2; exit 2; }
  OUT_DIR="$(dirname "$FROM_FILE")"
  INPUT_DESC="from-file=$FROM_FILE"
  raw_input="$(cat "$FROM_FILE")"
fi

# Accept TSV col 1 or plain UUID per line; filter to valid UUIDs only.
if printf '%s\n' "$raw_input" | grep -q $'\t'; then
  printf '%s\n' "$raw_input" | awk -F'\t' '{print $1}'
else
  printf '%s\n' "$raw_input"
fi | grep -Ei '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
   | sort -u > "$TMP_IDS"

TOTAL="$(wc -l < "$TMP_IDS" | tr -d ' ')"

# ── Pre-flight ────────────────────────────────────────────────────────────
echo "Source:  $INPUT_DESC"
echo "Output:  $OUT_DIR"
echo "Batch:   $BATCH"
echo "Assets:  $TOTAL"
echo

if [[ "$TOTAL" -eq 0 ]]; then
  echo "Nothing to do."
  exit 0
fi

if [[ $YES -ne 1 ]]; then
  read -rp "Restore $TOTAL asset(s) from trash? [y/N] " ans
  [[ "$ans" =~ ^[Yy] ]] || { echo "Aborted."; exit 2; }
fi

mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/restored.tsv"

# ── Process in batches ────────────────────────────────────────────────────
ok=0; failed=0; done_count=0

if [[ -t 1 ]]; then PROGRESS_CR=$'\r'; else PROGRESS_CR=""; fi
progress_line() {
  [[ -n "$PROGRESS_CR" ]] || return 0
  printf '%s  processed %d / %d  (ok=%d failed=%d)' \
    "$PROGRESS_CR" "$done_count" "$TOTAL" "$ok" "$failed"
}

flush_batch() {
  local -a ids=("$@")
  (( ${#ids[@]} == 0 )) && return 0

  local payload
  payload="$(printf '%s\n' "${ids[@]}" | jq -R . | jq -s '{ids: .}')"

  local ts http_code resp_body count
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  resp_body="$(mktemp)"
  http_code="$(curl -sS -o "$resp_body" -w '%{http_code}' \
    --max-time "${IMMICH_HTTP_TIMEOUT}" \
    -X POST \
    -H "x-api-key: ${IMMICH_API_KEY}" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    "${IMMICH_API_URL%/}/api/trash/restore/assets")" || http_code="000"

  if [[ "$http_code" == "401" ]]; then
    echo
    echo "FATAL: HTTP 401 — API key invalid or revoked. Aborting." >&2
    cat "$resp_body" >&2; echo >&2
    rm -f "$resp_body"
    exit 2
  fi

  count="$(jq -r '.count // 0' < "$resp_body" 2>/dev/null || echo 0)"

  for id in "${ids[@]}"; do
    printf '%s\t%s\t%s\n' "$id" "$http_code" "$ts" >> "$OUT_FILE"
    done_count=$((done_count+1))
  done
  case "$http_code" in
    2*) ok=$((ok + ${#ids[@]})) ;;
    *)  failed=$((failed + ${#ids[@]})) ;;
  esac
  rm -f "$resp_body"
}

batch_buf=()
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  batch_buf+=("$id")
  if (( ${#batch_buf[@]} >= BATCH )); then
    flush_batch "${batch_buf[@]}"
    batch_buf=()
    progress_line
  fi
done < "$TMP_IDS"
flush_batch "${batch_buf[@]}"
printf '  processed %d / %d  (ok=%d failed=%d)\n' "$done_count" "$TOTAL" "$ok" "$failed"

echo
echo "Done."
echo "  succeeded: $ok"
echo "  failed:    $failed"
echo "  log:       $OUT_FILE"

(( failed > 0 )) && exit 1
exit 0
