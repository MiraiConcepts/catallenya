#!/bin/bash
# Verify junk candidates by attempting to play/decode them. Read-only — no
# mutations. Splits each row into verified-junk (safe to delete) or
# rescued (do NOT delete, review).
#
# Default consumes the latest run dir under runs/ that lacks
# verify-summary.txt. Use --run=<ts> for a specific dir, or --audit-run=<ts>
# to verify already-deleted assets from a run's deleted.tsv.
#
# Usage:
#   bash immich/scripts/immich.verify-junk.sh [OPTIONS]
#
# OPTIONS:
#   --type=image|video|all   Which asset type(s) to verify (default: all)
#   --run=<ts>               Specific run dir under runs/<ts>
#   --audit-run=<ts>         Audit mode — verify items in <ts>/deleted.tsv;
#                            writes audit-report.tsv (not split files).
#   --parallel=N             Concurrent verify workers (default: nproc)
#   --timeout=N              Per-file ffmpeg/identify timeout in seconds
#                            (default: 60)
#   --monochrome-stddev=N    Max-channel stddev threshold for Tier C image
#                            (default: 0.1; computed over a white-composited
#                            sRGB image so transparent-bg PNGs aren't FPs)
#   --force-rerun            Overwrite existing verify output in the run dir
#   -h, --help               Show this help.
#
# OUTPUT FILES (normal mode) per run dir:
#   verified-junk-{a,b}-{image,video}.tsv  — rows safe to delete
#   rescued-{a,b}-{image,video}.tsv        — rows that play; DO NOT delete
#   verify-summary.txt                      — counts + sample previews + rescued list
#
# OUTPUT (audit mode):
#   audit-report.tsv  — full per-asset verdicts from the deleted.tsv set
#
# VERDICT TAXONOMY:
#   TINY          bytes < 5 KB (video only) — verified junk (fast-path)
#   MISSING       file does not exist on disk — verified junk (phantom)
#   AUDIO_ONLY    video container with no video stream / B1 audio filename
#                 — verified junk
#   BROKEN        video remux ratio < 30%, OR image fails ffmpeg/identify
#                 — verified junk
#   TRIVIAL       video plays (remux ≥ 80%) BUT content is small/short/
#                 unnamed — likely Telegram sticker / WhatsApp thumbnail.
#                 Also: Tier B image (filename trusted) and Tier C image
#                 whose max-channel stddev (over white composite) confirms
#                 monochrome. — verified junk
#   PARTIAL       video remux ratio 30–79% — rescued (review!)
#   GOOD          video remux ≥ 80% AND meaningful content (size ≥ 1MB
#                 OR camera-prefix name OR duration ≥ 5s OR min dim ≥ 240px),
#                 OR image passes both ffmpeg+identify, OR Tier C image
#                 whose stddev exceeds --monochrome-stddev (e.g. transparent-bg
#                 PNG with real content) — rescued (DO NOT delete)
#   VERIFY_ERROR  ffmpeg/identify/convert crash, timeout, or non-numeric output
#                 — rescued (default safe; covers giant PNGs that exhaust IM
#                 cache, etc.)
#
# EXIT CODES:
#   0  verify completed; check rescued/verified-junk files for results
#   1  partial failures (some verify calls errored); inspect output
#   2  aborted (bad args, run dir missing, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=immich.lib.sh
. "${SCRIPT_DIR}/immich.lib.sh"

# ── Constants ─────────────────────────────────────────────────────────────
# TINY fast-path: skip ffmpeg only for files structurally too small to be
# any video at all (< 5 KB cannot encode a single decodable frame at any
# resolution). Larger candidates always go through real verification.
TINY_VIDEO=5000
RATIO_GOOD=80
RATIO_PARTIAL=30
CONTAINER_PATH_PREFIX="/usr/src/app/upload"
HOST_PATH_PREFIX="/zpool/catallenya/immich/data"
B1_REGEX='^(AUD|PTT)-.*\.3gp$'

# A video that PLAYS may still be functionally junk (e.g. Telegram 94x52
# stickers, WhatsApp 5 KB clips). To earn GOOD/rescue, a remuxable video
# must clear ONE of these "meaningful content" gates:
#   1. file size >= 1 MB (real video content is at least this size), OR
#   2. filename has camera prefix (PXL_, IMG_, VID_, etc — real captures)
# Dim and duration signals were tried but produced too many false GOODs
# (Telegram stickers at 320x240, WhatsApp clips at 10s). The above two
# signals match user intent: rescue obvious-user-content, leave the rest.
MEANINGFUL_BYTES=1000000
# Filenames produced by real cameras (Android: VID_/PXL_/IMG_; iPhone: IMG_/MOV_;
# others: DSC_/MVI_). Underscore separator distinguishes from messaging app
# names like VID-20190315-WA0019.mp4 (WhatsApp uses hyphen).
MEANINGFUL_NAME_REGEX='^(PXL_|IMG_|VID_|DSC_|MOV_|MVI_)'

