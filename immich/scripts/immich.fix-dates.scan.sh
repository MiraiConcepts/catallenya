#!/bin/bash
# Scan the Immich library for assets whose fileCreatedAt disagrees with a
# more-authoritative external date source. Read-only — no mutations.
#
# Sources of truth (strict priority order):
#   1. EXIF DateTimeOriginal via exiftool (cameras, JPEG/HEIC)
#   2. Filename-embedded date (WhatsApp, Android camera, screenshots, Signal, etc.)
#   3. Video container creation_time via ffprobe (videos only)
#   4. File mtime (opt-in via --allow-mtime; weakest signal)
#
# First non-empty source that passes the sanity range wins.
#
# Cross-source disagreement detection: if EXIF and filename are both
# present and differ by > 24h, the row is flagged with source `exif*`
# so verify routes it to `rescued-fixes-*.tsv` rather than auto-applying.
#
# Defensive filters (always applied — same as find-junk):
#   status='active' AND deletedAt IS NULL AND visibility='timeline'
#
# Writes timestamped run dir under immich/scripts/runs/<ts>/ containing:
#   proposed-image.tsv     Per-asset rows for IMAGE candidates
#   proposed-video.tsv     Per-asset rows for VIDEO candidates
#   scan-summary.txt       Counts + top-10 densest current-date clusters + samples
#
# TSV columns (uniform across image/video):
#   uuid<TAB>current_date_sgt<TAB>proposed_date_sgt<TAB>source<TAB>filename<TAB>path<TAB>type
# Dates rendered as ISO-8601 with SGT offset: `YYYY-MM-DDTHH:MM:SS+08:00`.
#
# Usage:
#   bash immich/scripts/immich.fix-dates.scan.sh [OPTIONS]
#
# OPTIONS:
#   --type=image|video|all       Asset types to scan (default: all)
#   --date-cluster=YYYY-MM-DD    Narrow to assets whose current fileCreatedAt
#                                falls on this SGT day (default-date targeting)
#   --source=exif|filename|container|mtime|all
#                                Only consider this source for the pass
#                                (default: all — strict priority order)
#   --min-date=YYYY-MM-DD        Reject proposed dates before this (default: 1970-01-02)
#   --max-date=YYYY-MM-DD        Reject proposed dates after this (default: now+24h)
#   --allow-mtime                Permit source 4 (file mtime); off by default
#   --limit=N                    Cap candidates before resolver runs (debug/canary)
#   --parallel=N                 Concurrent date resolvers (default: nproc)
#   -h, --help                   Show this help.
#
# EXIT CODES:
#   0  scan completed; review proposed-*.tsv before running verify
#   1  partial failures (some resolver calls errored); inspect run dir
#   2  aborted (bad args, container down, missing tools)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=immich.lib.sh
. "${SCRIPT_DIR}/immich.lib.sh"
# Date derivation (parse_filename_date, the source readers, in_range,
# same_second) is shared with verify — one copy, so the two cannot drift.
# shellcheck source=immich.dates.lib.sh
. "${SCRIPT_DIR}/immich.dates.lib.sh"

# ── Constants ────────────────────────────────────────────────────────────
CONTAINER_PATH_PREFIX="/usr/src/app/upload"
HOST_PATH_PREFIX="/zpool/catallenya/immich/data"
SGT_OFFSET="+08:00"

# ── CLI ──────────────────────────────────────────────────────────────────
TYPE="all"
DATE_CLUSTER=""
SOURCE_FILTER="all"
MIN_DATE="1970-01-02"
MAX_DATE=""   # computed below if unset
ALLOW_MTIME=0
LIMIT=""
PARALLEL="$(nproc)"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --type=*)          TYPE="${1#*=}"; shift ;;
    --date-cluster=*)  DATE_CLUSTER="${1#*=}"; shift ;;
    --source=*)        SOURCE_FILTER="${1#*=}"; shift ;;
    --min-date=*)      MIN_DATE="${1#*=}"; shift ;;
    --max-date=*)      MAX_DATE="${1#*=}"; shift ;;
    --allow-mtime)     ALLOW_MTIME=1; shift ;;
    --limit=*)         LIMIT="${1#*=}"; shift ;;
    --parallel=*)      PARALLEL="${1#*=}"; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$TYPE" in image|video|all) ;; *) echo "error: --type must be image, video, or all" >&2; exit 2 ;; esac
case "$SOURCE_FILTER" in exif|filename|container|mtime|all) ;; *) echo "error: --source must be exif|filename|container|mtime|all" >&2; exit 2 ;; esac
if [[ "$SOURCE_FILTER" == "mtime" && "$ALLOW_MTIME" -ne 1 ]]; then
  echo "error: --source=mtime requires --allow-mtime (mtime is off by default)." >&2
  exit 2
