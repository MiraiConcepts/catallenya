#!/bin/bash
# Find junk/artifact assets in the Immich library. Read-only — no mutations.
#
# Supports both IMAGE and VIDEO asset types. Default scans both.
#
# Writes a timestamped run directory under immich/scripts/runs/<ts>/ containing
# up to five tier files plus a human-readable summary:
#   tier-a-image.tsv    Image Tier A (physical: tiny dim/bytes/missing)
#   tier-b-image.tsv    Image Tier B (Android UI sprite + tracking pixel names)
#   tier-c-image.tsv    Image Tier C (low-bpp prefilter, opt-in monochrome)
#   tier-a-video.tsv    Video Tier A (physical: tiny bytes/dim/missing duration)
#   tier-b-video.tsv    Video Tier B (WhatsApp voice-note .3gp pattern)
#   summary.txt         Counts and 5-sample previews per tier
#
# TSV columns (uniform across image/video):
#   uuid<TAB>tier<TAB>width<TAB>height<TAB>fileSizeInByte<TAB>originalFileName<TAB>duration_sec
# `duration_sec` is empty for IMAGE rows; numeric (or empty if unparseable)
# for VIDEO rows.
#
# IMAGE Tier A — perfect specificity, physical impossibility of being a real photo:
#   A1  width * height < 10000             (smaller than ~100×100 effective)
#   A2  fileSizeInByte < 5000              (under 5 KB)
#   A3  width/height NULL OR fileSizeInByte NULL/0
#
# IMAGE Tier B — filename pattern:
#   - Android-UI prefix set + tracking pixels (original)
#   - GIF source patterns (imgur URL IDs, gfycat 3-word names, tumblr/ezgif/
#     reddit-cache filenames) — narrow regexes that catch messaging/web cache
#     GIFs while sparing iPhone IMG_*.GIF, date-named screen recordings, and
#     user-saved descriptive names. Verify rescues anything that doesn't fit.
#
# IMAGE Tier C — monochrome / single-color candidates (opt-in):
#   Enabled by --enable-monochrome. SQL prefilter only:
#     bytes / (width*height) < --monochrome-bpp-max (default 0.01) AND
#     width >= 200 AND height >= 200
#   This is a *candidate set* — the precise per-pixel stddev classification
#   runs in verify-junk.sh (composites over white, then max-channel stddev <
#   --monochrome-stddev, default 0.1). Verify is the FP rescue: PNGs with
#   transparent backgrounds and any image whose ImageMagick read fails are
#   routed to rescued-c-image.tsv.
#
# VIDEO Tier A — physical impossibility for a real video:
#   A1  fileSizeInByte < 50000             (under 50 KB; no real video compresses below)
#   A2  width * height < 10000             (sub-100×100 effective)
#   A3  (width/height NULL or 0) AND fileSizeInByte < 5000000  (5 MB)
#   A4  (duration NULL or unparseable) AND fileSizeInByte < 5000000  (5 MB)
#       Size guards are essential — Immich can have real GB-scale videos
#       with NULL dims/duration when metadata extraction is incomplete.
#       The 5 MB ceiling spares all real captures (any meaningful video
#       is much bigger than 5 MB) while still catching audio-only .3gp
#       and broken micro-clips. Rule of thumb: if find-junk's heuristic
#       might catch a real file, verify-junk is the structural backstop —
#       it remux-tests every candidate and rescues anything that plays.
#
# VIDEO Tier B — WhatsApp voice-note pattern:
#   ^(AUD|PTT)-.*\.3gp$                    (audio messages Immich classifies as VIDEO)
#
# Defensive filters applied to BOTH tiers, BOTH types (zero-false-positive bar):
#   status='active' AND deletedAt IS NULL AND visibility='timeline'
#   AND isFavorite = false AND not present in any album
#
# Usage:
#   bash immich/scripts/immich.find-junk.sh                # default: --type=all
#   bash immich/scripts/immich.find-junk.sh --type=image
#   bash immich/scripts/immich.find-junk.sh --type=video
#   bash immich/scripts/immich.find-junk.sh --enable-monochrome
#   bash immich/scripts/immich.find-junk.sh --enable-monochrome --monochrome-bpp-max=0.005

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=immich.lib.sh
. "${SCRIPT_DIR}/immich.lib.sh"

TYPE="all"
ENABLE_MONOCHROME=0
MONOCHROME_BPP_MAX="0.01"
usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --type=*)                TYPE="${1#*=}"; shift ;;
    --enable-monochrome)     ENABLE_MONOCHROME=1; shift ;;
    --monochrome-bpp-max=*)  MONOCHROME_BPP_MAX="${1#*=}"; shift ;;
    -h|--help)               usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$TYPE" in
  image|video|all) ;;
  *) echo "error: --type must be image, video, or all" >&2; exit 2 ;;
