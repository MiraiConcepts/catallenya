#!/bin/bash
# Delete junk assets from Immich. Consumes a run dir produced by
# immich.find-junk.sh (default: latest one without a deleted.tsv) and POSTs
# their IDs to DELETE /api/assets in batches.
#
# Default mode is soft-delete: assets go to Immich Trash (30-day retention,
# recoverable via UI). Use --force for hard delete.
#
# Resume: deleted.tsv is appended one row per asset. If a run is interrupted,
# re-running with --force-rerun skips IDs whose logged outcome is terminal
# (2xx deleted, 404 already gone) and retries failure rows (000/5xx).
#
# Usage:
#   bash immich/scripts/immich.delete.sh [OPTIONS]
#
# OPTIONS:
#   --dry-run             Show what would be deleted, no API calls.
#   --yes                 Skip the confirmation prompt.
#   --force               Hard delete (skip trash).
#   --tier=a|b|c|all      Which tier(s) from the run dir (default: all).
#                         Tier c is image-only (monochrome candidates from
#                         --enable-monochrome).
#   --asset-type=image|video|all
#                         Which asset type(s) from the run dir (default: all).
#                         Files read are verified-junk-{a,b,c}-{image,video}.tsv
#                         per the cartesian product of --tier and --asset-type.
#                         (tier c × video has no matching file, silently skipped.)
#   --skip-verify         Read raw tier-*.tsv files (skipping verify-junk's
#                         physical playability check). Prints warning + asks
#                         to confirm unless --yes is also passed. DANGEROUS —
#                         may delete real content that find-junk wrongly flagged.
#   --batch=N             IDs per DELETE call (default: 100).
#   --run=<ts>            Specific run dir instead of latest unprocessed.
#   --from-file=<p>       Read IDs from a file (TSV col 1 or UUID-per-line).
#                         Creates runs/<ts>_external/ for the log.
#                         --asset-type is ignored: caller provides IDs directly.
#   --force-rerun         Re-process a run dir that already has deleted.tsv.
#   -h, --help            Show this help.
#
# EXIT CODES:
#   0  all succeeded (200/204) or already gone (404)
#   1  some assets failed; inspect deleted.tsv for HTTP statuses
#   2  aborted (auth failure, user declined, bad arguments)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=immich.lib.sh
. "${SCRIPT_DIR}/immich.lib.sh"

DRY_RUN=0
YES=0
FORCE=0
FORCE_RERUN=0
SKIP_VERIFY=0
TIER="all"
ASSET_TYPE="all"
BATCH=100
RUN_OVERRIDE=""
FROM_FILE=""
EXTERNAL_PENDING=0

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)      DRY_RUN=1; shift ;;
    --yes)          YES=1; shift ;;
    --force)        FORCE=1; shift ;;
    --force-rerun)  FORCE_RERUN=1; shift ;;
    --skip-verify)  SKIP_VERIFY=1; shift ;;
    --tier=*)       TIER="${1#*=}"; shift ;;
    --asset-type=*) ASSET_TYPE="${1#*=}"; shift ;;
    --batch=*)      BATCH="${1#*=}"; shift ;;
    --run=*)        RUN_OVERRIDE="${1#*=}"; shift ;;
    --from-file=*)  FROM_FILE="${1#*=}"; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$TIER"       in a|b|c|all)       ;; *) echo "error: --tier must be a, b, c, or all" >&2; exit 2 ;; esac
case "$ASSET_TYPE" in image|video|all) ;; *) echo "error: --asset-type must be image, video, or all" >&2; exit 2 ;; esac
[[ "$BATCH" =~ ^[0-9]+$ && "$BATCH" -ge 1 && "$BATCH" -le 1000 ]] \
  || { echo "error: --batch must be 1..1000" >&2; exit 2; }
[[ -n "$FROM_FILE" && -n "$RUN_OVERRIDE" ]] \
  && { echo "error: --from-file and --run are mutually exclusive" >&2; exit 2; }