fi
[[ "$PARALLEL" =~ ^[0-9]+$ && "$PARALLEL" -ge 1 ]] || { echo "error: --parallel must be >=1" >&2; exit 2; }
[[ -n "$LIMIT" && ! "$LIMIT" =~ ^[0-9]+$ ]] && { echo "error: --limit must be a positive integer" >&2; exit 2; }
[[ -n "$DATE_CLUSTER" && ! "$DATE_CLUSTER" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && {
  echo "error: --date-cluster must be YYYY-MM-DD" >&2; exit 2; }
[[ ! "$MIN_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && { echo "error: --min-date must be YYYY-MM-DD" >&2; exit 2; }
[[ -n "$MAX_DATE" && ! "$MAX_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && {
  echo "error: --max-date must be YYYY-MM-DD" >&2; exit 2; }

# Default MAX_DATE = today (UTC) + 1 day. We compare with > MAX_DATE so this
# gives ~24h headroom against clock skew without permitting far-future dates.
if [[ -z "$MAX_DATE" ]]; then
  MAX_DATE="$(date -u -d 'tomorrow' +'%Y-%m-%d')"
fi

# exiftool is a hard requirement when EXIF source is in play (it always is,
# unless --source explicitly excludes it).
if [[ "$SOURCE_FILTER" == "all" || "$SOURCE_FILTER" == "exif" ]]; then
  if ! command -v exiftool >/dev/null 2>&1; then
    echo "error: exiftool is not installed on host." >&2
    echo "  Install: sudo apt install -y libimage-exiftool-perl" >&2
    echo "  Or skip the EXIF source: --source=filename|container|mtime" >&2
    exit 2
  fi
fi
imapi_require_cmd docker awk stat date timeout

# Verify immich-postgres + immich-server are up.
if [[ "$(docker inspect -f '{{.State.Running}}' immich-postgres 2>/dev/null)" != "true" ]]; then
  echo "error: immich-postgres container is not running" >&2
  exit 1
fi
if [[ "$(docker inspect -f '{{.State.Running}}' immich-server 2>/dev/null)" != "true" ]]; then
  echo "error: immich-server container is not running" >&2
  exit 1
fi

RUN_TS="$(date -u +'%Y-%m-%d_%H-%M-%SZ')"
RUN_DIR="${SCRIPT_DIR}/runs/${RUN_TS}"
mkdir -p "${RUN_DIR}"
SUMMARY_FILE="${RUN_DIR}/scan-summary.txt"

echo "Immich fix-dates scan — ${RUN_TS}"
echo "  Run dir:        ${RUN_DIR}"
echo "  Type:           ${TYPE}"
echo "  Source:         ${SOURCE_FILTER}"
echo "  Date cluster:   ${DATE_CLUSTER:-<all days>}"
echo "  Range:          [${MIN_DATE}, ${MAX_DATE}]"
echo "  Allow mtime:    $([[ "$ALLOW_MTIME" == "1" ]] && echo yes || echo no)"
echo "  Limit:          ${LIMIT:-<none>}"
echo "  Parallel:       ${PARALLEL}"
echo

# ── Postgres extract: candidate list ─────────────────────────────────────
# Columns emitted: uuid \t type_lower \t cpath \t fname \t bytes \t current_iso_sgt
type_filter=""
case "$TYPE" in
  image) type_filter="AND a.type = 'IMAGE'" ;;
  video) type_filter="AND a.type = 'VIDEO'" ;;
  all)   type_filter="AND a.type IN ('IMAGE','VIDEO')" ;;
esac

cluster_filter=""
if [[ -n "$DATE_CLUSTER" ]]; then
  cluster_filter="AND date_trunc('day', a.\"fileCreatedAt\" AT TIME ZONE 'Asia/Singapore')::date = '${DATE_CLUSTER}'"
fi

limit_clause=""
[[ -n "$LIMIT" ]] && limit_clause="LIMIT ${LIMIT}"

CANDIDATES_FILE="${RUN_DIR}/.candidates.tsv"
docker exec -i immich-postgres \
  psql -U postgres -d immich -A -t -F $'\t' --pset=footer=off \
       -v ON_ERROR_STOP=1 > "${CANDIDATES_FILE}" <<SQL
SELECT a.id::text,
       lower(a.type::text),
       a."originalPath",
       a."originalFileName",
       COALESCE(e."fileSizeInByte"::text, '0'),
       to_char(a."fileCreatedAt" AT TIME ZONE 'Asia/Singapore',
               'YYYY-MM-DD"T"HH24:MI:SS+08:00')
FROM asset a
LEFT JOIN asset_exif e ON e."assetId" = a.id
WHERE a.status = 'active'
  AND a."deletedAt" IS NULL
  AND a.visibility = 'timeline'
  ${type_filter}
  ${cluster_filter}
ORDER BY a."fileCreatedAt"
${limit_clause};
SQL

TOTAL="$(wc -l < "${CANDIDATES_FILE}" | tr -d ' ')"
echo "Candidates: ${TOTAL}"
if [[ "${TOTAL}" -eq 0 ]]; then
  echo "Nothing to scan."
  echo "Empty scan: no candidates matched the filters." > "${SUMMARY_FILE}"
  exit 0
fi

# ── Per-asset date resolver ──────────────────────────────────────────────
# Runs under xargs -P. Reads one tab-separated row; emits a row to one of
# PROPOSED_IMG_FILE / PROPOSED_VID_FILE if a source disagrees with the
# current date.
resolve_one_row() {
  local line=$1
  # Row: uuid, type, cpath, fname, bytes, current_iso — bytes is unused (`_`).
  local uuid type cpath fname current_iso
  IFS=$'\t' read -r uuid type cpath fname _ current_iso <<<"$line"
  local hpath="${cpath/$CONTAINER_PATH_PREFIX/$HOST_PATH_PREFIX}"

  local exif_iso="" filename_iso="" container_iso="" mtime_iso=""

  # Sources 1-4 read via immich.dates.lib.sh (readers print to stdout, empty
  # on no result). The gates — which sources are even consulted — stay here.

  # Source 1: EXIF DateTimeOriginal (+ OffsetTimeOriginal if present)
  if [[ "$SOURCE_FILTER" == "all" || "$SOURCE_FILTER" == "exif" ]]; then
    exif_iso="$(read_exif_date "$hpath")"
  fi

  # Source 2: Filename-embedded date
  if [[ "$SOURCE_FILTER" == "all" || "$SOURCE_FILTER" == "filename" ]]; then
    filename_iso="$(parse_filename_date "$fname")"
  fi

  # Source 3: Video container creation_time (video only)
  if [[ "$type" == "video" && ( "$SOURCE_FILTER" == "all" || "$SOURCE_FILTER" == "container" ) ]]; then
    container_iso="$(read_container_date "$cpath")"
  fi

  # Source 4: mtime (opt-in)
  if [[ "$ALLOW_MTIME" == "1" && ( "$SOURCE_FILTER" == "all" || "$SOURCE_FILTER" == "mtime" ) ]]; then
    mtime_iso="$(read_mtime_date "$hpath")"
  fi

  # Pick winning source by strict priority, gated by range check.
  local winning_source="" winning_iso=""
  local src val
  for src in exif filename container mtime; do
    case "$src" in
      exif)      val="$exif_iso" ;;
      filename)  val="$filename_iso" ;;
      container) val="$container_iso" ;;
      mtime)     val="$mtime_iso" ;;
    esac
    if [[ -n "$val" ]] && in_range "$val"; then
      winning_source="$src"
      winning_iso="$val"
      break
    fi
  done

  # No usable source.
  [[ -z "$winning_iso" ]] && return 0

  # Skip if proposed equals current within 1 second.
  if same_second "$winning_iso" "$current_iso"; then
    return 0
  fi

  # Cross-source CONFLICT flag: EXIF + filename both present, differ > 24h.
  local flag=""
  if [[ -n "$exif_iso" && -n "$filename_iso" ]]; then
    if ! within_24h "$exif_iso" "$filename_iso"; then
      flag="*"
    fi
  fi

  local out_file
  if [[ "$type" == "image" ]]; then
    out_file="${PROPOSED_IMG_FILE}"
  else
    out_file="${PROPOSED_VID_FILE}"
  fi
  # File appends are atomic for < PIPE_BUF bytes on Linux; one line per row
  # so safe under xargs -P.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$uuid" "$current_iso" "$winning_iso" "${winning_source}${flag}" \
    "$fname" "$cpath" "$type" >> "$out_file"
}

