# Immich library tooling

Scripts for two pipelines against the Immich library:

1. **Cleanup**: find → verify → delete junk/artifact assets (images + videos)
2. **Date recovery**: scan → verify → apply authoritative capture timestamps to assets whose `fileCreatedAt` was bulk-defaulted during a bad import

Both pipelines share the `immich.lib.sh` substrate (`imapi`, `imapi_load_key`, `imapi_require_cmd`) and the per-run `runs/<ts>/` directory convention.

## Files

| File | Purpose |
|---|---|
| `immich.conf` | Base URL + API key file path (sourced by lib). |
| `immich.lib.sh` | Shared helpers: `imapi <METHOD> <path>`, `imapi_load_key`, `imapi_require_cmd`. |
| `immich.validate.sh` | Read-only connectivity + auth + stats sanity check. Run first to verify API access. |
| `immich.find-junk.sh` | Reads Postgres directly, writes a timestamped run dir under `runs/<ts>/` with `tier-{a,b}-{image,video}.tsv` + `summary.txt`. Read-only. `--type=image\|video\|all` (default `all`). `--enable-monochrome` adds `tier-c-image.tsv` (low-bytes-per-pixel prefilter for single-color candidates). |
| `immich.verify-junk.sh` | Reads tier files, ffmpeg-remuxes / decodes each candidate, classifies into `verified-junk-*.tsv` (safe to delete) or `rescued-*.tsv` (do NOT delete, review). Read-only. **Mandatory before delete.** Also supports `--audit-run=<ts>` mode for retroactive checks on already-deleted assets. |
| `immich.delete.sh` | Consumes `verified-junk-*.tsv` from a run dir. Batches `DELETE /api/assets`. Soft-delete default (Trash, 30-day retention). `--skip-verify` to bypass (with warning + prompt). |
| `immich.restore.sh` | Inverse of soft-delete. Accepts UUIDs via `--from-file` (TSV or one-per-line, `-` for stdin), batches `POST /api/trash/restore/assets`. |
| `immich.fix-dates.scan.sh` | Date-recovery stage 1. Reads Postgres + per-asset external sources (exiftool / filename regex / ffprobe / mtime), writes `proposed-{image,video}.tsv` + `scan-summary.txt`. Read-only. Strict priority resolution. |
| `immich.fix-dates.verify.sh` | Date-recovery stage 2. Re-reads the declared source per row and sanity-checks; routes to `verified-fixes-*.tsv` (safe to apply) or `rescued-fixes-*.tsv` (review). Read-only. **Mandatory before apply.** |
| `immich.fix-dates.apply.sh` | Date-recovery stage 3. Consumes `verified-fixes-*.tsv`. Per-asset `PUT /api/assets/<id>` with `dateTimeOriginal`. Pauses `metadataExtraction` job in a trap-protected window to avoid the race. `--dry-run` previews. |
| `.immich_api_key` | API key file (chmod 600, gitignored). Override with `IMMICH_API_KEY` env var. |
| `runs/` | Per-invocation working dirs (gitignored). |

**Host dependencies:** `curl`, `jq`, `docker`, `awk`, `sort`, `stat`, `date`, **`identify`** (ImageMagick — used by verify-junk on Tier A images and required for Tier C monochrome verification). Date-recovery additionally needs **`exiftool`** (`sudo apt install -y libimage-exiftool-perl`). Tier C monochrome verification also uses ImageMagick's **`convert`** (same package as `identify`). `ffprobe`/`ffmpeg` are read from the `immich-server` container as needed.

Run `bash immich.<script>.sh --help` for full flag listings.

## Pipeline: find → verify → delete

```
find-junk        →   verify-junk          →   delete
(heuristics)         (physical playability)    (acts on verified-junk only)
                                               --skip-verify to bypass
```

The split is the core safety design:
- **find-junk** uses metadata heuristics (size, dim, duration, filename) to nominate candidates. Fast but can produce false positives (e.g., real videos with incomplete metadata).
- **verify-junk** is the **physical truth oracle.** It tries to remux every candidate video and decode every candidate image. Truncated downloads, corrupt files, and audio-only containers fail. Real content passes.
- **delete** only consumes `verified-junk-*.tsv` — the rows verify proved are broken. Anything verify rescued is excluded by construction.