imapi_require_cmd curl jq awk sort comm
imapi_load_key

# ── Resolve the source of IDs and the output dir ──────────────────────────
RUN_DIR=""
INPUT_DESC=""
src=()  # populated by run-dir branch below; stays empty for --from-file

if [[ -n "$FROM_FILE" ]]; then
  [[ -r "$FROM_FILE" ]] || { echo "error: cannot read $FROM_FILE" >&2; exit 2; }
  RUN_TS="$(date -u +'%Y-%m-%d_%H-%M-%SZ')"
  RUN_DIR="${SCRIPT_DIR}/runs/${RUN_TS}_external"
  # Defer dir creation until we know we'll write to it (skipped in --dry-run).
  INPUT_DESC="from-file=$FROM_FILE"
  EXTERNAL_PENDING=1
elif [[ -n "$RUN_OVERRIDE" ]]; then
  RUN_DIR="${SCRIPT_DIR}/runs/${RUN_OVERRIDE}"
  [[ -d "$RUN_DIR" ]] || { echo "error: run dir not found: $RUN_DIR" >&2; exit 2; }
  INPUT_DESC="run=$RUN_OVERRIDE (override)"
else
  # Latest run dir under runs/, preferring those without deleted.tsv unless
  # --force-rerun is set. Order: newest first by name (ISO timestamps sort).
  shopt -s nullglob
  candidates=("${SCRIPT_DIR}/runs/"*/)
  shopt -u nullglob
  for d in $(printf '%s\n' "${candidates[@]}" | sort -r); do
    d="${d%/}"
    if [[ -f "$d/deleted.tsv" && "$FORCE_RERUN" -ne 1 ]]; then continue; fi
    shopt -s nullglob
    tier_files=("$d/tier-"*.tsv)
    shopt -u nullglob
    (( ${#tier_files[@]} > 0 )) || continue
    RUN_DIR="$d"; break
  done
  [[ -n "$RUN_DIR" ]] || {
    echo "error: no pending run dir found under ${SCRIPT_DIR}/runs/" >&2
    echo "  Run immich.find-junk.sh first, or pass --run=<ts> / --from-file=<path>." >&2
    exit 2
  }
  INPUT_DESC="run=$(basename "$RUN_DIR")"
fi

# ── Build the working ID list (dedup, filter resume) ──────────────────────
TMP_IDS="$(mktemp)"
trap 'rm -f "$TMP_IDS"' EXIT

if [[ -n "$FROM_FILE" ]]; then
  if grep -q $'\t' "$FROM_FILE"; then
    awk -F'\t' '{print $1}' "$FROM_FILE"
  else
    cat "$FROM_FILE"
  fi | grep -Ei '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
     | sort -u > "$TMP_IDS"
else
  src=()
  tier_letters=()
  type_words=()
  case "$TIER" in
    a)   tier_letters=(a) ;;
    b)   tier_letters=(b) ;;
    c)   tier_letters=(c) ;;
    all) tier_letters=(a b c) ;;
  esac
  case "$ASSET_TYPE" in
    image) type_words=(image) ;;
    video) type_words=(video) ;;
    all)   type_words=(image video) ;;
  esac
  # Prefer verified-junk-*.tsv (output of immich.verify-junk.sh). Falls back
  # to raw tier-*.tsv only when --skip-verify is set explicitly.
  source_kind=""
  for t in "${tier_letters[@]}"; do
    for typ in "${type_words[@]}"; do
      f="$RUN_DIR/verified-junk-$t-$typ.tsv"
      [[ -f "$f" ]] && src+=("$f")
    done
  done
  if (( ${#src[@]} > 0 )); then
    source_kind="verified-junk"
  elif [[ -f "$RUN_DIR/verify-summary.txt" ]]; then
    # Verify ran but produced no verified-junk for this tier/type filter —
    # everything was rescued. That's a successful no-op, not an error.
    source_kind="verified-junk (empty)"
  elif (( SKIP_VERIFY == 1 )); then
    for t in "${tier_letters[@]}"; do
      for typ in "${type_words[@]}"; do
        f="$RUN_DIR/tier-$t-$typ.tsv"
        [[ -f "$f" ]] && src+=("$f")
      done
    done
    # Legacy fallback for pre-extension runs (tier-{a,b}.tsv, image-only)
    if (( ${#src[@]} == 0 )) && [[ "$ASSET_TYPE" == "image" || "$ASSET_TYPE" == "all" ]]; then
      for t in "${tier_letters[@]}"; do
        f="$RUN_DIR/tier-$t.tsv"
        [[ -f "$f" ]] && src+=("$f")
      done
    fi
    (( ${#src[@]} > 0 )) || { echo "error: no candidate files in $RUN_DIR (tier=$TIER, asset-type=$ASSET_TYPE)" >&2; exit 2; }
    source_kind="raw-tier (--skip-verify)"
  else
    echo "error: verify-junk has not been run on $RUN_DIR" >&2
    echo "  Run immich.verify-junk.sh on this dir first, or pass --skip-verify to use raw tier files." >&2
    exit 2
  fi
  awk -F'\t' '{print $1}' "${src[@]:-/dev/null}" 2>/dev/null | sort -u > "$TMP_IDS"
fi

OUT_FILE="$RUN_DIR/deleted.tsv"

# Resume: if deleted.tsv exists, require --force-rerun and skip already-logged IDs.
if [[ -f "$OUT_FILE" && -z "$FROM_FILE" ]]; then
  if [[ "$FORCE_RERUN" -ne 1 ]]; then
    echo "error: $OUT_FILE already exists." >&2
    echo "  Pass --force-rerun to retry IDs without a logged success (2xx/404)." >&2
    exit 2
  fi
  done_ids="$(mktemp)"
  # Only terminal outcomes count as done: 2xx (deleted) and 404 (already gone)
  # — the same pair the exit code calls success. Failure rows (000 transport,
  # 5xx) stay retryable: every logged row used to count, so one transient
  # failure excluded an asset from every future rerun and the advertised
  # --force-rerun remedy retried exactly nothing.
  awk -F'\t' '$2 ~ /^2/ || $2 == "404" {print $1}' "$OUT_FILE" | sort -u > "$done_ids"
  remaining="$(mktemp)"
  comm -23 "$TMP_IDS" "$done_ids" > "$remaining"
  mv "$remaining" "$TMP_IDS"
  rm -f "$done_ids"
fi

TOTAL="$(wc -l < "$TMP_IDS" | tr -d ' ')"

# ── Pre-flight summary ────────────────────────────────────────────────────
echo "Source: $INPUT_DESC"
echo "Run dir: $RUN_DIR"
echo "Tier: $TIER  /  Asset type: $ASSET_TYPE"
echo "Source files: ${source_kind:-from-file}"
if (( ${#src[@]} > 0 )); then
  echo "Files:"
  for f in "${src[@]}"; do printf '  %s (%d IDs)\n' "$(basename "$f")" "$(wc -l < "$f")"; done
fi
echo "Mode: $([[ $FORCE -eq 1 ]] && echo 'HARD DELETE (force=true, skips trash)' || echo 'soft delete (force=false, goes to trash)')"
echo "Batch size: $BATCH"
echo "Assets to process: $TOTAL"

# Loud warning + confirmation when --skip-verify is in effect
if (( SKIP_VERIFY == 1 )) && [[ -z "$FROM_FILE" ]] && [[ "${source_kind:-}" == raw-tier* ]]; then
  echo
  echo "  ⚠  WARNING: --skip-verify means physical playability was NOT checked."
  echo "  ⚠  Find-junk's heuristics may have flagged real content that won't be"
  echo "  ⚠  rescued. The 30-day trash window is your only safety net."
  if (( YES != 1 )) && (( DRY_RUN != 1 )); then
    read -rp "Proceed without verify? [y/N] " ans
    [[ "$ans" =~ ^[Yy] ]] || { echo "Aborted."; exit 2; }
  fi
fi
[[ $DRY_RUN -eq 1 ]] && echo "DRY RUN — no API calls will be made"
echo

if [[ "$TOTAL" -eq 0 ]]; then
  echo "Nothing to do."
  exit 0
fi

# ── Confirmation ──────────────────────────────────────────────────────────
if [[ $YES -ne 1 && $DRY_RUN -ne 1 ]]; then
  read -rp "Proceed? [y/N] " ans
  [[ "$ans" =~ ^[Yy] ]] || { echo "Aborted."; exit 2; }
fi

# Create the from-file _external run dir only now, once we're committed to writing.
# Skipped in --dry-run so we don't litter empty dirs across the runs/ tree.
if (( EXTERNAL_PENDING == 1 )) && [[ $DRY_RUN -ne 1 ]]; then
  mkdir -p "$RUN_DIR"
  echo "source: $FROM_FILE" > "$RUN_DIR/source.txt"
fi

# ── Process in batches ────────────────────────────────────────────────────
force_json="$([[ $FORCE -eq 1 ]] && echo true || echo false)"
ok=0; gone=0; failed=0; done_count=0

# Use \r progress in TTY, suppress mid-loop progress when stdout is piped.
if [[ -t 1 ]]; then PROGRESS_CR=$'\r'; else PROGRESS_CR=""; fi
progress_line() {
  [[ -n "$PROGRESS_CR" ]] || return 0
  printf '%s  processed %d / %d  (ok=%d gone=%d failed=%d)' \
    "$PROGRESS_CR" "$done_count" "$TOTAL" "$ok" "$gone" "$failed"
}

flush_batch() {
  local -a ids=("$@")
  (( ${#ids[@]} == 0 )) && return 0

  if [[ $DRY_RUN -eq 1 ]]; then
    done_count=$((done_count + ${#ids[@]}))
    ok=$((ok + ${#ids[@]}))
    return 0
  fi

  local payload
  payload="$(printf '%s\n' "${ids[@]}" | jq -R . | jq -s --argjson f "$force_json" '{ids: ., force: $f}')"

  local ts http_code resp_body
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  resp_body="$(mktemp)"
  http_code="$(curl -sS -o "$resp_body" -w '%{http_code}' \
    --max-time "${IMMICH_HTTP_TIMEOUT}" \
    -X DELETE \
    -H "x-api-key: ${IMMICH_API_KEY}" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    "${IMMICH_API_URL%/}/api/assets")" || http_code="000"

  if [[ "$http_code" == "401" ]]; then
    echo
    echo "FATAL: HTTP 401 — API key invalid or revoked. Aborting." >&2
    cat "$resp_body" >&2
    echo >&2
    rm -f "$resp_body"
    exit 2
  fi

  for id in "${ids[@]}"; do
    printf '%s\t%s\t%s\n' "$id" "$http_code" "$ts" >> "$OUT_FILE"
    case "$http_code" in
      2*)  ok=$((ok+1)) ;;
      404) gone=$((gone+1)) ;;
      *)   failed=$((failed+1)) ;;
    esac
    done_count=$((done_count+1))
  done
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
# Final line: always print, always with newline, regardless of TTY.
printf '  processed %d / %d  (ok=%d gone=%d failed=%d)\n' "$done_count" "$TOTAL" "$ok" "$gone" "$failed"

echo
echo "Done."
echo "  succeeded:          $ok"
echo "  already gone (404): $gone"
echo "  failed:             $failed"
[[ $DRY_RUN -ne 1 ]] && echo "  log: $OUT_FILE"

# Exit non-zero if any batch failed (excluding 404s which are expected for already-deleted).
(( failed > 0 )) && exit 1
exit 0
