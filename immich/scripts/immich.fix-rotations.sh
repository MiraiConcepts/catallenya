#!/bin/bash
# Bake Immich non-destructive rotate edits into their originals, losslessly.
#
# Immich's editor stores a rotate as a DB "Edit Action" and serves a
# RE-ENCODED `_fullsize_edited.jpeg` render on download (`?edited=true`),
# while the original stays landscape. This script turns each such edit into a
# real, lossless rotation of the original by writing the EXIF Orientation flag
# (metadata only — pixel data is byte-identical), then drops the edit + its
# recompressed renders so downloads serve the full-quality, correctly-oriented
# original. See memory `immich-editor-nondestructive-download`.
#
# Method = EXIF orientation (no re-encode, no extra tools). Caveat: a viewer
# that ignores EXIF orientation shows the stored (landscape) pixels. Immich,
# browsers, phones and modern OS viewers honor it. For a universal pixel-bake
# you'd need jpegtran (libjpeg-turbo-progs) — not what this script does.
#
# Per asset (each step guarded; anything unexpected -> SKIP, never guess):
#   1. Require the edit to be pure rotate(s); net angle mod 360 -> orientation
#      (90->6, 180->3, 270->8). Require the original's current Orientation = 1.
#   2. Verify direction by RMSE-matching original-rotated-by-net against the
#      existing `_fullsize_edited.jpeg` render (guards against upside-down).
#   3. Back up the original + capture restore SQL (re-INSERT edit + old cksum).
#   4. exiftool -P -overwrite_original -Orientation#=<n>  (mtime preserved).
#   5. UPDATE asset.checksum to the new sha1 (keeps integrity checks green);
#      DELETE the asset_edit rows (trigger sets isEdited=false); delete the
#      orphaned `*_edited.*` derivatives.
#   6. Re-index: POST /api/assets/jobs refresh-metadata + regenerate-thumbnail.
#      Verify by polling asset_exif.orientation (the REST response lags a few s).
#
# Fully reversible: pixels are never changed, so undo = set Orientation back to
# 1; to restore Immich's edit exactly, replay runs/<ts>/restore/<id>.sql and
# re-index. Backups also live in runs/<ts>/orig/.
#
# Usage:
#   bash immich/scripts/immich.fix-rotations.sh [OPTIONS]
#
# OPTIONS:
#   --dry-run             Show the plan (net angle, orientation, direction
#                         verdict) and touch nothing. Recommended first.
#   --yes                 Skip the confirmation prompt.
#   --asset=<uuid>        Process only this asset id.
#   --limit=N             Process at most N assets (canary).
#   --no-verify-direction Trust the recorded angle; skip the RMSE render match.
#                         Faster, but no upside-down guard. Not recommended.
#   -h, --help            Show this help.
#
# ENV OVERRIDES (defaults suit this host):
#   IMMICH_DATA_DIR   host path bind-mounted to /usr/src/app/upload
#                     (default: /zpool/catallenya/immich/data)
#   IMMICH_PG_CONTAINER / IMMICH_PG_USER / IMMICH_PG_DB
#                     (default: immich-postgres / postgres / immich)
#   plus IMMICH_API_URL / IMMICH_API_KEY[_FILE] from immich.conf.
#
# EXIT CODES:
#   0  all processed assets verified oriented
#   1  some assets failed or failed verification (see runs/<ts>/manifest.csv)
#   2  aborted (auth failure, user declined, bad arguments, deps missing)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=immich.lib.sh
. "${SCRIPT_DIR}/immich.lib.sh"

DRY_RUN=0
YES=0
ASSET_ONLY=""
LIMIT=""
VERIFY_DIRECTION=1

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)             DRY_RUN=1; shift ;;
    --yes)                 YES=1; shift ;;
    --asset=*)             ASSET_ONLY="${1#*=}"; shift ;;
    --limit=*)             LIMIT="${1#*=}"; shift ;;
    --no-verify-direction) VERIFY_DIRECTION=0; shift ;;
    -h|--help)             usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