# ── CLI ──────────────────────────────────────────────────────────────────
TYPE="all"
RUN_OVERRIDE=""
AUDIT_RUN=""
PARALLEL="$(nproc)"
TIMEOUT=60
FORCE_RERUN=0
MONO_STDDEV="0.1"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --type=*)               TYPE="${1#*=}"; shift ;;
    --run=*)                RUN_OVERRIDE="${1#*=}"; shift ;;
    --audit-run=*)          AUDIT_RUN="${1#*=}"; shift ;;
    --parallel=*)           PARALLEL="${1#*=}"; shift ;;
    --timeout=*)            TIMEOUT="${1#*=}"; shift ;;
    --monochrome-stddev=*)  MONO_STDDEV="${1#*=}"; shift ;;
    --force-rerun)          FORCE_RERUN=1; shift ;;
    -h|--help)              usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$TYPE" in image|video|all) ;; *) echo "error: --type must be image, video, or all" >&2; exit 2 ;; esac
[[ "$PARALLEL" =~ ^[0-9]+$ && "$PARALLEL" -ge 1 ]] || { echo "error: --parallel must be >=1" >&2; exit 2; }
[[ "$TIMEOUT" =~ ^[0-9]+$ && "$TIMEOUT" -ge 1 ]] || { echo "error: --timeout must be >=1" >&2; exit 2; }
[[ "$MONO_STDDEV" =~ ^0?\.[0-9]+$ ]] || { echo "error: --monochrome-stddev must be a positive decimal like 0.1" >&2; exit 2; }
[[ -n "$AUDIT_RUN" && -n "$RUN_OVERRIDE" ]] && { echo "error: --audit-run and --run are mutually exclusive" >&2; exit 2; }

# `convert` is only needed if a tier-c-image.tsv exists in the run dir.
# Probed below once RUN_DIR is resolved.
imapi_require_cmd docker identify awk sort timeout
# ffmpeg/ffprobe live inside immich-server, not host. Probe in-container:
docker exec immich-server which ffmpeg ffprobe >/dev/null || { echo "error: ffmpeg/ffprobe missing in immich-server" >&2; exit 2; }

# ── Resolve run dir ──────────────────────────────────────────────────────
RUN_DIR=""
if [[ -n "$AUDIT_RUN" ]]; then
  RUN_DIR="${SCRIPT_DIR}/runs/${AUDIT_RUN}"
  [[ -d "$RUN_DIR" ]] || { echo "error: run dir not found: $RUN_DIR" >&2; exit 2; }
  [[ -f "$RUN_DIR/deleted.tsv" ]] || { echo "error: no deleted.tsv in $RUN_DIR (--audit-run requires a processed delete run)" >&2; exit 2; }
elif [[ -n "$RUN_OVERRIDE" ]]; then
  RUN_DIR="${SCRIPT_DIR}/runs/${RUN_OVERRIDE}"
  [[ -d "$RUN_DIR" ]] || { echo "error: run dir not found: $RUN_DIR" >&2; exit 2; }