esac
[[ "$MONOCHROME_BPP_MAX" =~ ^0?\.[0-9]+$ ]] || {
  echo "error: --monochrome-bpp-max must be a positive decimal like 0.01" >&2; exit 2; }

imapi_require_cmd docker awk

# Verify immich-postgres is up. psql runs inside the container, not on the host.
if [[ "$(docker inspect -f '{{.State.Running}}' immich-postgres 2>/dev/null)" != "true" ]]; then
  echo "error: immich-postgres container is not running" >&2
  exit 1
fi

RUN_TS="$(date -u +'%Y-%m-%d_%H-%M-%SZ')"
RUN_DIR="${SCRIPT_DIR}/runs/${RUN_TS}"
mkdir -p "${RUN_DIR}"
SUMMARY_FILE="${RUN_DIR}/summary.txt"

echo "Running junk detection — type=${TYPE}, output: ${RUN_DIR}"

# Partition a psql result blob (tab-separated, with col 2 = tier letter)
# into per-tier output files for the given asset type.
partition_to_tiers() {
  local type_lc="$1"
  local psql_out="$2"
  local a_file="${RUN_DIR}/tier-a-${type_lc}.tsv"
  local b_file="${RUN_DIR}/tier-b-${type_lc}.tsv"
  : > "${a_file}"
  : > "${b_file}"
  printf '%s\n' "${psql_out}" | awk -F'\t' -v A="${a_file}" -v B="${b_file}" '
    NF >= 6 && $2 == "A" { print >> A }
    NF >= 6 && $2 == "B" { print >> B }
  '
}

img_a_count=0; img_b_count=0; img_c_count=0; img_union_count=0
vid_a_count=0; vid_b_count=0; vid_union_count=0

# ── IMAGE ─────────────────────────────────────────────────────────────────
if [[ "${TYPE}" == "image" || "${TYPE}" == "all" ]]; then
  img_psql_out="$(docker exec -i immich-postgres \
    psql -U postgres -d immich -A -t -F $'\t' --pset=footer=off \
         -v ON_ERROR_STOP=1 <<'SQL'
WITH base AS (
  SELECT a.id, a.width, a.height, a."originalFileName",
         e."fileSizeInByte"
  FROM asset a
  LEFT JOIN asset_exif e ON e."assetId" = a.id
  WHERE a.type = 'IMAGE'
    AND a.status = 'active'
    AND a."deletedAt" IS NULL
    AND a.visibility = 'timeline'
    AND a."isFavorite" = false
    AND NOT EXISTS (SELECT 1 FROM album_asset aa WHERE aa."assetId" = a.id)
),
tier_a AS (
  SELECT id, 'A' AS tier, width, height, "fileSizeInByte", "originalFileName"
  FROM base
  WHERE
       (width * height < 10000)                                    -- A1
    OR ("fileSizeInByte" < 5000)                                   -- A2
    OR (width IS NULL OR height IS NULL
        OR "fileSizeInByte" IS NULL OR "fileSizeInByte" = 0)       -- A3
),
tier_b AS (
  SELECT id, 'B' AS tier, width, height, "fileSizeInByte", "originalFileName"
  FROM base
  WHERE
       "originalFileName" ~* '^(abc_|ic_|btn_|menu_|tab_|notification_|status_|tooltip_|design_|emoji_).*\.(png|jpg|gif|webp)$'
    OR "originalFileName" IN ('indexer.gif','s.gif','mime.jpg','inherit.gif',
                              'spacer.gif','transparent.gif','blank.gif',
                              'pixel.gif','dot.gif','clear.gif')
    -- GIF source patterns (messaging / image hosts / web editors):
    OR "originalFileName" ~  '^[A-Za-z0-9]{5,9}\.gif$'                          -- imgur URL ID
    OR "originalFileName" ~  '^([A-Z][a-z]+){3}(-size_restricted)?\.gif$'       -- gfycat 3-word
    OR "originalFileName" ~  '^[0-9a-z]{10,15}\.gif$'                           -- reddit/cache hash-ish
    OR "originalFileName" ~* '^tumblr_.+\.gif$'                                 -- tumblr
    OR "originalFileName" ~* '^ezgif\.com-.+\.gif$'                             -- ezgif web editor intermediates
    OR "originalFileName" ~  '^[0-9a-f]{16,}\.gif$'                             -- hash-named
)
SELECT id::text, tier, COALESCE(width::text, ''), COALESCE(height::text, ''),
       COALESCE("fileSizeInByte"::text, ''), "originalFileName", ''