IMMICH_DATA_DIR="${IMMICH_DATA_DIR:-/zpool/catallenya/immich/data}"
IMMICH_PG_CONTAINER="${IMMICH_PG_CONTAINER:-immich-postgres}"
IMMICH_PG_USER="${IMMICH_PG_USER:-postgres}"
IMMICH_PG_DB="${IMMICH_PG_DB:-immich}"
CONT_UPLOAD_PREFIX="/usr/src/app/upload/"
THUMBS_DIR="${IMMICH_DATA_DIR%/}/thumbs"

# RMSE gate: matched candidate must be this low, and this many x better than
# the 180°-off alternative, or the asset is skipped as ambiguous.
RMSE_MATCH_MAX="${RMSE_MATCH_MAX:-0.05}"
RMSE_MIN_RATIO="${RMSE_MIN_RATIO:-5}"

imapi_require_cmd exiftool convert compare docker python3 sha1sum base64
imapi_load_key

# psql helpers (query -> stdout; command; matches repo convention).
pg()  { docker exec -i "${IMMICH_PG_CONTAINER}" psql -U "${IMMICH_PG_USER}" -d "${IMMICH_PG_DB}" -Atc "$1"; }
pgc() { docker exec -i "${IMMICH_PG_CONTAINER}" psql -U "${IMMICH_PG_USER}" -d "${IMMICH_PG_DB}" -q -c "$1" >/dev/null; }

docker exec "${IMMICH_PG_CONTAINER}" true 2>/dev/null || {
  echo "error: cannot reach postgres container '${IMMICH_PG_CONTAINER}'" >&2; exit 2; }

RUN_TS="$(date -u +'%Y-%m-%d_%H-%M-%SZ')"
RUN_DIR="${SCRIPT_DIR}/runs/${RUN_TS}_fix-rotations"
mkdir -p "${RUN_DIR}/orig" "${RUN_DIR}/restore"
MANIFEST="${RUN_DIR}/manifest.csv"
echo "id,filename,net_angle,orientation,old_checksum_b64,new_checksum_hex,status" > "${MANIFEST}"

echo "immich.fix-rotations — $( [[ ${DRY_RUN} -eq 1 ]] && echo DRY-RUN || echo APPLY )"
echo "  Run dir: ${RUN_DIR}"
echo "  Data dir: ${IMMICH_DATA_DIR}   Verify direction: $([[ ${VERIFY_DIRECTION} -eq 1 ]] && echo on || echo off)"

# --- Build worklist: distinct assets that currently have an asset_edit row ---
if [[ -n "${ASSET_ONLY}" ]]; then
  WHERE="WHERE \"assetId\" = '${ASSET_ONLY}'"
else
  WHERE=""
