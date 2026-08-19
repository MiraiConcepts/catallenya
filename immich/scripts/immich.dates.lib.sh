#!/bin/bash
# Shared date-derivation helpers for immich.fix-dates.{scan,verify}.sh.
# Source this (after immich.lib.sh); do not execute.
#
# These functions existed as two hand-synced copies — scan's inline block and
# verify's "mirror scan; kept inline so verify is self-contained" block — that
# were proven functionally identical (normalized diff empty) before the merge.
# One copy means the parsers cannot drift apart again: verify re-reads the very
# source scan derived from, so a divergence here would make verify reject rows
# as UNSTABLE for no real reason (or, worse, confirm a date scan never derived).
#
# Callers must set — and `export`, because both consumers run these inside
# `xargs -P` workers via `bash -c` + `export -f`:
#   SGT_OFFSET            offset rendered onto naked / library-convention dates
#   MIN_DATE / MAX_DATE   YYYY-MM-DD bounds read by in_range
#
# Provides (readers print the ISO date to stdout; empty output = no result):
#   parse_filename_date <fname>   filename-embedded date -> ISO-8601 SGT
#   read_exif_date <hpath>        EXIF DateTimeOriginal (+offset) via exiftool
#   read_container_date <cpath>   video creation_time via ffprobe (immich-server)
#   read_mtime_date <hpath>       file mtime, rendered SGT
#   in_range <iso>                true if MIN_DATE <= iso <= MAX_DATE
#   same_second <a> <b>           true if the two ISO timestamps match to the second

