#!/bin/bash
# Verify proposed date fixes by re-reading the declared source per row and
# sanity-checking the value. Read-only — no mutations. Splits each row into
# verified-fixes-*.tsv (safe to apply) or rescued-fixes-*.tsv (do NOT apply,
# review).
#
# Default consumes the latest run dir under runs/ that has proposed-*.tsv
# but lacks verify-fixes-summary.txt. Use --run=<ts> for a specific dir.
#
# Usage:
#   bash immich/scripts/immich.fix-dates.verify.sh [OPTIONS]
#
# OPTIONS:
#   --type=image|video|all   Which asset type(s) to verify (default: all)
#   --run=<ts>               Specific run dir under runs/<ts>
#   --parallel=N             Concurrent re-read workers (default: nproc)
#   --min-date=YYYY-MM-DD    Sanity floor (default: 1970-01-02)
#   --max-date=YYYY-MM-DD    Sanity ceiling (default: now+24h)
#   --force-rerun            Overwrite existing verify output in the run dir
#   -h, --help               Show this help.
#
# OUTPUT FILES per run dir:
#   verified-fixes-{image,video}.tsv  — rows safe to apply
#   rescued-fixes-{image,video}.tsv   — rows that failed verify (verdict appended)
#   verify-fixes-summary.txt          — counts + sample previews per verdict
#
# VERDICT TAXONOMY:
#   OK            All checks pass — routed to verified-fixes-*.tsv
#   MISSING       File no longer exists on disk
#   OUT_OF_RANGE  Proposed date outside [min-date, max-date]
#   NO_CHANGE     Proposed == current (scan should have skipped; defensive)
#   CONFLICT      Scan flagged cross-source disagreement (source ends with `*`)
#   UNSTABLE      Source re-read produced a different (or empty) date
#
# EXIT CODES:
#   0  verify completed; review verified/rescued files
#   1  partial failures (some re-reads errored); inspect output
#   2  aborted (bad args, run dir missing, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=immich.lib.sh
. "${SCRIPT_DIR}/immich.lib.sh"

# ── Constants ────────────────────────────────────────────────────────────
CONTAINER_PATH_PREFIX="/usr/src/app/upload"
HOST_PATH_PREFIX="/zpool/catallenya/immich/data"
SGT_OFFSET="+08:00"

# ── CLI ──────────────────────────────────────────────────────────────────
TYPE="all"
RUN_OVERRIDE=""
PARALLEL="$(nproc)"
MIN_DATE="1970-01-02"
MAX_DATE=""
FORCE_RERUN=0

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --type=*)        TYPE="${1#*=}"; shift ;;
    --run=*)         RUN_OVERRIDE="${1#*=}"; shift ;;
    --parallel=*)    PARALLEL="${1#*=}"; shift ;;
    --min-date=*)    MIN_DATE="${1#*=}"; shift ;;
    --max-date=*)    MAX_DATE="${1#*=}"; shift ;;
    --force-rerun)   FORCE_RERUN=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$TYPE" in image|video|all) ;; *) echo "error: --type must be image, video, or all" >&2; exit 2 ;; esac