fi
mapfile -t TODO < <(pg "SELECT DISTINCT \"assetId\" FROM asset_edit ${WHERE} ORDER BY 1;")
echo "  Edited assets found: ${#TODO[@]}"
[[ ${#TODO[@]} -eq 0 ]] && { echo "Nothing to do."; exit 0; }

# --- RMSE of two images after identical normalization (lower = more similar) ---
rmse() { compare -metric RMSE "$1" "$2" null: 2>&1 | sed -n 's/.*(\([0-9.]*\)).*/\1/p'; }

# --- Decide orientation + verify direction. Echoes "ORI NET VERDICT". ---
plan_asset() {
  local id="$1" orig="$2"
  # collect edit actions; require all rotate
  local rows n_nonrotate net
  rows="$(pg "SELECT action||' '||COALESCE(parameters->>'angle','') FROM asset_edit WHERE \"assetId\"='${id}' ORDER BY sequence;")"
  n_nonrotate="$(printf '%s\n' "${rows}" | grep -vc '^rotate ' || true)"
  [[ "${n_nonrotate}" -ne 0 ]] && { echo "- - SKIP_NON_ROTATE"; return; }
  net="$(printf '%s\n' "${rows}" | awk '{s+=$2} END{print ((s%360)+360)%360}')"
  local ori
  case "${net}" in
    90)  ori=6 ;;
    180) ori=3 ;;
    270) ori=8 ;;
    0)   echo "0 ${net} SKIP_NET_ZERO"; return ;;
    *)   echo "- ${net} SKIP_ODD_ANGLE"; return ;;
  esac
  # require the original to currently be un-oriented (Orientation 1/absent)
  local cur; cur="$(exiftool -s3 -n -Orientation "${orig}" 2>/dev/null)"
  [[ -z "${cur}" || "${cur}" == "1" ]] || { echo "${ori} ${net} SKIP_ORIG_ORIENTED(${cur})"; return; }
  if [[ ${VERIFY_DIRECTION} -eq 1 ]]; then
    local render; render="$(find "${THUMBS_DIR}" -name "${id}_fullsize_edited.jpeg" 2>/dev/null | head -1)"
    [[ -n "${render}" ]] || { echo "${ori} ${net} SKIP_NO_RENDER"; return; }
    local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' RETURN
    convert "${render}" -auto-orient -colorspace Gray -resize 128x128! "${tmp}/r.png" 2>/dev/null
    convert "${orig}" -auto-orient -rotate "${net}"        -colorspace Gray -resize 128x128! "${tmp}/m.png" 2>/dev/null
    convert "${orig}" -auto-orient -rotate "$(((net+180)%360))" -colorspace Gray -resize 128x128! "${tmp}/a.png" 2>/dev/null
    local rm ra; rm="$(rmse "${tmp}/m.png" "${tmp}/r.png")"; ra="$(rmse "${tmp}/a.png" "${tmp}/r.png")"
    local ok; ok="$(python3 -c "m=float('${rm}');a=float('${ra}');print(1 if (m<${RMSE_MATCH_MAX} and a> m*${RMSE_MIN_RATIO}) else 0)")"
    [[ "${ok}" == "1" ]] || { echo "${ori} ${net} SKIP_AMBIGUOUS(m=${rm},alt=${ra})"; return; }
  fi
  echo "${ori} ${net} OK"
}

