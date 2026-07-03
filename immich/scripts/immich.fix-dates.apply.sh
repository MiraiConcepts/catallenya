#!/bin/bash
# Apply verified date fixes to Immich. Consumes verified-fixes-*.tsv from a
# run dir (default: latest one without applied.tsv) and PUTs each asset's
# new dateTimeOriginal.
#
# Job-queue safety: pauses the `metadataExtraction` job before applying and
# resumes it in an EXIT trap (so resume runs even on Ctrl-C / abort). This
# avoids the documented race where a queued extraction lands after the PUT
# and overwrites the new date (immich-app/immich#16901).
#
# Resume: applied.tsv is appended one row per asset. If a run is interrupted,
# re-running with --force-rerun skips IDs already in applied.tsv.
#
# Usage:
#   bash immich/scripts/immich.fix-dates.apply.sh [OPTIONS]
#
# OPTIONS:
#   --dry-run             Show what would be applied, no API calls.
#   --yes                 Skip the confirmation prompt.
#   --type=image|video|all  Asset type filter (default: all)
#   --limit=N             Cap to first N rows (canary).
#   --parallel=N          Concurrent PUT workers (default: 4)
#   --run=<ts>            Specific run dir instead of latest unprocessed.
#   --from-file=<p>       Read rows from a TSV file (same shape as
#                         verified-fixes-*.tsv) instead of a run dir.
#                         Creates runs/<ts>_external/ for the log.
#   --skip-verify         Read raw proposed-*.tsv (no playability check).
#                         DANGEROUS — prints warning + asks unless --yes.
#   --no-pause-jobs       Skip pausing metadataExtraction. The PUT writes
#                         become racy with any queued extraction (which can
#                         overwrite our new date). Use only if you've already
#                         paused the job yourself or are sure no extraction
#                         work is queued.
#   --force-rerun         Re-process a run dir that already has applied.tsv.
#   -h, --help            Show this help.
#
# applied.tsv columns:
#   uuid<TAB>old_date<TAB>new_date<TAB>source<TAB>http_code<TAB>iso_timestamp
#
# EXIT CODES:
#   0  all succeeded (200/204)
#   1  some PUTs failed; inspect applied.tsv for HTTP statuses
#   2  aborted (auth failure, user declined, bad arguments)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=immich.lib.sh
. "${SCRIPT_DIR}/immich.lib.sh"

DRY_RUN=0
YES=0
TYPE="all"
LIMIT=""
PARALLEL=4
RUN_OVERRIDE=""
FROM_FILE=""
SKIP_VERIFY=0
NO_PAUSE_JOBS=0
FORCE_RERUN=0
EXTERNAL_PENDING=0

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)        DRY_RUN=1; shift ;;
    --yes)            YES=1; shift ;;
    --type=*)         TYPE="${1#*=}"; shift ;;
    --limit=*)        LIMIT="${1#*=}"; shift ;;
    --parallel=*)     PARALLEL="${1#*=}"; shift ;;
    --run=*)          RUN_OVERRIDE="${1#*=}"; shift ;;
    --from-file=*)    FROM_FILE="${1#*=}"; shift ;;
    --skip-verify)    SKIP_VERIFY=1; shift ;;
    --no-pause-jobs)  NO_PAUSE_JOBS=1; shift ;;
    --force-rerun)    FORCE_RERUN=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$TYPE" in image|video|all) ;; *) echo "error: --type must be image, video, or all" >&2; exit 2 ;; esac
[[ "$PARALLEL" =~ ^[0-9]+$ && "$PARALLEL" -ge 1 && "$PARALLEL" -le 32 ]] \
  || { echo "error: --parallel must be 1..32" >&2; exit 2; }
[[ -n "$LIMIT" && ! "$LIMIT" =~ ^[0-9]+$ ]] && { echo "error: --limit must be a positive integer" >&2; exit 2; }
[[ -n "$FROM_FILE" && -n "$RUN_OVERRIDE" ]] && { echo "error: --from-file and --run are mutually exclusive" >&2; exit 2; }

imapi_require_cmd curl jq awk sort
imapi_load_key

