#!/bin/bash
# Find junk/artifact images in the Immich library. Read-only — no mutations.
#
# Writes a timestamped run directory under immich/scripts/runs/<ts>/ containing:
#   tier-a.tsv    Definite junk (physical: tiny dims, tiny bytes, missing data)
#   tier-b.tsv    Pattern-matched junk (Android UI sprite filenames + tracking pixels)
#   summary.txt   Human-readable counts and sample previews
#
# TSV columns: uuid<TAB>tier<TAB>width<TAB>height<TAB>fileSizeInByte<TAB>originalFileName
#
# Tier A — perfect specificity, physical impossibility of being a real photo:
#   A1  width * height < 10000             (smaller than ~100×100 effective)
#   A2  fileSizeInByte < 5000              (under 5 KB)
#   A3  width/height NULL OR fileSizeInByte NULL/0
#
# Tier B — filename pattern match, narrow Android-UI prefix set:
#   abc_*, ic_*, btn_*, menu_*, tab_*, notification_*, status_*, tooltip_*,
#   design_*, emoji_* (with png/jpg/gif/webp suffix), plus 10 known tracking
#   pixel filenames (indexer.gif, s.gif, spacer.gif, etc.)
#
# Defensive filters applied to BOTH tiers (zero-false-positive bar):
#   type='IMAGE' AND status='active' AND deletedAt IS NULL AND visibility='timeline'
#   AND isFavorite = false AND not present in any album
#
# Usage:
#   bash immich/scripts/immich.find-junk.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=immich.lib.sh
. "${SCRIPT_DIR}/immich.lib.sh"

imapi_require_cmd docker awk

# Verify immich-postgres is up. psql runs inside the container, not on the host.
if [[ "$(docker inspect -f '{{.State.Running}}' immich-postgres 2>/dev/null)" != "true" ]]; then
  echo "error: immich-postgres container is not running" >&2
  exit 1
fi

RUN_TS="$(date -u +'%Y-%m-%d_%H-%M-%SZ')"
RUN_DIR="${SCRIPT_DIR}/runs/${RUN_TS}"
mkdir -p "${RUN_DIR}"

TIER_A_FILE="${RUN_DIR}/tier-a.tsv"
TIER_B_FILE="${RUN_DIR}/tier-b.tsv"
SUMMARY_FILE="${RUN_DIR}/summary.txt"

echo "Running junk detection — output: ${RUN_DIR}"

# Emit two unioned result sets tagged with a tier column; we partition client-side.
# psql flags: -A unaligned, -t tuples-only, -F$'\t' tab separator, no footer.
psql_out="$(docker exec -i immich-postgres \
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
)
SELECT id::text, tier, COALESCE(width::text, ''), COALESCE(height::text, ''),
       COALESCE("fileSizeInByte"::text, ''), "originalFileName"
FROM tier_a
UNION ALL
SELECT id::text, tier, COALESCE(width::text, ''), COALESCE(height::text, ''),
       COALESCE("fileSizeInByte"::text, ''), "originalFileName"
FROM tier_b
ORDER BY 2, 5 NULLS FIRST;  -- tier, then fileSizeInByte
SQL
)"

# Partition rows into tier files. Use awk for speed and to avoid bash subshell
# overhead per row (we may have thousands).
# Pre-create both files so awk doesn't need to handle the "empty tier" case.
: > "${TIER_A_FILE}"
: > "${TIER_B_FILE}"

echo "$psql_out" | awk -F'\t' -v A="${TIER_A_FILE}" -v B="${TIER_B_FILE}" '
  NF >= 6 && $2 == "A" { print >> A }
  NF >= 6 && $2 == "B" { print >> B }
'

a_count="$(wc -l < "${TIER_A_FILE}" | tr -d ' ')"
b_count="$(wc -l < "${TIER_B_FILE}" | tr -d ' ')"
union_count="$(cat "${TIER_A_FILE}" "${TIER_B_FILE}" | awk -F'\t' '!seen[$1]++' | wc -l | tr -d ' ')"

# Build summary.
{
  echo "Immich junk detection — ${RUN_TS}"
  echo "Run dir: ${RUN_DIR}"
  echo
  echo "Filters applied (both tiers):"
  echo "  type=IMAGE, status=active, deletedAt IS NULL, visibility=timeline"
  echo "  isFavorite=false, not in any album"
  echo
  printf '  %-50s %s\n' "Tier A (physical junk: tiny dim/bytes/missing)" "${a_count} assets"
  printf '  %-50s %s\n' "Tier B (Android UI sprite/tracking pixel names)" "${b_count} assets"
  printf '  %-50s %s\n' "Unique assets across both tiers" "${union_count} assets"
  echo
  echo "Sample (5 smallest, Tier A):"
  head -n 5 "${TIER_A_FILE}" | awk -F'\t' '{printf "  %s  %sx%s  %s bytes  %s\n", $1, $3, $4, $5, $6}'
  echo
  echo "Sample (5 smallest, Tier B):"
  head -n 5 "${TIER_B_FILE}" | awk -F'\t' '{printf "  %s  %sx%s  %s bytes  %s\n", $1, $3, $4, $5, $6}'
  echo
  echo "Inspect any asset via: ${IMMICH_API_URL}/photos/<uuid>"
} | tee "${SUMMARY_FILE}"