# ---------------------------- main loop ----------------------------
declare -a DONE_IDS=()
processed=0; done=0; skipped=0
for id in "${TODO[@]}"; do
  [[ -n "${LIMIT}" && ${processed} -ge ${LIMIT} ]] && break
  processed=$((processed+1))
  cpath="$(pg "SELECT \"originalPath\" FROM asset WHERE id='${id}';")"
  orig="${cpath/${CONT_UPLOAD_PREFIX}/${IMMICH_DATA_DIR%/}/}"
  fn="$(basename "${orig}")"
  if [[ ! -f "${orig}" ]]; then
    printf "  SKIP %-20s original missing\n" "${fn}"
    echo "${id},${fn},,,,,SKIP_MISSING" >> "${MANIFEST}"; skipped=$((skipped+1)); continue
  fi
  read -r ori net verdict <<<"$(plan_asset "${id}" "${orig}")"
  if [[ "${verdict}" != "OK" ]]; then
    printf "  SKIP %-20s net=%s ori=%s %s\n" "${fn}" "${net}" "${ori}" "${verdict}"
    echo "${id},${fn},${net},${ori},,,${verdict}" >> "${MANIFEST}"; skipped=$((skipped+1)); continue
  fi
  if [[ ${DRY_RUN} -eq 1 ]]; then
    printf "  PLAN %-20s net=%3s -> Orientation %s\n" "${fn}" "${net}" "${ori}"
    echo "${id},${fn},${net},${ori},,,PLAN" >> "${MANIFEST}"; done=$((done+1)); continue
  fi
  # ---- apply ----
  cp -a "${orig}" "${RUN_DIR}/orig/${id}.jpg"
  old_b64="$(sha1sum "${orig}" | awk '{print $1}' | xxd -r -p | base64)"
  old_hex="$(sha1sum "${orig}" | awk '{print $1}')"
  pg "SELECT 'INSERT INTO asset_edit(id,\"assetId\",action,parameters,sequence,\"updatedAt\") VALUES ('''||id||''','''||\"assetId\"||''','''||action||''','''||parameters||'''::jsonb,'||sequence||','''||\"updatedAt\"||''');' FROM asset_edit WHERE \"assetId\"='${id}';" > "${RUN_DIR}/restore/${id}.sql"
  echo "UPDATE asset SET checksum=decode('${old_hex}','hex') WHERE id='${id}';" >> "${RUN_DIR}/restore/${id}.sql"
  if ! exiftool -P -overwrite_original -Orientation#="${ori}" "${orig}" >/dev/null 2>&1; then
    printf "  FAIL %-20s exiftool failed\n" "${fn}"
    echo "${id},${fn},${net},${ori},${old_b64},,EXIFTOOL_FAIL" >> "${MANIFEST}"; skipped=$((skipped+1)); continue
  fi
  new_hex="$(sha1sum "${orig}" | awk '{print $1}')"
  pgc "UPDATE asset SET checksum=decode('${new_hex}','hex') WHERE id='${id}';"
  pgc "DELETE FROM asset_edit WHERE \"assetId\"='${id}';"
  find "${THUMBS_DIR}" -name "${id}_"'*_edited.*' -delete 2>/dev/null || true
  echo "${id},${fn},${net},${ori},${old_b64},${new_hex},DONE" >> "${MANIFEST}"
  DONE_IDS+=("${id}")
  printf "  DONE %-20s net=%3s -> Orientation %s\n" "${fn}" "${net}" "${ori}"
  done=$((done+1))
done

echo
echo "Planned/updated: ${done}   Skipped: ${skipped}   (manifest: ${MANIFEST})"

if [[ ${DRY_RUN} -eq 1 ]]; then
  echo "Dry-run only — nothing changed. Re-run without --dry-run to apply."
  exit 0
fi
[[ ${#DONE_IDS[@]} -eq 0 ]] && { echo "No assets modified."; exit 0; }

if [[ ${YES} -ne 1 ]]; then
  read -r -p "Re-index ${#DONE_IDS[@]} asset(s) now (refresh-metadata + regenerate-thumbnail)? [y/N] " ans
  [[ "${ans}" =~ ^[Yy] ]] || { echo "Left DB/files updated but NOT re-indexed. Trigger jobs later to refresh Immich."; exit 1; }
fi

# ---- re-index (bulk) ----
IDS_JSON="$(printf '%s\n' "${DONE_IDS[@]}" | python3 -c 'import sys,json;print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
for job in refresh-metadata regenerate-thumbnail; do
  imapi POST /api/assets/jobs -H "Content-Type: application/json" \
    -d "{\"assetIds\":${IDS_JSON},\"name\":\"${job}\"}" >/dev/null && echo "  queued ${job} (${#DONE_IDS[@]})"
done

# ---- verify: poll asset_exif.orientation until all match, or timeout ----
echo "Verifying orientation in asset_exif..."
fail=0
for _ in $(seq 1 40); do
  bad=0
  for id in "${DONE_IDS[@]}"; do
    want="$(awk -F, -v i="${id}" '$1==i{print $4}' "${MANIFEST}")"
    got="$(pg "SELECT orientation FROM asset_exif WHERE \"assetId\"='${id}';")"
    [[ "${got}" == "${want}" ]] || bad=$((bad+1))
  done
  [[ ${bad} -eq 0 ]] && { echo "  all ${#DONE_IDS[@]} oriented ✓"; fail=0; break; }
  fail=${bad}
  sleep 2
done
[[ ${fail} -ne 0 ]] && { echo "  WARNING: ${fail} asset(s) not yet oriented — re-check later"; exit 1; }
echo "Done."
exit 0