[[ "$PARALLEL" =~ ^[0-9]+$ && "$PARALLEL" -ge 1 ]] || { echo "error: --parallel must be >=1" >&2; exit 2; }
[[ ! "$MIN_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && { echo "error: --min-date must be YYYY-MM-DD" >&2; exit 2; }
[[ -n "$MAX_DATE" && ! "$MAX_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && {
  echo "error: --max-date must be YYYY-MM-DD" >&2; exit 2; }
if [[ -z "$MAX_DATE" ]]; then
  MAX_DATE="$(date -u -d 'tomorrow' +'%Y-%m-%d')"
fi

imapi_require_cmd docker awk stat date timeout
# exiftool may be needed depending on row sources. Probe lazily inside the
# resolver (some runs may only have filename rows).

# ── Resolve run dir ──────────────────────────────────────────────────────
RUN_DIR=""
if [[ -n "$RUN_OVERRIDE" ]]; then
  RUN_DIR="${SCRIPT_DIR}/runs/${RUN_OVERRIDE}"
  [[ -d "$RUN_DIR" ]] || { echo "error: run dir not found: $RUN_DIR" >&2; exit 2; }
else
  shopt -s nullglob
  candidates=("${SCRIPT_DIR}/runs/"*/)
  shopt -u nullglob
  for d in $(printf '%s\n' "${candidates[@]}" | sort -r); do
    d="${d%/}"
    if [[ -f "$d/verify-fixes-summary.txt" && "$FORCE_RERUN" -ne 1 ]]; then continue; fi
    shopt -s nullglob
    pfiles=("$d"/proposed-*.tsv)
    shopt -u nullglob
    (( ${#pfiles[@]} > 0 )) || continue
    RUN_DIR="$d"; break
  done
  [[ -n "$RUN_DIR" ]] || {
    echo "error: no pending run dir found under ${SCRIPT_DIR}/runs/" >&2
    echo "  Run immich.fix-dates.scan.sh first, or pass --run=<ts>." >&2
    exit 2
  }
fi

# Re-run guard
if compgen -G "$RUN_DIR/verified-fixes-*.tsv" > /dev/null || compgen -G "$RUN_DIR/rescued-fixes-*.tsv" > /dev/null; then
  if [[ "$FORCE_RERUN" -ne 1 ]]; then
    echo "error: verify-fixes output already exists in $RUN_DIR" >&2
    echo "  Pass --force-rerun to overwrite." >&2
    exit 2
  fi
  rm -f "$RUN_DIR"/verified-fixes-*.tsv "$RUN_DIR"/rescued-fixes-*.tsv "$RUN_DIR/verify-fixes-summary.txt"
fi

# ── Build the input for the selected type(s) ─────────────────────────────
INPUT_FILE="$(mktemp)"
trap 'rm -f "$INPUT_FILE"' EXIT

types=()
case "$TYPE" in
  image) types=(image) ;;
  video) types=(video) ;;
  all)   types=(image video) ;;
esac
for typ in "${types[@]}"; do
  f="$RUN_DIR/proposed-$typ.tsv"
  [[ -f "$f" ]] && cat "$f" >> "$INPUT_FILE"
done

TOTAL="$(wc -l < "$INPUT_FILE" | tr -d ' ')"

echo "Immich fix-dates verify"
echo "  Run dir:    $RUN_DIR"
echo "  Type:       $TYPE"
echo "  Parallel:   $PARALLEL"
echo "  Range:      [$MIN_DATE, $MAX_DATE]"
echo "  Rows:       $TOTAL"
echo

if [[ "$TOTAL" -eq 0 ]]; then
  echo "Nothing to verify."
  echo "Empty verify: no proposed rows for selected types." > "$RUN_DIR/verify-fixes-summary.txt"
  exit 0
fi

# ── Helpers (mirror scan; kept inline so verify is self-contained) ──────
# Parse a filename and emit ISO-SGT date if pattern matches; else empty.
# Date-only matches default to 12:00:00 SGT.
parse_filename_date() {
  local fname=$1
  local y mo d h mi s
  h=12; mi=0; s=0
  if [[ "$fname" =~ ^(IMG|VID|PXL|PANO)_([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2}) ]]; then
    y="${BASH_REMATCH[2]}"; mo="${BASH_REMATCH[3]}"; d="${BASH_REMATCH[4]}"
    h="${BASH_REMATCH[5]}"; mi="${BASH_REMATCH[6]}"; s="${BASH_REMATCH[7]}"
  elif [[ "$fname" =~ ^video-([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{2})-([0-9]{2})-([0-9]{2})\. ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    h="${BASH_REMATCH[4]}"; mi="${BASH_REMATCH[5]}"; s="${BASH_REMATCH[6]}"
  elif [[ "$fname" =~ ^[0-9]+_([0-9]{13})_ ]]; then
    local _ms _sec _parts
    _ms="${BASH_REMATCH[1]}"
    _sec=$((_ms / 1000))
    if (( _sec < 1000000000 || _sec > 4102444800 )); then return 0; fi
    _parts=$(TZ=Asia/Singapore date -d "@${_sec}" +'%Y %m %d %H %M %S' 2>/dev/null) || return 0
    read -r y mo d h mi s <<<"$_parts"
  elif [[ "$fname" =~ ^IMG([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})\. ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    h="${BASH_REMATCH[4]}"; mi="${BASH_REMATCH[5]}"; s="${BASH_REMATCH[6]}"
  elif [[ "$fname" =~ ^Screenshot_([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2}) ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    h="${BASH_REMATCH[4]}"; mi="${BASH_REMATCH[5]}"; s="${BASH_REMATCH[6]}"
  elif [[ "$fname" =~ ^Screenshot[\ _]([0-9]{4})-([0-9]{2})-([0-9]{2})[\ _-](at[\ _])?([0-9]{2})[.-]([0-9]{2})[.-]([0-9]{2}) ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    h="${BASH_REMATCH[5]}"; mi="${BASH_REMATCH[6]}"; s="${BASH_REMATCH[7]}"
  elif [[ "$fname" =~ ^signal-([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{2})-([0-9]{2})-([0-9]{2}) ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    h="${BASH_REMATCH[4]}"; mi="${BASH_REMATCH[5]}"; s="${BASH_REMATCH[6]}"
  elif [[ "$fname" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})\ ([0-9]{2})\.([0-9]{2})\.([0-9]{2})[-_\ .\(] ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    h="${BASH_REMATCH[4]}"; mi="${BASH_REMATCH[5]}"; s="${BASH_REMATCH[6]}"
  elif [[ "$fname" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})[_.] ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    h="${BASH_REMATCH[4]}"; mi="${BASH_REMATCH[5]}"; s="${BASH_REMATCH[6]}"
  elif [[ "$fname" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2})[_.] ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    h="${BASH_REMATCH[4]}"; mi="${BASH_REMATCH[5]}"; s="${BASH_REMATCH[6]}"
  elif [[ "$fname" =~ ^[Ss]creenshot-([0-9]{13})[_.] ]]; then
    local _ms _sec _parts
    _ms="${BASH_REMATCH[1]}"
    _sec=$((_ms / 1000))
    if (( _sec < 1000000000 || _sec > 4102444800 )); then return 0; fi
    _parts=$(TZ=Asia/Singapore date -d "@${_sec}" +'%Y %m %d %H %M %S' 2>/dev/null) || return 0
    read -r y mo d h mi s <<<"$_parts"
  elif [[ "$fname" =~ ^IMG-([0-9]{4})([0-9]{2})([0-9]{2})-WA[0-9]+\. ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
  elif [[ "$fname" =~ ^VID-([0-9]{4})([0-9]{2})([0-9]{2})-WA[0-9]+\. ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
  elif [[ "$fname" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})\ *[\(][0-9]+[\)]\. ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
  elif [[ "$fname" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})\. ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
  else
    return 0
  fi
  if ! date -d "${y}-${mo}-${d} ${h}:${mi}:${s}" >/dev/null 2>&1; then
    return 0
  fi
  # Force base-10: "08"/"09" are invalid octal under %02d (silently print 0).
  printf '%s-%s-%sT%02d:%02d:%02d%s' "$y" "$mo" "$d" \
    $((10#$h)) $((10#$mi)) $((10#$s)) "$SGT_OFFSET"
}

# Re-read a single source for an asset and return ISO date or empty.
re_read_source() {
  local source=$1 hpath=$2 cpath=$3 fname=$4
  case "$source" in
    exif)
      command -v exiftool >/dev/null 2>&1 || return 0
      [[ -e "$hpath" ]] || return 0
      # Pull date + offset separately (avoid exiftool's %z auto-filling host TZ).
      local raw naked_dt off_dt
      raw=$(timeout 10 exiftool -q -q -s -s -DateTimeOriginal -OffsetTimeOriginal \
              -d "%Y-%m-%dT%H:%M:%S" "$hpath" 2>/dev/null || true)
      naked_dt=""; off_dt=""
      while IFS= read -r ln; do
        case "$ln" in
          DateTimeOriginal*)   naked_dt="${ln#*: }"; naked_dt="${naked_dt// /}" ;;
          OffsetTimeOriginal*) off_dt="${ln#*: }";   off_dt="${off_dt// /}" ;;
        esac
      done <<<"$raw"
      if [[ "$naked_dt" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        if [[ "$off_dt" =~ ^[+-][0-9]{2}:[0-9]{2}$ ]]; then
          printf '%s%s' "$naked_dt" "$off_dt"
        else
          printf '%s%s' "$naked_dt" "$SGT_OFFSET"
        fi
      fi
      ;;
    filename)
      parse_filename_date "$fname"
      ;;
    container)
      local raw
      raw=$(timeout 15 docker exec immich-server ffprobe -v error \
              -show_entries format_tags=creation_time -of csv=p=0 "$cpath" 2>/dev/null || true)
      if [[ -n "$raw" && "$raw" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        printf '%sT%s+00:00' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
      fi
      ;;
    mtime)
      [[ -e "$hpath" ]] || return 0
      local epoch
      epoch=$(stat -c '%Y' "$hpath" 2>/dev/null || true)
      [[ -n "$epoch" ]] && TZ=Asia/Singapore date -d "@$epoch" +'%Y-%m-%dT%H:%M:%S+08:00' 2>/dev/null
      ;;
  esac
}

in_range() {
  local iso=$1 epoch min_epoch max_epoch
  epoch=$(date -d "$iso" +%s 2>/dev/null) || return 1
  min_epoch=$(date -d "${MIN_DATE}T00:00:00+00:00" +%s)
  max_epoch=$(date -d "${MAX_DATE}T23:59:59+00:00" +%s)
  (( epoch >= min_epoch && epoch <= max_epoch ))
}

same_second() {
  local ea eb
  ea=$(date -d "$1" +%s 2>/dev/null) || return 1
  eb=$(date -d "$2" +%s 2>/dev/null) || return 1
  (( ea == eb ))
}

# Verify one row. Reads tab-separated input row from $1.
# Appends a row to either verified-fixes-{type}.tsv (verdict=OK, clean source)
# or rescued-fixes-{type}.tsv (verdict appended as col 8).
verify_one_row() {
  local line=$1
  local uuid current_iso proposed_iso source fname cpath type
  IFS=$'\t' read -r uuid current_iso proposed_iso source fname cpath type <<<"$line"
  local hpath="${cpath/$CONTAINER_PATH_PREFIX/$HOST_PATH_PREFIX}"

  local clean_source="${source%\*}"
  local conflict=0
  [[ "$source" == *"*" ]] && conflict=1

  local verdict=""
  if [[ ! -e "$hpath" ]]; then
    verdict="MISSING"
  elif ! in_range "$proposed_iso"; then
    verdict="OUT_OF_RANGE"
  elif same_second "$proposed_iso" "$current_iso"; then
    verdict="NO_CHANGE"
  elif (( conflict == 1 )); then
    verdict="CONFLICT"
  else
    local re_iso
    re_iso="$(re_read_source "$clean_source" "$hpath" "$cpath" "$fname")"
    if [[ -z "$re_iso" ]] || ! same_second "$re_iso" "$proposed_iso"; then
      verdict="UNSTABLE"
    else
      verdict="OK"
    fi
  fi

  local out_file
  if [[ "$verdict" == "OK" ]]; then
    out_file="$RUN_DIR/verified-fixes-$type.tsv"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$uuid" "$current_iso" "$proposed_iso" "$clean_source" \
      "$fname" "$cpath" "$type" >> "$out_file"
  else
    out_file="$RUN_DIR/rescued-fixes-$type.tsv"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$uuid" "$current_iso" "$proposed_iso" "$source" \
      "$fname" "$cpath" "$type" "$verdict" >> "$out_file"
  fi
}

export -f verify_one_row re_read_source parse_filename_date in_range same_second
export CONTAINER_PATH_PREFIX HOST_PATH_PREFIX SGT_OFFSET MIN_DATE MAX_DATE RUN_DIR

# ── Run verify in parallel ───────────────────────────────────────────────
echo "Verifying $TOTAL rows with $PARALLEL workers..."
< "$INPUT_FILE" xargs -P "$PARALLEL" -d '\n' -I {} \
  bash -c 'verify_one_row "$1"' _ {} || true

# Sort outputs deterministically
for f in "$RUN_DIR"/verified-fixes-*.tsv "$RUN_DIR"/rescued-fixes-*.tsv; do
  [[ -s "$f" ]] || continue
  sort -t $'\t' -k2,2r -o "$f" "$f"
done

# ── Summary ──────────────────────────────────────────────────────────────
write_summary() {
  local sum="$RUN_DIR/verify-fixes-summary.txt"
  {
    echo "Immich fix-dates verify — $(date -u +'%Y-%m-%d_%H-%M-%SZ')"
    echo "Run dir:   $RUN_DIR"
    echo "Type:      $TYPE"
    echo "Range:     [$MIN_DATE, $MAX_DATE]"
    echo "Rows in:   $TOTAL"
    echo
    echo "Outputs:"
    shopt -s nullglob
    for f in "$RUN_DIR"/verified-fixes-*.tsv "$RUN_DIR"/rescued-fixes-*.tsv; do
      [[ -f "$f" ]] || continue
      n=$(wc -l < "$f" | tr -d ' ')
      printf '  %-40s %d\n' "$(basename "$f")" "$n"
    done
    shopt -u nullglob
    echo
    echo "Verdict counts (rescued):"
    shopt -s nullglob
    for f in "$RUN_DIR"/rescued-fixes-*.tsv; do
      [[ -s "$f" ]] || continue
      awk -F'\t' -v F="$(basename "$f")" '{c[$8]++} END {for (v in c) printf "  %-30s %-14s %d\n", F, v, c[v]}' "$f"
    done | sort
    shopt -u nullglob
    echo
    echo "Rescued samples (do NOT apply — review):"
    shopt -s nullglob
    for f in "$RUN_DIR"/rescued-fixes-*.tsv; do
      [[ -s "$f" ]] || continue
      echo "  -- $(basename "$f") --"
      head -10 "$f" | awk -F'\t' '{printf "  %s  %s → %s  [%s, %s]  %s\n", $1, substr($2,1,19), substr($3,1,19), $4, $8, $5}'
    done
    shopt -u nullglob
    echo
    echo "Next: bash immich/scripts/immich.fix-dates.apply.sh --dry-run"
  } | tee "$sum"
}
write_summary