else
  # Auto-pick: latest dir under runs/ that has tier files and no verify-summary.txt
  shopt -s nullglob
  candidates=("${SCRIPT_DIR}/runs/"*/)
  shopt -u nullglob
  for d in $(printf '%s\n' "${candidates[@]}" | sort -r); do
    d="${d%/}"
    if [[ -f "$d/verify-summary.txt" && "$FORCE_RERUN" -ne 1 ]]; then continue; fi
    shopt -s nullglob
    tfiles=("$d/tier-"*.tsv)
    shopt -u nullglob
    (( ${#tfiles[@]} > 0 )) || continue
    RUN_DIR="$d"; break
  done
  [[ -n "$RUN_DIR" ]] || {
    echo "error: no pending run dir found under ${SCRIPT_DIR}/runs/" >&2
    echo "  Run immich.find-junk.sh first, or pass --run=<ts> / --audit-run=<ts>." >&2
    exit 2
  }
fi

# Re-run guard
if [[ -z "$AUDIT_RUN" ]]; then
  if ls "$RUN_DIR"/verified-junk-*.tsv "$RUN_DIR"/rescued-*.tsv 2>/dev/null | grep -q .; then
    if [[ "$FORCE_RERUN" -ne 1 ]]; then
      echo "error: verify output already exists in $RUN_DIR" >&2
      echo "  Pass --force-rerun to overwrite." >&2
      exit 2
    fi
    rm -f "$RUN_DIR"/verified-junk-*.tsv "$RUN_DIR"/rescued-*.tsv "$RUN_DIR/verify-summary.txt"
  fi
else
  if [[ -f "$RUN_DIR/audit-report.tsv" && "$FORCE_RERUN" -ne 1 ]]; then
    echo "error: audit-report.tsv already exists in $RUN_DIR. Pass --force-rerun to overwrite." >&2
    exit 2
  fi
  rm -f "$RUN_DIR/audit-report.tsv"
fi

# Conditional dependency: monochrome verify needs ImageMagick `convert` on host.
if [[ -s "$RUN_DIR/tier-c-image.tsv" ]]; then
  imapi_require_cmd convert
fi

# ── Build the enriched input (TSV with originalPath) ─────────────────────
# Format: uuid<TAB>tier<TAB>type<TAB>bytes<TAB>path<TAB>filename<TAB>duration
ENRICHED="$(mktemp)"
trap 'rm -f "$ENRICHED" "$TMP_OUT" 2>/dev/null' EXIT
TMP_OUT="$(mktemp)"

collect_input_audit() {
  # Audit mode: pull UUIDs from deleted.tsv; look up type + path from DB
  local uuids_csv
  uuids_csv=$(awk -F'\t' '{printf "'\''"$1"'\'',"}' "$RUN_DIR/deleted.tsv" | sed 's/,$//')
  [[ -n "$uuids_csv" ]] || return 0
  docker exec -i immich-postgres psql -U postgres -d immich -A -t -F $'\t' --pset=footer=off <<SQL
SELECT a.id, '-' AS tier, lower(a.type::text),
       COALESCE(e."fileSizeInByte"::text, '0'),
       a."originalPath", a."originalFileName",
       CASE WHEN a.duration ~ '^[0-9]{2}:[0-9]{2}:[0-9]{2}'
            THEN ROUND(EXTRACT(EPOCH FROM a.duration::interval)::numeric, 3)::text
            ELSE '' END
FROM asset a LEFT JOIN asset_exif e ON e."assetId" = a.id
WHERE a.id IN (${uuids_csv}) AND a."deletedAt" IS NOT NULL;
SQL
}

collect_input_normal() {
  # Normal mode: read tier files for selected types, enrich with originalPath.
  # Tier `c` only exists for image type (added by --enable-monochrome in find-junk).
  local types=() tiers=(a b c)
  case "$TYPE" in
    image) types=(image) ;;
    video) types=(video) ;;
    all)   types=(image video) ;;
  esac
  for typ in "${types[@]}"; do
    for tier in "${tiers[@]}"; do
      local f="$RUN_DIR/tier-$tier-$typ.tsv"
      [[ -f "$f" ]] || continue
      # Read UUIDs to look up paths
      local uuids_csv
      uuids_csv=$(awk -F'\t' '{printf "'\''"$1"'\'',"}' "$f" | sed 's/,$//')
      [[ -n "$uuids_csv" ]] || continue
      # Map UUID → path
      local pmap
      pmap=$(docker exec -i immich-postgres psql -U postgres -d immich -A -t -F $'\t' --pset=footer=off <<SQL
SELECT id, "originalPath" FROM asset WHERE id IN (${uuids_csv});
SQL
      )
      # Join tier file + path map: emit uuid<tier><type><bytes><path><filename><duration>
      awk -F'\t' -v TIER="$tier" -v TYP="$typ" '
        FNR==NR { path[$1]=$2; next }
        {
          # tier file row: $1=uuid $2=tier_letter $3=w $4=h $5=bytes $6=fname $7=dur
          p = path[$1]
          if (p == "") next
          printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1, TIER, TYP, $5, p, $6, $7
        }
      ' <(printf '%s\n' "$pmap") "$f"
    done
  done
}

if [[ -n "$AUDIT_RUN" ]]; then
  collect_input_audit > "$ENRICHED"
else
  collect_input_normal > "$ENRICHED"
fi

TOTAL=$(wc -l < "$ENRICHED" | tr -d ' ')

# ── Pre-flight ───────────────────────────────────────────────────────────
echo "Verify junk candidates"
echo "  Run dir:        $RUN_DIR"
echo "  Type:           $TYPE"
echo "  Mode:           $([[ -n "$AUDIT_RUN" ]] && echo 'AUDIT (reads deleted.tsv)' || echo 'normal')"
echo "  Parallel:       $PARALLEL"
echo "  Timeout/file:   ${TIMEOUT}s"
echo "  Candidates:     $TOTAL"
echo

if [[ "$TOTAL" -eq 0 ]]; then
  echo "Nothing to verify."
  if [[ -z "$AUDIT_RUN" ]]; then
    : > "$RUN_DIR/verify-summary.txt"
    echo "Empty run: no tier files or all tier files empty." > "$RUN_DIR/verify-summary.txt"
  fi
  exit 0
fi

# ── Per-row verify function ──────────────────────────────────────────────
# Exported and called by xargs -P. Reads one tab-separated row, emits one
# tab-separated row with verdict + ratio_pct appended.
# Row in:  uuid<TAB>tier<TAB>type<TAB>bytes<TAB>cpath<TAB>fname<TAB>dur
# Row out: uuid<TAB>tier<TAB>type<TAB>bytes<TAB>cpath<TAB>fname<TAB>dur<TAB>verdict<TAB>ratio_pct
verify_one_row() {
  local line=$1
  local uuid tier typ bytes cpath fname dur
  IFS=$'\t' read -r uuid tier typ bytes cpath fname dur <<<"$line"
  local hpath="${cpath/$CONTAINER_PATH_PREFIX/$HOST_PATH_PREFIX}"

  local emit_verdict="" emit_ratio="-"

  # Existence check (host)
  if [[ ! -e "$hpath" ]]; then
    emit_verdict="MISSING"
  elif [[ "$typ" == "video" ]]; then
    if (( bytes < TINY_VIDEO )); then
      emit_verdict="TINY"
    elif [[ "$fname" =~ $B1_REGEX ]]; then
      emit_verdict="AUDIO_ONLY"
    else
      # Stream check: does it have a video stream?
      local codec
      codec=$(docker exec immich-server timeout "$TIMEOUT" ffprobe -v error \
        -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$cpath" 2>/dev/null || echo "")
      if [[ -z "$codec" ]]; then
        emit_verdict="AUDIO_ONLY"
      else
        # Remux test. MP4 muxer needs seekable output, so write to a
        # per-PID temp file in the container, stat it, then unlink.
        local remux
        remux=$(docker exec immich-server bash -c '
          set -e
          tmp="/tmp/verify-remux-$$.mp4"
          trap "rm -f \"\$tmp\"" EXIT
          timeout '"$TIMEOUT"' ffmpeg -v error -i "$1" -c copy -f mp4 -y "$tmp" >/dev/null 2>&1 || { echo 0; exit 0; }
          stat -c %s "$tmp"
        ' _ "$cpath" 2>/dev/null || echo "0")
        if [[ -z "$remux" || "$remux" == "0" ]]; then
          emit_verdict="VERIFY_ERROR"
        else
          local ratio=$(( remux * 100 / bytes ))
          emit_ratio="$ratio"
          if (( ratio < RATIO_PARTIAL )); then
            emit_verdict="BROKEN"
          elif (( ratio < RATIO_GOOD )); then
            emit_verdict="PARTIAL"
          else
            # Remux is healthy. But is the content meaningful, or just a
            # tiny sticker/thumbnail that happens to be a valid container?
            if (( bytes >= MEANINGFUL_BYTES )) || [[ "$fname" =~ $MEANINGFUL_NAME_REGEX ]]; then
              emit_verdict="GOOD"
            else
              emit_verdict="TRIVIAL"
            fi
          fi
        fi
      fi
    fi
  else  # image
    if [[ "$tier" =~ ^[bB]$ ]]; then
      # Tier B image: filename pattern was the junk signal. Don't second-guess
      # via decode — a valid messaging GIF (e.g. imgur reaction) decodes fine
      # but is exactly the junk the user wants gone. Trust the filename match.
      emit_verdict="TRIVIAL"
    elif [[ "$tier" =~ ^[cC]$ ]]; then
      # Tier C image: monochrome candidate. Composite over white (so transparent
      # PNG content shows against the bg instead of hiding in stored-as-black
      # alpha pixels), then measure max-channel stddev. Empty / non-numeric
      # output (e.g. giant images that exhaust IM's cache) → VERIFY_ERROR rescue.
      local stddev
      stddev=$(timeout "$TIMEOUT" convert "$hpath" -background white -alpha remove -alpha off -colorspace sRGB \
                -format '%[fx:max(standard_deviation.r,max(standard_deviation.g,standard_deviation.b))]' \
                info: 2>/dev/null || echo "")
      if [[ -z "$stddev" || ! "$stddev" =~ ^[0-9.eE+-]+$ ]]; then
        emit_verdict="VERIFY_ERROR"
      elif awk -v s="$stddev" -v t="$MONO_STDDEV" 'BEGIN{exit !(s+0 < t+0)}'; then
        emit_verdict="TRIVIAL"
      else
        emit_verdict="GOOD"
      fi
      emit_ratio="$stddev"  # repurpose ratio column for the stddev value
    else
      # Tier A image: physical-impossibility candidate. Verify is the FP rescue.
      if ! docker exec immich-server timeout "$TIMEOUT" \
           ffmpeg -v error -i "$cpath" -frames:v 1 -f null - >/dev/null 2>&1; then
        emit_verdict="BROKEN"
      elif ! timeout "$TIMEOUT" identify "$hpath" >/dev/null 2>&1; then
        emit_verdict="BROKEN"
      elif (( bytes >= 500000 )) || [[ "$fname" =~ $MEANINGFUL_NAME_REGEX ]]; then
        emit_verdict="GOOD"
      else
        emit_verdict="TRIVIAL"
      fi
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$uuid" "$tier" "$typ" "$bytes" "$cpath" "$fname" "$dur" "$emit_verdict" "$emit_ratio"
}
export -f verify_one_row
export TIMEOUT TINY_VIDEO RATIO_GOOD RATIO_PARTIAL CONTAINER_PATH_PREFIX HOST_PATH_PREFIX B1_REGEX
export MEANINGFUL_BYTES MEANINGFUL_NAME_REGEX MONO_STDDEV

# ── Run verify in parallel ───────────────────────────────────────────────
echo "Verifying $TOTAL candidates with $PARALLEL parallel workers..."
< "$ENRICHED" xargs -P "$PARALLEL" -d '\n' -I {} bash -c 'verify_one_row "$1"' _ {} > "$TMP_OUT"

# ── Write output files ───────────────────────────────────────────────────
write_output() {
  if [[ -n "$AUDIT_RUN" ]]; then
    # Audit: single file with all rows
    mv "$TMP_OUT" "$RUN_DIR/audit-report.tsv"
    return
  fi
  # Normal: split into verified-junk-* and rescued-* by (tier, type, verdict)
  awk -F'\t' -v RUN_DIR="$RUN_DIR" '
    {
      uuid=$1; tier=$2; typ=$3; verdict=$8
      verified_set = (verdict=="TINY" || verdict=="MISSING" || verdict=="AUDIO_ONLY" || verdict=="BROKEN" || verdict=="TRIVIAL")
      file = RUN_DIR "/" (verified_set ? "verified-junk-" : "rescued-") tier "-" typ ".tsv"
      print >> file
    }
  ' "$TMP_OUT"
  rm -f "$TMP_OUT"
}
write_output

# ── Summary ──────────────────────────────────────────────────────────────
write_summary() {
  local sum="$RUN_DIR/verify-summary.txt"
  {
    echo "Immich verify-junk — $(date -u +'%Y-%m-%d_%H-%M-%SZ')"
    echo "Run dir:   $RUN_DIR"
    echo "Type:      $TYPE"
    echo "Mode:      $([[ -n "$AUDIT_RUN" ]] && echo 'AUDIT' || echo 'normal')"
    echo "Total:     $TOTAL candidates"
    echo
    echo "Verdict counts:"
    if [[ -n "$AUDIT_RUN" ]]; then
      awk -F'\t' '{c[$8]++} END {for (v in c) printf "  %-14s %d\n", v, c[v]}' \
        "$RUN_DIR/audit-report.tsv" | sort
    else
      shopt -s nullglob
      for f in "$RUN_DIR"/verified-junk-*.tsv "$RUN_DIR"/rescued-*.tsv; do
        [[ -f "$f" ]] || continue
        awk -F'\t' -v F="$(basename "$f")" '{c[$8]++} END {for (v in c) printf "  %-30s %-14s %d\n", F, v, c[v]}' "$f"
      done | sort
      shopt -u nullglob
    fi
    echo
    if [[ -z "$AUDIT_RUN" ]]; then
      echo "RESCUED items (do NOT delete — review):"
      shopt -s nullglob
      for f in "$RUN_DIR"/rescued-*.tsv; do
        [[ -s "$f" ]] || continue
        echo "  -- $(basename "$f") --"
        awk -F'\t' '{printf "  %s  [%s,%s%%]  %s bytes  %s\n", $1, $8, $9, $4, $6}' "$f"
      done
      shopt -u nullglob
    fi
  } | tee "$sum"
}
write_summary