This means a future heuristic regression in find-junk can't silently delete real content. Verify is the structural backstop.

## Tier taxonomy (find-junk)

### Image tiers
- **Tier A — physical-impossibility.** `area < 10000 px` OR `fileSizeInByte < 5000` OR missing dim/size.
- **Tier B — pattern match.** Filenames matching narrow Android UI sprite prefixes (`abc_`, `ic_`, `btn_`, etc.) + 10 known tracking-pixel names.
- **Tier C — monochrome candidates (opt-in via `--enable-monochrome`).** SQL prefilter only: `width≥200 AND height≥200 AND bytes/(w×h) < --monochrome-bpp-max` (default `0.01`). The precise per-pixel stddev classification happens in verify-junk (see below); find-junk just nominates the bucket.

### Video tiers
- **Tier A — physical-impossibility.** Catches: `fileSizeInByte < 50 KB` OR `area < 10000 px` OR `(missing dim AND < 5 MB)` OR `(missing duration AND < 5 MB)`.
- **Tier B — pattern match.** WhatsApp voice-note convention: `^(AUD|PTT)-.*\.3gp$`. These are audio messages Immich classifies as VIDEO because `.3gp` is a video container format.

Defensive filters baked into all queries: `status=active`, `deletedAt IS NULL`, `visibility=timeline`, `isFavorite=false`, not in any album.

The `< 5 MB` size guard on A3/A4 spares real GB-scale videos with incomplete metadata while still catching audio-only `.3gp` files and broken micro-clips. Verify-junk is the further safety net.

## Verdict taxonomy (verify-junk)

Each candidate is classified into one of:

| Verdict | Test | Routed to |
|---|---|---|
| `TINY` | bytes < 5 KB (video) — fast-path, no ffmpeg | verified-junk |
| `MISSING` | file does not exist on disk | verified-junk |
| `AUDIO_ONLY` | filename matches B1 OR no video stream | verified-junk |
| `BROKEN` | video remux ratio < 30%, OR image fails decode | verified-junk |
| `TRIVIAL` | plays cleanly BUT bytes < 1 MB AND not a camera-prefix name (Telegram stickers, WhatsApp thumbnails); also: Tier B images (filename trusted); also: Tier C images whose max-channel stddev (over a white composite) is below `--monochrome-stddev` (default `0.1`) — confirmed monochrome | verified-junk |
| `PARTIAL` | video remux ratio 30–79% | rescued (review) |
| `GOOD` | video remux ≥ 80% AND (bytes ≥ 1 MB OR camera-prefix name); OR image passes both ffmpeg + ImageMagick; OR Tier C image whose stddev exceeds the threshold (e.g. transparent-bg PNG whose real content was hidden in the alpha) | rescued (do not delete) |
| `VERIFY_ERROR` | ffmpeg/identify/convert crashed, timed out, or returned non-numeric output | rescued (default safe — covers e.g. giant PNGs that exhaust ImageMagick's pixel cache) |

Camera-prefix regex: `^(PXL_|IMG_|VID_|DSC_|MOV_|MVI_)` — underscore distinguishes real camera names from messaging-app conventions (`VID-*-WA*.mp4` is WhatsApp, not a camera capture).

## Typical workflow

```bash
# 1. Verify API access (one-time / when troubleshooting)
bash immich.validate.sh

# 2. Detect junk — creates runs/<ts>/. Default scans both images and videos.
bash immich.find-junk.sh
bash immich.find-junk.sh --type=video     # videos only
bash immich.find-junk.sh --enable-monochrome   # adds Tier C image candidates

# 3. Verify — physical playability + monochrome stddev check. Mandatory before delete.
bash immich.verify-junk.sh
bash immich.verify-junk.sh --monochrome-stddev=0.05  # stricter Tier C threshold

# 4. Review rescued items (these would have been deleted without verify)
cat runs/<ts>/rescued-*.tsv

# 5. Preview deletion
bash immich.delete.sh --dry-run

# 6. Delete (soft, to trash). Auto-picks the latest run dir.
bash immich.delete.sh                            # interactive confirmation
bash immich.delete.sh --yes                      # skip prompt
bash immich.delete.sh --asset-type=video --yes   # only videos from the run
```

Soft-deleted assets sit in your Immich Trash for 30 days, reviewable + restorable via the UI. Immich auto-purges on day 31 (file + thumbnails + ML data, cascade handled server-side).

## Retroactive audit

Want to check whether a past delete cycle wrongly trashed any real content?

```bash
bash immich.verify-junk.sh --audit-run=<ts>
cat runs/<ts>/audit-report.tsv  # full per-asset verdicts
awk -F'\t' '$8=="GOOD"' runs/<ts>/audit-report.tsv  # candidates worth restoring
```

Audit mode reads `deleted.tsv` from a past run, looks up paths from the DB, and runs the same verify logic. Items already restored (no `deletedAt`) are excluded automatically.

## Restoring from trash

```bash
# Restore specific UUIDs
echo "<uuid>" | bash immich.restore.sh --from-file=-

# Restore from an audit-report.tsv (col 1 = UUID)
awk -F'\t' '$8=="GOOD" {print $1}' runs/<ts>/audit-report.tsv \
  | bash immich.restore.sh --from-file=- --yes
```

## Reading audit logs

Each run dir's `deleted.tsv` is the delete-side audit trail:
```
<uuid>\t<http_status>\t<iso_timestamp>
```
- `204` = success (soft-deleted to trash)
- `404` = asset already gone (manually deleted, or prior trash purge)
- anything else = failure (inspect the response; script continues past per-asset errors but aborts on `401`).

The presence of `deleted.tsv` in a run dir marks it processed; `delete.sh` skips it on auto-pick. Pass `--force-rerun` to re-process; the script subtracts IDs already in `deleted.tsv` so no double-deletes.

`restored.tsv` (written by restore.sh) follows the same shape.

## Pipeline: scan → verify → apply (dates)

```
fix-dates.scan      →   fix-dates.verify         →   fix-dates.apply
(external sources)      (sanity + stability)         (PUT /api/assets/<id>)
                                                     --skip-verify to bypass
```

Motivation: bulk-imported assets sometimes land in Immich with `fileCreatedAt` defaulted to the import date (e.g., a 22,925-image cluster on `2023-02-19` SGT) when EXIF was unavailable or skipped during ingest. This pipeline reconstructs capture timestamps from external sources of truth and patches Immich.

### Sources of truth (strict priority order)

| # | Source | Tool | Notes |
|---|---|---|---|
| 1 | EXIF `DateTimeOriginal` | `exiftool` | Cameras, JPEG/HEIC. Most authoritative when an `OffsetTimeOriginal` is present; naked EXIF (no offset, common on older cameras) is stamped as SGT per library convention. |
| 2 | Filename-embedded date | regex | WhatsApp (`IMG-YYYYMMDD-WA####`), Android (`IMG_/VID_/PXL_/PANO_YYYYMMDD_HHMMSS`), iOS-ish (`IMGYYYYMMDDHHMMSS`), screenshots (`Screenshot_YYYYMMDD-HHMMSS`, `Screenshot YYYY-MM-DD at HH.MM.SS`), Signal (`signal-YYYY-MM-DD-…`), bare `YYYYMMDD_HHMMSS` / `YYYYMMDD-HHMMSS_N`, dated-with-dots `YYYY-MM-DD HH.MM.SS[-_ .(]N`, Android stock video (`video-YYYY-MM-DD-HH-MM-SS.mp4`), Facebook downloads (`<digits>_<13-digit ms epoch>_…`), Unix-ms screenshot saves (`screenshot-{13digits}_N.png`), date-only `YYYY-MM-DD (N).ext` / `YYYY-MM-DD.ext`. |
| 3 | Video container `creation_time` | `ffprobe` | Video only. Can be wrong on re-encoded clips. |
| 4 | File mtime | `stat` | Opt-in only (`--allow-mtime`). Weakest signal. |

First non-empty source that passes the sanity range (`--min-date` ≤ d ≤ `--max-date`) wins. SGT (UTC+8) is the assumed library timezone — see `[[immich-photos-sgt-timezone]]` memory.

### Verdicts (verify)

| Verdict | Test | Routed to |
|---|---|---|
| `OK` | All checks pass; source re-read produced same value | `verified-fixes-*.tsv` |
| `MISSING` | File no longer exists on disk | rescued |
| `OUT_OF_RANGE` | Proposed date outside `[min-date, max-date]` | rescued |
| `NO_CHANGE` | Proposed equals current (defensive; scan should have skipped) | rescued |
| `CONFLICT` | Scan flagged cross-source disagreement (EXIF + filename differ > 24h) | rescued |
| `UNSTABLE` | Source re-read produced a different (or empty) date | rescued |

### Apply safety

`apply.sh` pauses Immich's `metadataExtraction` job before issuing PUTs and resumes it in an `EXIT` trap. Without this, a queued extraction can land after the PUT and overwrite the new date (immich-app/immich#16901).

A successful `PUT /api/assets/{id}` with `dateTimeOriginal` triggers a `SIDECAR_WRITE` job that persists the new date to an XMP sidecar next to the asset. Subsequent metadata extractions read the sidecar (XMP > embedded EXIF), so writes are authoritative across rescans.

### Typical workflow

```bash
# 1. One-time: install exiftool (the only host dependency added)
sudo apt install -y libimage-exiftool-perl

# 2. Canary: target the known 22.9k-image 2023-02-19 cluster, images only, EXIF only
bash immich.fix-dates.scan.sh --date-cluster=2023-02-19 --source=exif --type=image --limit=100

# 3. Verify (auto-picks the latest run dir)
bash immich.fix-dates.verify.sh

# 4. Review what would change
bash immich.fix-dates.apply.sh --dry-run

# 5. Apply the canary
bash immich.fix-dates.apply.sh --limit=100

# 6. Spot-check in the Immich UI; sidecar write is async, may lag a few minutes.

# 7. Broaden: drop --limit, then drop --source, then drop --date-cluster
bash immich.fix-dates.scan.sh --date-cluster=2023-02-19
bash immich.fix-dates.verify.sh
bash immich.fix-dates.apply.sh --yes
```

### Reading the apply log

`applied.tsv` has six columns:
```
<uuid>\t<old_date>\t<new_date>\t<source>\t<http_code>\t<iso_timestamp>
```
- `200`/`204` = success
- `400`/`404` = asset gone or malformed payload
- anything else = failure (script continues; aborts on `401`)

`--dry-run` prints preview rows to stdout only and does NOT touch `applied.tsv` — keeping the log free of fake entries that would otherwise confuse resume logic on later real runs.

The old/new dates are retained on every row so a future revert is implementable from this log alone.

### Recovering from a stuck pause

If `apply.sh` is killed in a way that bypasses the EXIT trap (rare — `kill -9`, OOM), `metadataExtraction` may stay paused. Resume manually:
```bash
curl -X PUT "${IMMICH_API_URL}/api/jobs/metadataExtraction" \
     -H "x-api-key: $(cat .immich_api_key)" \
     -H "Content-Type: application/json" \
     --data '{"command":"resume"}'
```

## What's deferred

- Duplicate cleanup — Immich's `UQ_asset_owner_checksum` unique constraint blocks byte-identical dupes at upload; a scan of this library (2026-05-18, 168,541 live assets) found 0 SHA collisions. For fuzzy near-duplicates use Immich's CLIP-based "Review Duplicates" UI.
- Combined scan+verify+delete script — the explicit split is intentional. The review gap between verify and delete is the human-in-the-loop layer.
- Video Tier C (implied-bitrate floor, `bytes/duration < 200 kbps`) — replaced in spirit by verify's remux-ratio test (which catches the same class of broken clips with higher precision).
- `immich.fix-dates.revert.sh` — `applied.tsv` retains both old and new dates so a revert is implementable when needed.

See `.claude/plans/immich-find-junk-plan.md`, `.claude/plans/immich-delete-plan.md`, `.claude/plans/immich-find-junk-videos-plan.md`, `.claude/plans/immich-verify-pipeline-plan.md`, and `.claude/plans/immich-fix-dates-plan.md` for the full design rationale.