# parse_filename_date, in_range and same_second now live in
# immich.dates.lib.sh (sourced above), shared with verify.

# True if two ISO timestamps differ by < 24h.
within_24h() {
  local a b ea eb diff
  a=$1; b=$2
  ea=$(date -d "$a" +%s 2>/dev/null) || return 1
  eb=$(date -d "$b" +%s 2>/dev/null) || return 1
  diff=$(( ea > eb ? ea - eb : eb - ea ))
  (( diff < 86400 ))
}

# The lib functions must be exported too: the workers are fresh `bash -c`
# processes under xargs -P and only see exported functions.
export -f resolve_one_row within_24h \
          parse_filename_date read_exif_date read_container_date read_mtime_date \
          in_range same_second
export CONTAINER_PATH_PREFIX HOST_PATH_PREFIX SGT_OFFSET
export SOURCE_FILTER ALLOW_MTIME MIN_DATE MAX_DATE

# Empty output files first (resolver appends).
PROPOSED_IMG_FILE="${RUN_DIR}/proposed-image.tsv"
PROPOSED_VID_FILE="${RUN_DIR}/proposed-video.tsv"
: > "${PROPOSED_IMG_FILE}"
: > "${PROPOSED_VID_FILE}"
export PROPOSED_IMG_FILE PROPOSED_VID_FILE