# Parse a filename and return an ISO-8601 SGT date string, or empty if no
# pattern matched. Time component defaults to 12:00:00 SGT for date-only matches.
parse_filename_date() {
  local fname=$1
  local y mo d h mi s
  h=12; mi=0; s=0

  # ── Date+time patterns (most specific first) ─────────────────────────
  # Android camera: IMG_/VID_/PXL_/PANO_YYYYMMDD_HHMMSS(_optional).{jpg,mp4,…}
  if [[ "$fname" =~ ^(IMG|VID|PXL|PANO)_([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2}) ]]; then
    y="${BASH_REMATCH[2]}"; mo="${BASH_REMATCH[3]}"; d="${BASH_REMATCH[4]}"
    h="${BASH_REMATCH[5]}"; mi="${BASH_REMATCH[6]}"; s="${BASH_REMATCH[7]}"
  # Android stock video: video-YYYY-MM-DD-HH-MM-SS.mp4
  elif [[ "$fname" =~ ^video-([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{2})-([0-9]{2})-([0-9]{2})\. ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    h="${BASH_REMATCH[4]}"; mi="${BASH_REMATCH[5]}"; s="${BASH_REMATCH[6]}"
  # Facebook download: <digits>_<13-digit ms epoch>_... — extracts the 2nd numeric block
  elif [[ "$fname" =~ ^[0-9]+_([0-9]{13})_ ]]; then
    local _ms _sec _parts
    _ms="${BASH_REMATCH[1]}"
    _sec=$((_ms / 1000))
    if (( _sec < 1000000000 || _sec > 4102444800 )); then return 0; fi
    _parts=$(TZ=Asia/Singapore date -d "@${_sec}" +'%Y %m %d %H %M %S' 2>/dev/null) || return 0
    read -r y mo d h mi s <<<"$_parts"
  # iOS-ish: IMG20240510143200.heic
  elif [[ "$fname" =~ ^IMG([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})\. ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    h="${BASH_REMATCH[4]}"; mi="${BASH_REMATCH[5]}"; s="${BASH_REMATCH[6]}"
  # Android screenshot dashed: Screenshot_20240510-143200_App.png
  elif [[ "$fname" =~ ^Screenshot_([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2}) ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    h="${BASH_REMATCH[4]}"; mi="${BASH_REMATCH[5]}"; s="${BASH_REMATCH[6]}"
  # Screenshot 2024-05-10 at 14.32.00 (macOS) or Screenshot_2024-05-10-14-32-00
  elif [[ "$fname" =~ ^Screenshot[\ _]([0-9]{4})-([0-9]{2})-([0-9]{2})[\ _-](at[\ _])?([0-9]{2})[.-]([0-9]{2})[.-]([0-9]{2}) ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    h="${BASH_REMATCH[5]}"; mi="${BASH_REMATCH[6]}"; s="${BASH_REMATCH[7]}"
  # Signal: signal-2024-05-10-14-32-00-001.jpg
  elif [[ "$fname" =~ ^signal-([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{2})-([0-9]{2})-([0-9]{2}) ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    h="${BASH_REMATCH[4]}"; mi="${BASH_REMATCH[5]}"; s="${BASH_REMATCH[6]}"
  # 2024-05-10 14.32.00[-_ .(]…  — Android camera variants + dedup suffix
  # `[-_ .(]` after seconds tolerates: 14.32.00.jpg / 14.32.00-3.jpg /
  # 14.32.00_1.jpg / "14.32.00 (1).jpg"
  elif [[ "$fname" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})\ ([0-9]{2})\.([0-9]{2})\.([0-9]{2})[-_\ .\(] ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    h="${BASH_REMATCH[4]}"; mi="${BASH_REMATCH[5]}"; s="${BASH_REMATCH[6]}"
  # Bare YYYYMMDD_HHMMSS[_.] — accept e.g. 20240510_143200.jpg or _1.jpg variants
  elif [[ "$fname" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})[_.] ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    h="${BASH_REMATCH[4]}"; mi="${BASH_REMATCH[5]}"; s="${BASH_REMATCH[6]}"
  # YYYYMMDD-HHMMSS[_.] — alt camera/screenshot variant
  elif [[ "$fname" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2})[_.] ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    h="${BASH_REMATCH[4]}"; mi="${BASH_REMATCH[5]}"; s="${BASH_REMATCH[6]}"
  # screenshot-{13-digit ms epoch}[_.] — Reddit/Android web saves
  elif [[ "$fname" =~ ^[Ss]creenshot-([0-9]{13})[_.] ]]; then
    local _ms _sec _parts
    _ms="${BASH_REMATCH[1]}"
    _sec=$((_ms / 1000))
    # plausibility band: 2001-09-09 .. 2100-01-01
    if (( _sec < 1000000000 || _sec > 4102444800 )); then return 0; fi
    _parts=$(TZ=Asia/Singapore date -d "@${_sec}" +'%Y %m %d %H %M %S' 2>/dev/null) || return 0
    read -r y mo d h mi s <<<"$_parts"
  # ── Date-only patterns (default time 12:00:00 SGT) ────────────────────
  # WhatsApp image: IMG-20240510-WA0001.jpg
  elif [[ "$fname" =~ ^IMG-([0-9]{4})([0-9]{2})([0-9]{2})-WA[0-9]+\. ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
  # WhatsApp video: VID-20240510-WA0001.mp4
  elif [[ "$fname" =~ ^VID-([0-9]{4})([0-9]{2})([0-9]{2})-WA[0-9]+\. ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
  # YYYY-MM-DD (N).ext — date-only with paren dedup suffix
  elif [[ "$fname" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})\ *[\(][0-9]+[\)]\. ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
  # YYYY-MM-DD.ext — bare date (rare; covers any date-only files)
  elif [[ "$fname" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})\. ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
  else
    return 0
  fi

  # Validate calendar date (catches Feb 30 etc.). `date -d` accepts the
  # rendered form and returns non-zero on impossible dates.
  if ! date -d "${y}-${mo}-${d} ${h}:${mi}:${s}" >/dev/null 2>&1; then
    return 0
  fi

  # Force base-10 on h/mi/s: bash treats leading-0 strings (e.g., "08","09")
  # as invalid octal under %02d, silently outputting 0.
  printf '%s-%s-%sT%02d:%02d:%02d%s' "$y" "$mo" "$d" \
    $((10#$h)) $((10#$mi)) $((10#$s)) "$SGT_OFFSET"
}

# EXIF DateTimeOriginal (+ OffsetTimeOriginal if present) -> ISO, or empty.
# CRITICAL: do NOT use `-d "...%z"` on the date — exiftool fills `%z` with
# the HOST's timezone for naked-EXIF dates, which is wrong (we'd inject PDT
# into an SGT library). Pull date + offset separately.
read_exif_date() {
  local hpath=$1
  command -v exiftool >/dev/null 2>&1 || return 0
  [[ -e "$hpath" ]] || return 0
  local raw naked_dt off_dt ln
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
      # EXIF without offset — apply library convention (SGT).
      printf '%s%s' "$naked_dt" "$SGT_OFFSET"
    fi
  fi
}

# Video container creation_time via ffprobe inside immich-server -> ISO, or empty.
# ffprobe returns e.g. "2024-05-10T13:42:00.000000Z" — normalize to seconds +
# explicit offset. Container time is always UTC ('Z'); render as +00:00 so
# comparison stays explicit.
read_container_date() {
  local cpath=$1 raw
  raw=$(timeout 15 docker exec immich-server ffprobe -v error \
          -show_entries format_tags=creation_time -of csv=p=0 "$cpath" 2>/dev/null || true)
  if [[ -n "$raw" && "$raw" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
    printf '%sT%s+00:00' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  fi
}

# File mtime -> ISO, or empty. Rendered in SGT for consistency with the
# library's capture intent.
read_mtime_date() {
  local hpath=$1 epoch
  [[ -e "$hpath" ]] || return 0
  epoch=$(stat -c '%Y' "$hpath" 2>/dev/null || true)
  [[ -n "$epoch" ]] || return 0
  TZ=Asia/Singapore date -d "@$epoch" +'%Y-%m-%dT%H:%M:%S+08:00' 2>/dev/null || true
}

# Sanity range check: MIN_DATE <= iso_date <= MAX_DATE (both inclusive).
# Compares as epoch seconds for unambiguous TZ handling.
in_range() {
  local iso=$1 epoch min_epoch max_epoch
  epoch=$(date -d "$iso" +%s 2>/dev/null) || return 1
  min_epoch=$(date -d "${MIN_DATE}T00:00:00+00:00" +%s)
  max_epoch=$(date -d "${MAX_DATE}T23:59:59+00:00" +%s)
  (( epoch >= min_epoch && epoch <= max_epoch ))
}

# Compare two ISO timestamps; true if same to the second.
same_second() {
  local ea eb
  ea=$(date -d "$1" +%s 2>/dev/null) || return 1
  eb=$(date -d "$2" +%s 2>/dev/null) || return 1
  (( ea == eb ))
}
