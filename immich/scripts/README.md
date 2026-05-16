# Immich cleanup pipeline

Scripts for finding and deleting junk/artifact images from the Immich library.

## Files

| File | Purpose |
|---|---|
| `immich.conf` | Base URL + API key file path (sourced by lib). |
| `immich.lib.sh` | Shared helpers: `imapi <METHOD> <path>`, `imapi_load_key`, `imapi_require_cmd`. |
| `immich.validate.sh` | Read-only connectivity + auth + stats sanity check. Run first to verify API access. |
| `immich.find-junk.sh` | Reads Postgres directly, writes a timestamped run dir under `runs/<ts>/` with `tier-a.tsv`, `tier-b.tsv`, `summary.txt`. Read-only. |
| `immich.delete.sh` | Consumes a run dir (latest unprocessed by default). Batches `DELETE /api/assets`. Soft-delete by default (asset → Trash, 30-day retention). |
| `.immich_api_key` | API key file (chmod 600, gitignored). Override with `IMMICH_API_KEY` env var. |
| `runs/` | Per-invocation working dirs (gitignored). |

Run `bash immich.<script>.sh --help` for full flag listings.

## Tier taxonomy

`find-junk` emits two tier files (de-duplicated by `delete.sh` at consume time):

- **Tier A — physical-impossibility junk.** `area < 10000 px` OR `fileSizeInByte < 5000` OR missing dim/size. Cannot represent a real photo.
- **Tier B — pattern-match junk.** Filenames matching narrow Android UI sprite prefixes (`abc_`, `ic_`, `btn_`, etc.) + 10 known tracking-pixel names.

Defensive filters baked into both: `type=IMAGE`, `status=active`, `deletedAt IS NULL`, `visibility=timeline`, `isFavorite=false`, not in any album.

Specificity over recall — designed for zero false positives. See the per-script header comments for thresholds.

## Typical workflow

```bash
# 1. Verify API access (one-time / when troubleshooting)
bash immich.validate.sh

# 2. Detect junk — creates runs/<ts>/
bash immich.find-junk.sh

# 3. Preview what will be deleted (no API calls)
bash immich.delete.sh --dry-run

# 4. Delete (soft, to trash). Auto-picks the latest unprocessed run dir.
bash immich.delete.sh           # interactive confirmation
bash immich.delete.sh --yes     # skip prompt
```

Soft-deleted assets sit in your Immich Trash for 30 days, reviewable + restorable via the UI. Immich auto-purges on day 31 (file + thumbnails + ML data, cascade handled server-side).

## Reading `deleted.tsv`

Each run dir's `deleted.tsv` is the audit trail:

```
<uuid>\t<http_status>\t<iso_timestamp>
```

- `204` = success (soft-deleted to trash)
- `404` = asset already gone (manually deleted, or prior trash purge)
- anything else = failure; inspect the response. The script continues past per-asset errors but aborts on `401` (revoked key).

The presence of `deleted.tsv` in a run dir marks it processed; `delete.sh` will skip it on auto-pick. Pass `--force-rerun` to re-process; the script subtracts IDs already in `deleted.tsv` so no double-deletes.

## What's deferred

- True single-color detection (requires reading image bytes — needs ImageMagick or similar).
- Duplicate cleanup — Immich has built-in detection; handle via UI.
- Combined scan+delete script — the find/delete split is intentional during taxonomy-building. Revisit once the taxonomy has been validated across several real cycles.

See `.claude/plans/immich-find-junk-plan.md` and `.claude/plans/immich-delete-plan.md` for the full design rationale.