FROM tier_a
UNION ALL
SELECT id::text, tier, COALESCE(width::text, ''), COALESCE(height::text, ''),
       COALESCE("fileSizeInByte"::text, ''), "originalFileName", ''
FROM tier_b
ORDER BY 2, 5 NULLS FIRST;  -- tier, then fileSizeInByte
SQL
  )"
  partition_to_tiers image "${img_psql_out}"
  img_a_count="$(wc -l < "${RUN_DIR}/tier-a-image.tsv" | tr -d ' ')"
  img_b_count="$(wc -l < "${RUN_DIR}/tier-b-image.tsv" | tr -d ' ')"

  # Tier C (opt-in): monochrome candidates by low bytes-per-pixel prefilter.
  # Per-pixel stddev classification runs in verify-junk.sh.
  : > "${RUN_DIR}/tier-c-image.tsv"
  if [[ "${ENABLE_MONOCHROME}" -eq 1 ]]; then
    img_tier_c_out="$(docker exec -i immich-postgres \
      psql -U postgres -d immich -A -t -F $'\t' --pset=footer=off \
           -v bpp_max="${MONOCHROME_BPP_MAX}" \
           -v ON_ERROR_STOP=1 <<'SQL'
WITH base AS (
  SELECT a.id, a.width, a.height, a."originalFileName",
         e."fileSizeInByte"
  FROM asset a
  LEFT JOIN asset_exif e ON e."assetId" = a.id
  WHERE a.type = 'IMAGE'
    AND a.status = 'active'
    AND a."deletedAt" IS NULL
    AND a.visibility = 'timeline'
    AND a."isFavorite" = false
    AND NOT EXISTS (SELECT 1 FROM album_asset aa WHERE aa."assetId" = a.id)
)
SELECT id::text, 'C',
       COALESCE(width::text, ''), COALESCE(height::text, ''),
       COALESCE("fileSizeInByte"::text, ''), "originalFileName", ''
FROM base
WHERE width >= 200 AND height >= 200
  AND "fileSizeInByte" IS NOT NULL AND "fileSizeInByte" > 1024
  AND ("fileSizeInByte"::float / NULLIF(width * height, 0)) < :bpp_max
ORDER BY ("fileSizeInByte"::float / NULLIF(width * height, 0)) ASC;
SQL
    )"
    printf '%s\n' "${img_tier_c_out}" | awk 'NF>=6' > "${RUN_DIR}/tier-c-image.tsv"
  fi
  img_c_count="$(wc -l < "${RUN_DIR}/tier-c-image.tsv" | tr -d ' ')"

  img_union_count="$(cat "${RUN_DIR}/tier-a-image.tsv" "${RUN_DIR}/tier-b-image.tsv" "${RUN_DIR}/tier-c-image.tsv" \
    | awk -F'\t' '!seen[$1]++' | wc -l | tr -d ' ')"
fi

# ── VIDEO ─────────────────────────────────────────────────────────────────
if [[ "${TYPE}" == "video" || "${TYPE}" == "all" ]]; then
  vid_psql_out="$(docker exec -i immich-postgres \
    psql -U postgres -d immich -A -t -F $'\t' --pset=footer=off \
         -v ON_ERROR_STOP=1 <<'SQL'
WITH base AS (
  SELECT a.id, a.width, a.height, a."originalFileName", a.duration,
         e."fileSizeInByte"
  FROM asset a
  LEFT JOIN asset_exif e ON e."assetId" = a.id
  WHERE a.type = 'VIDEO'
    AND a.status = 'active'
    AND a."deletedAt" IS NULL
    AND a.visibility = 'timeline'
    AND a."isFavorite" = false
    AND NOT EXISTS (SELECT 1 FROM album_asset aa WHERE aa."assetId" = a.id)
),
parsed AS (
  SELECT id, width, height, "originalFileName", "fileSizeInByte",
         CASE WHEN duration ~ '^[0-9]{2}:[0-9]{2}:[0-9]{2}'
              THEN EXTRACT(EPOCH FROM duration::interval)
              ELSE NULL END AS duration_sec
  FROM base
),
tier_a AS (
  SELECT id, 'A' AS tier, width, height, "fileSizeInByte", "originalFileName", duration_sec
  FROM parsed
  WHERE
       ("fileSizeInByte" < 50000)                                  -- A1
    OR (width * height < 10000)                                    -- A2
    OR ((width IS NULL OR height IS NULL OR width = 0 OR height = 0)
        AND "fileSizeInByte" < 5000000)                            -- A3 (size-guarded, 5 MB)
    OR ((duration_sec IS NULL) AND "fileSizeInByte" < 5000000)     -- A4 (size-guarded, 5 MB)
),
tier_b AS (
  SELECT id, 'B' AS tier, width, height, "fileSizeInByte", "originalFileName", duration_sec
  FROM parsed
  WHERE "originalFileName" ~* '^(AUD|PTT)-.*\.3gp$'
)
SELECT id::text, tier, COALESCE(width::text, ''), COALESCE(height::text, ''),
       COALESCE("fileSizeInByte"::text, ''), "originalFileName",
       COALESCE(duration_sec::text, '')