# ── Resolve source of IDs and output dir ──────────────────────────────────
RUN_DIR=""
INPUT_DESC=""
src=()
source_kind=""

if [[ -n "$FROM_FILE" ]]; then
  [[ -r "$FROM_FILE" ]] || { echo "error: cannot read $FROM_FILE" >&2; exit 2; }
  RUN_TS="$(date -u +'%Y-%m-%d_%H-%M-%SZ')"
  RUN_DIR="${SCRIPT_DIR}/runs/${RUN_TS}_external_fixdates"
  INPUT_DESC="from-file=$FROM_FILE"
  EXTERNAL_PENDING=1
  src=("$FROM_FILE")
  source_kind="from-file"
elif [[ -n "$RUN_OVERRIDE" ]]; then
  RUN_DIR="${SCRIPT_DIR}/runs/${RUN_OVERRIDE}"
  [[ -d "$RUN_DIR" ]] || { echo "error: run dir not found: $RUN_DIR" >&2; exit 2; }
  INPUT_DESC="run=$RUN_OVERRIDE (override)"
else
  shopt -s nullglob
  candidates=("${SCRIPT_DIR}/runs/"*/)
  shopt -u nullglob
  for d in $(printf '%s\n' "${candidates[@]}" | sort -r); do
    d="${d%/}"
    if [[ -f "$d/applied.tsv" && "$FORCE_RERUN" -ne 1 ]]; then continue; fi
    shopt -s nullglob
    vfiles=("$d"/verified-fixes-*.tsv)
    shopt -u nullglob
    (( ${#vfiles[@]} > 0 )) || continue
    RUN_DIR="$d"; break
  done
  [[ -n "$RUN_DIR" ]] || {
    echo "error: no pending run dir found under ${SCRIPT_DIR}/runs/" >&2
    echo "  Run immich.fix-dates.scan.sh + verify.sh first, or pass --run=<ts>/--from-file=<p>." >&2
    exit 2
  }
  INPUT_DESC="run=$(basename "$RUN_DIR")"
fi

# Resolve src[] from the run dir (if not from-file)
if [[ -z "$FROM_FILE" ]]; then
  types=()
  case "$TYPE" in
    image) types=(image) ;;
    video) types=(video) ;;
    all)   types=(image video) ;;
  esac
  for typ in "${types[@]}"; do
    f="$RUN_DIR/verified-fixes-$typ.tsv"
    [[ -f "$f" ]] && src+=("$f")
  done
  if (( ${#src[@]} > 0 )); then
    source_kind="verified-fixes"
  elif [[ -f "$RUN_DIR/verify-fixes-summary.txt" ]]; then
    source_kind="verified-fixes (empty)"
  elif (( SKIP_VERIFY == 1 )); then
    for typ in "${types[@]}"; do
      f="$RUN_DIR/proposed-$typ.tsv"
      [[ -f "$f" ]] && src+=("$f")
    done
    (( ${#src[@]} > 0 )) || { echo "error: no candidate files in $RUN_DIR (type=$TYPE)" >&2; exit 2; }
    source_kind="proposed (--skip-verify)"
  else
    echo "error: verify has not been run on $RUN_DIR" >&2
    echo "  Run immich.fix-dates.verify.sh first, or pass --skip-verify." >&2
    exit 2
  fi
fi

# ── Build working list (dedup, filter resume) ────────────────────────────
TMP_INPUT="$(mktemp)"
TMP_REMAINING="$(mktemp)"
cleanup_tmp() { rm -f "${TMP_INPUT:-}" "${TMP_REMAINING:-}" 2>/dev/null || true; }
trap cleanup_tmp EXIT

# Concatenate all source files; rows must be exactly 7 cols (verified-fixes
# shape). 8-col rescued-fixes rows are explicitly rejected — if a user wants
# to apply a manually-reviewed rescued row, they must drop the verdict
# column themselves first.
if (( ${#src[@]} > 0 )); then
  awk -F'\t' '
    NF == 7 { print; next }
    NF >  7 { bad++ }
    END { if (bad) printf "warning: dropped %d row(s) with >7 cols (rescued-fixes shape? feed verified-fixes only)\n", bad > "/dev/stderr" }
  ' "${src[@]}" > "$TMP_INPUT"
else
  : > "$TMP_INPUT"
fi

OUT_FILE="$RUN_DIR/applied.tsv"

# Resume support: subtract already-applied uuids (only meaningful for real
# runs — dry-run never writes to applied.tsv).
if [[ $DRY_RUN -ne 1 && -f "$OUT_FILE" && -z "$FROM_FILE" ]]; then
  if [[ "$FORCE_RERUN" -ne 1 ]]; then
    echo "error: $OUT_FILE already exists." >&2
    echo "  Pass --force-rerun to retry any uuids not yet logged in it." >&2
    exit 2
  fi
  done_ids="$(mktemp)"
  awk -F'\t' '{print $1}' "$OUT_FILE" | sort -u > "$done_ids"
  awk -F'\t' -v dones="$done_ids" '
    BEGIN { while ((getline id < dones) > 0) d[id]=1 }
    !($1 in d)
  ' "$TMP_INPUT" > "$TMP_REMAINING"
  mv "$TMP_REMAINING" "$TMP_INPUT"
  rm -f "$done_ids"
fi

# Optional limit cap
if [[ -n "$LIMIT" ]]; then
  head -n "$LIMIT" "$TMP_INPUT" > "$TMP_REMAINING"
  mv "$TMP_REMAINING" "$TMP_INPUT"
fi

TOTAL="$(wc -l < "$TMP_INPUT" | tr -d ' ')"

# ── Pre-flight summary ────────────────────────────────────────────────────
echo "Source:        $INPUT_DESC"
echo "Run dir:       $RUN_DIR"
echo "Type filter:   $TYPE"
echo "Source files:  ${source_kind:-?}"
if (( ${#src[@]} > 0 )); then
  echo "Files:"
  for f in "${src[@]}"; do printf '  %s (%d rows)\n' "$(basename "$f")" "$(wc -l < "$f" | tr -d ' ')"; done
fi
echo "Parallel:      $PARALLEL"
[[ -n "$LIMIT" ]] && echo "Limit:         $LIMIT"
echo "Pause jobs:    $([[ $NO_PAUSE_JOBS -eq 1 ]] && echo 'NO (--no-pause-jobs)' || echo 'yes')"
echo "To apply:      $TOTAL"

if (( SKIP_VERIFY == 1 )) && [[ -z "$FROM_FILE" ]] && [[ "${source_kind:-}" == proposed* ]]; then
  echo
  echo "  ⚠  WARNING: --skip-verify bypassed source stability + range checks."
  echo "  ⚠  Bad dates from scan heuristics may be applied directly."
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

if [[ $YES -ne 1 && $DRY_RUN -ne 1 ]]; then
  read -rp "Apply $TOTAL date fix(es)? [y/N] " ans
  [[ "$ans" =~ ^[Yy] ]] || { echo "Aborted."; exit 2; }
fi

# Create the from-file _external run dir only now (skipped in --dry-run)
if (( EXTERNAL_PENDING == 1 )) && [[ $DRY_RUN -ne 1 ]]; then
  mkdir -p "$RUN_DIR"
  echo "source: $FROM_FILE" > "$RUN_DIR/source.txt"
fi

# ── Pause/resume metadataExtraction job ──────────────────────────────────
JOB_PAUSED=0

pause_metadata_job() {
  [[ $NO_PAUSE_JOBS -eq 1 || $DRY_RUN -eq 1 ]] && return 0
  echo "Pausing metadataExtraction job..."
  if imapi PUT /api/jobs/metadataExtraction \
       -H 'Content-Type: application/json' \
       --data '{"command":"pause"}' >/dev/null 2>&1; then
    JOB_PAUSED=1
    echo "  paused."
  else
    echo "  WARNING: pause failed (admin key required?). Continuing anyway." >&2
  fi
}

resume_metadata_job() {
  (( JOB_PAUSED == 1 )) || return 0
  echo "Resuming metadataExtraction job..."
  if imapi PUT /api/jobs/metadataExtraction \
       -H 'Content-Type: application/json' \
       --data '{"command":"resume"}' >/dev/null 2>&1; then
    echo "  resumed."
  else
    echo "  ERROR: could not resume metadataExtraction. Resume manually via:" >&2
    echo "    curl -X PUT '${IMMICH_API_URL}/api/jobs/metadataExtraction' \\" >&2
    echo "         -H 'x-api-key: <key>' -H 'Content-Type: application/json' \\" >&2
    echo "         --data '{\"command\":\"resume\"}'" >&2
  fi
}
on_exit() { resume_metadata_job; cleanup_tmp; }
trap on_exit EXIT
pause_metadata_job

# ── Per-asset apply function ─────────────────────────────────────────────
apply_one_row() {
  local line=$1
  # Row: uuid, current_iso, proposed_iso, source, fname, cpath, type —
  # only the first four are used; `_` swallows the rest.
  local uuid current_iso proposed_iso source
  IFS=$'\t' read -r uuid current_iso proposed_iso source _ <<<"$line"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '  DRY  %s  %s → %s  [%s]\n' "$uuid" "${current_iso:0:19}" "${proposed_iso:0:19}" "$source"
    return 0
  fi

  local payload http_code ts resp_body
  payload="$(jq -nc --arg d "$proposed_iso" '{dateTimeOriginal: $d}')"
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  resp_body="$(mktemp)"

  http_code="$(curl -sS -o "$resp_body" -w '%{http_code}' \
    --max-time "${IMMICH_HTTP_TIMEOUT}" \
    -X PUT \
    -H "x-api-key: ${IMMICH_API_KEY}" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    "${IMMICH_API_URL%/}/api/assets/${uuid}")" || http_code="000"

  # Always log the per-asset row before any abort logic, so summary counts
  # see the failure and the script exits non-zero.
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$uuid" "$current_iso" "$proposed_iso" "$source" "$http_code" "$ts" >> "$OUT_FILE"

  if [[ "$http_code" == "401" ]]; then
    echo
    echo "FATAL: HTTP 401 — API key invalid or revoked. Aborting." >&2
    cat "$resp_body" >&2; echo >&2
    rm -f "$resp_body"
    # Kill the xargs parent so remaining workers stop; the script's EXIT
    # trap will then resume metadataExtraction and the summary will fail.
    kill -TERM "$PPID" 2>/dev/null || true
    exit 2
  fi

  rm -f "$resp_body"
}
export -f apply_one_row
export DRY_RUN IMMICH_API_KEY IMMICH_API_URL IMMICH_HTTP_TIMEOUT OUT_FILE

# Touch the output file so all workers append cleanly (skip in dry-run; no file used).
[[ $DRY_RUN -ne 1 ]] && touch "$OUT_FILE"

# ── Run apply in parallel ────────────────────────────────────────────────
echo "Applying $TOTAL date fix(es) with $PARALLEL workers..."
< "$TMP_INPUT" xargs -P "$PARALLEL" -d '\n' -I {} \
  bash -c 'apply_one_row "$1"' _ {} || true

# ── Summary ──────────────────────────────────────────────────────────────
if [[ $DRY_RUN -eq 1 ]]; then
  echo
  echo "Done (dry-run). $TOTAL rows would be PUT."
  exit 0
fi

ok=$(awk -F'\t' '$5 ~ /^2/' "$OUT_FILE" | wc -l | tr -d ' ')
failed=$(awk -F'\t' '$5 !~ /^2/' "$OUT_FILE" | wc -l | tr -d ' ')

echo
echo "Done."
echo "  succeeded:  $ok"
echo "  failed:     $failed"
echo "  log:        $OUT_FILE"

if (( failed > 0 )); then
  echo
  echo "Failed rows (first 10):"
  awk -F'\t' '$5 !~ /^2/' "$OUT_FILE" \
    | head -10 \
    | awk -F'\t' '{printf "  %s  http=%s  %s → %s  [%s]\n", $1, $5, substr($2,1,19), substr($3,1,19), $4}'
fi

(( failed > 0 )) && exit 1
exit 0
