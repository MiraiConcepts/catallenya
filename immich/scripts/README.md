# Immich cleanup pipeline

Scripts for finding, verifying, and deleting junk/artifact assets (images + videos) from the Immich library.

## Files

| File | Purpose |
|---|---|
| `immich.conf` | Base URL + API key file path (sourced by lib). |
| `immich.lib.sh` | Shared helpers: `imapi <METHOD> <path>`, `imapi_load_key`, `imapi_require_cmd`. |
| `immich.validate.sh` | Read-only connectivity + auth + stats sanity check. Run first to verify API access. |
| `immich.find-junk.sh` | Reads Postgres directly, writes a timestamped run dir under `runs/<ts>/` with `tier-{a,b}-{image,video}.tsv` + `summary.txt`. Read-only. `--type=image\|video\|all` (default `all`). |
| `immich.verify-junk.sh` | Reads tier files, ffmpeg-remuxes / decodes each candidate, classifies into `verified-junk-*.tsv` (safe to delete) or `rescued-*.tsv` (do NOT delete, review). Read-only. **Mandatory before delete.** Also supports `--audit-run=<ts>` mode for retroactive checks on already-deleted assets. |
| `immich.delete.sh` | Consumes `verified-junk-*.tsv` from a run dir. Batches `DELETE /api/assets`. Soft-delete default (Trash, 30-day retention). `--skip-verify` to bypass (with warning + prompt). |
| `immich.restore.sh` | Inverse of soft-delete. Accepts UUIDs via `--from-file` (TSV or one-per-line, `-` for stdin), batches `POST /api/trash/restore/assets`. |
| `.immich_api_key` | API key file (chmod 600, gitignored). Override with `IMMICH_API_KEY` env var. |
| `runs/` | Per-invocation working dirs (gitignored). |

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
| `TRIVIAL` | plays cleanly BUT bytes < 1 MB AND not a camera-prefix name (Telegram stickers, WhatsApp thumbnails) | verified-junk |
| `PARTIAL` | video remux ratio 30–79% | rescued (review) |
| `GOOD` | video remux ≥ 80% AND (bytes ≥ 1 MB OR camera-prefix name); OR image passes both ffmpeg + ImageMagick | rescued (do not delete) |
| `VERIFY_ERROR` | ffmpeg/identify crashed, timed out, or non-zero exit | rescued (default safe) |

Camera-prefix regex: `^(PXL_|IMG_|VID_|DSC_|MOV_|MVI_)` — underscore distinguishes real camera names from messaging-app conventions (`VID-*-WA*.mp4` is WhatsApp, not a camera capture).

## Typical workflow

```bash
# 1. Verify API access (one-time / when troubleshooting)
bash immich.validate.sh

# 2. Detect junk — creates runs/<ts>/. Default scans both images and videos.
bash immich.find-junk.sh
bash immich.find-junk.sh --type=video     # videos only

# 3. Verify — physical playability check. Mandatory before delete.
bash immich.verify-junk.sh

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

## What's deferred

- True single-color detection (requires reading image bytes pixel by pixel — needs ImageMagick `identify -fx` or similar).
- Duplicate cleanup — Immich has built-in detection; handle via UI.
- Combined scan+verify+delete script — the explicit split is intentional. The review gap between verify and delete is the human-in-the-loop layer.
- Video Tier C (implied-bitrate floor, `bytes/duration < 200 kbps`) — replaced in spirit by verify's remux-ratio test (which catches the same class of broken clips with higher precision).

See `.claude/plans/immich-find-junk-plan.md`, `.claude/plans/immich-delete-plan.md`, `.claude/plans/immich-find-junk-videos-plan.md`, and `.claude/plans/immich-verify-pipeline-plan.md` for the full design rationale.