FROM tier_a
UNION ALL
SELECT id::text, tier, COALESCE(width::text, ''), COALESCE(height::text, ''),
       COALESCE("fileSizeInByte"::text, ''), "originalFileName",
       COALESCE(duration_sec::text, '')
FROM tier_b
ORDER BY 2, 5 NULLS FIRST;
SQL
  )"
  partition_to_tiers video "${vid_psql_out}"
  vid_a_count="$(wc -l < "${RUN_DIR}/tier-a-video.tsv" | tr -d ' ')"
  vid_b_count="$(wc -l < "${RUN_DIR}/tier-b-video.tsv" | tr -d ' ')"
  vid_union_count="$(cat "${RUN_DIR}/tier-a-video.tsv" "${RUN_DIR}/tier-b-video.tsv" \
    | awk -F'\t' '!seen[$1]++' | wc -l | tr -d ' ')"
fi

# ── Summary ───────────────────────────────────────────────────────────────
{
  echo "Immich junk detection — ${RUN_TS}"
  echo "Run dir: ${RUN_DIR}"
  echo "Type: ${TYPE}"
  echo
  echo "Defensive filters (all queries):"
  echo "  status=active, deletedAt IS NULL, visibility=timeline"
  echo "  isFavorite=false, not in any album"
  echo
  if [[ "${TYPE}" == "image" || "${TYPE}" == "all" ]]; then
    echo "── IMAGE ──"
    printf '  %-50s %s\n' "Tier A (physical: tiny dim/bytes/missing)"      "${img_a_count} assets"
    printf '  %-50s %s\n' "Tier B (Android UI sprite/tracking pixel names)" "${img_b_count} assets"
    if [[ "${ENABLE_MONOCHROME}" -eq 1 ]]; then
      printf '  %-50s %s\n' "Tier C (low-bpp monochrome prefilter, bpp<${MONOCHROME_BPP_MAX})" "${img_c_count} assets"
    fi
    printf '  %-50s %s\n' "Unique assets across tiers"                     "${img_union_count} assets"
    echo
    echo "Sample (5 smallest, Image Tier A):"
    head -n 5 "${RUN_DIR}/tier-a-image.tsv" \
      | awk -F'\t' '{printf "  %s  %sx%s  %s bytes  %s\n", $1, $3, $4, $5, $6}'
    echo
    echo "Sample (5 smallest, Image Tier B):"
    head -n 5 "${RUN_DIR}/tier-b-image.tsv" \
      | awk -F'\t' '{printf "  %s  %sx%s  %s bytes  %s\n", $1, $3, $4, $5, $6}'
    echo
    if [[ "${ENABLE_MONOCHROME}" -eq 1 ]]; then
      echo "Sample (5 lowest-bpp, Image Tier C):"
      head -n 5 "${RUN_DIR}/tier-c-image.tsv" \
        | awk -F'\t' '{printf "  %s  %sx%s  %s bytes  %s\n", $1, $3, $4, $5, $6}'
      echo
    fi
  fi
  if [[ "${TYPE}" == "video" || "${TYPE}" == "all" ]]; then
    echo "── VIDEO ──"
    printf '  %-50s %s\n' "Tier A (physical: tiny bytes/dim/missing duration)" "${vid_a_count} assets"
    printf '  %-50s %s\n' "Tier B (WhatsApp voice-note pattern)"               "${vid_b_count} assets"
    printf '  %-50s %s\n' "Unique assets across both tiers"                    "${vid_union_count} assets"
    echo
    echo "Sample (5 smallest, Video Tier A):"
    head -n 5 "${RUN_DIR}/tier-a-video.tsv" \
      | awk -F'\t' '{printf "  %s  %sx%s  %s bytes  %ss  %s\n", $1, $3, $4, $5, $7, $6}'
    echo
    echo "Sample (5 smallest, Video Tier B):"
    head -n 5 "${RUN_DIR}/tier-b-video.tsv" \
      | awk -F'\t' '{printf "  %s  %sx%s  %s bytes  %ss  %s\n", $1, $3, $4, $5, $7, $6}'
    echo
  fi
  echo "Inspect any asset via: ${IMMICH_API_URL}/photos/<uuid>"
} | tee "${SUMMARY_FILE}"