# ── Run resolver in parallel ─────────────────────────────────────────────
echo "Resolving dates for ${TOTAL} candidates with ${PARALLEL} workers..."
< "${CANDIDATES_FILE}" xargs -P "${PARALLEL}" -d '\n' -I {} \
  bash -c 'resolve_one_row "$1"' _ {} || true

# ── Sort outputs deterministically (by current_date desc) ────────────────
for f in "${PROPOSED_IMG_FILE}" "${PROPOSED_VID_FILE}"; do
  if [[ -s "$f" ]]; then
    sort -t $'\t' -k2,2r -o "$f" "$f"
  fi
done

img_count="$(wc -l < "${PROPOSED_IMG_FILE}" | tr -d ' ')"
vid_count="$(wc -l < "${PROPOSED_VID_FILE}" | tr -d ' ')"

# ── Source breakdown ─────────────────────────────────────────────────────
src_breakdown() {
  local f=$1
  [[ -s "$f" ]] || { echo "  (none)"; return; }
  awk -F'\t' '{c[$4]++} END {for (s in c) printf "  %-12s %d\n", s, c[s]}' "$f" | sort
}

# ── Top-10 densest current-date clusters (informational) ─────────────────
cluster_top10() {
  local f=$1
  [[ -s "$f" ]] || { echo "  (none)"; return; }
  awk -F'\t' '{print substr($2,1,10)}' "$f" \
    | sort | uniq -c | sort -rn | head -10 \
    | awk '{printf "  %-12s %d\n", $2, $1}'
}

sample_rows() {
  local f=$1
  [[ -s "$f" ]] || { echo "  (none)"; return; }
  head -5 "$f" | awk -F'\t' '{printf "  %s  %s → %s  [%s]  %s\n", $1, substr($2,1,19), substr($3,1,19), $4, $5}'
}

# ── Summary ──────────────────────────────────────────────────────────────
{
  echo "Immich fix-dates scan — ${RUN_TS}"
  echo "Run dir:        ${RUN_DIR}"
  echo "Type:           ${TYPE}"
  echo "Source filter:  ${SOURCE_FILTER}"
  echo "Date cluster:   ${DATE_CLUSTER:-<all days>}"
  echo "Range:          [${MIN_DATE}, ${MAX_DATE}]"
  echo "Allow mtime:    $([[ "$ALLOW_MTIME" == "1" ]] && echo yes || echo no)"
  echo "Candidates:     ${TOTAL}"
  echo
  echo "Proposed changes:"
  printf '  %-12s %d\n' "image" "${img_count}"
  printf '  %-12s %d\n' "video" "${vid_count}"
  printf '  %-12s %d\n' "total" "$(( img_count + vid_count ))"
  echo
  if (( img_count > 0 )); then
    echo "── IMAGE ──"
    echo "Sources:"
    src_breakdown "${PROPOSED_IMG_FILE}"
    echo
    echo "Current-date clusters (top 10):"
    cluster_top10 "${PROPOSED_IMG_FILE}"
    echo
    echo "Sample rows:"
    sample_rows "${PROPOSED_IMG_FILE}"
    echo
  fi
  if (( vid_count > 0 )); then
    echo "── VIDEO ──"
    echo "Sources:"
    src_breakdown "${PROPOSED_VID_FILE}"
    echo
    echo "Current-date clusters (top 10):"
    cluster_top10 "${PROPOSED_VID_FILE}"
    echo
    echo "Sample rows:"
    sample_rows "${PROPOSED_VID_FILE}"
    echo
  fi
  echo "Source legend:"
  echo "  exif       EXIF DateTimeOriginal"
  echo "  filename   Filename-embedded date (regex)"
  echo "  container  Video container creation_time (ffprobe)"
  echo "  mtime      File mtime (--allow-mtime only)"
  echo "  *suffix    Cross-source conflict (EXIF + filename differ > 24h) — verify will rescue."
  echo
  echo "Next: bash immich/scripts/immich.fix-dates.verify.sh"
} | tee "${SUMMARY_FILE}"

# Cleanup candidate intermediate.
rm -f "${CANDIDATES_FILE}"
