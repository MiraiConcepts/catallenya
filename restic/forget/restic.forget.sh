#!/bin/bash
set -euo pipefail

. /zpool/catallenya/restic/restic.conf
# shellcheck source=/zpool/catallenya/restic/restic.lib.sh
. /zpool/catallenya/restic/restic.lib.sh

# See restic.lib.sh. forget is the job this mattered most for: its stdout is the
# entire keep/remove table across all 18 snapshot groups, every path spelled out.
RESTIC_CAPTURE="$(mktemp)"
trap 'rm -f "$RESTIC_CAPTURE"' EXIT

# Clear a stale lock left by a run killed mid-flight — SIGKILL, an OOM kill,
# power loss. restic >=0.17.0 releases on SIGINT and SIGTERM (#4703), so the
# 2026-08-07 `timeout` case that orphaned an exclusive lock is fixed by the
# 0.19.1 upgrade; the ways a process dies WITHOUT a signal it can handle are
# not, and this host has no UPS. A LIVE run is never touched: restic refreshes its own
# lock every 5 min and self-aborts at 22.5 min if it cannot, so a running job's
# lock can never reach the 30 min staleness threshold.
restic -r "${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION}" \
    --password-file "${RESTIC_PASSWORD_FILE}" unlock

# Forget and prune stale snapshots in repository. --retry-lock waits out a LIVE
# lock (another job mid-run); the unlock above clears a DEAD one. Different
# cases, neither substitutes for the other.
restic_run "$RESTIC_CAPTURE" \
    -r "${RESTIC_DRIVER}:${RESTIC_RCLONE_REMOTE}:${RESTIC_BACKUP_LOCATION}" \
    --password-file "${RESTIC_PASSWORD_FILE}" \
    --retry-lock=30m \
    --verbose forget --prune \
    --keep-daily "${RESTIC_NUMBER_DAILY_TO_KEEP}" \
    --keep-weekly "${RESTIC_NUMBER_WEEKLY_TO_KEEP}" \
    --keep-monthly "${RESTIC_NUMBER_MONTHLY_TO_KEEP}" \
    --keep-yearly "${RESTIC_NUMBER_YEARLY_TO_KEEP}"

# --- the receipt ------------------------------------------------------------
# The numbers worth a lock screen are what was FREED and what is LEFT. The pack
# arithmetic above them (used/duplicates/unused/to-repack) is forensics and stays
# in the journal.
_pruned="$(first_match "$RESTIC_CAPTURE"    's/^total prune: +[0-9]+ blobs \/ ([0-9.]+ [KMGT]i?B)$/\1/p')"
_remaining="$(first_match "$RESTIC_CAPTURE" 's/^remaining: +[0-9]+ blobs \/ ([0-9.]+ [KMGT]i?B)$/\1/p')"
_repacked="$(first_match "$RESTIC_CAPTURE"  's/^to repack: +([0-9]+) packs$/\1/p')"

# SUMMED ACROSS GROUPS, not read from the first block. forget runs with restic's
# default --group-by host,paths and this repo has 18 groups, so "keep 7 snapshots:"
# appears once PER GROUP — reporting the first would be the same class of mistake
# restic.staleness made when `--latest 1` returned the oldest group's newest and
# called the repo 17186h stale. `remove` blocks are absent entirely on a run that
# drops nothing, hence the +0.
_kept="$(grep -oE '^keep [0-9]+ snapshots:$' "$RESTIC_CAPTURE" | awk '{s+=$2} END {print s+0}')"
_removed="$(grep -oE '^remove [0-9]+ snapshots?:?$' "$RESTIC_CAPTURE" | awk '{s+=$2} END {print s+0}')"

[[ -n "$_pruned"    ]] && fact "${_pruned} pruned"
[[ -n "$_remaining" ]] && fact "${_remaining} remaining"
[[ -n "$_repacked" && "$_repacked" != 0 ]] && fact "${_repacked} packs repacked"
[[ "${_removed:-0}" != 0 ]] && fact "${_removed} snapshots removed"
[[ "${_kept:-0}"    != 0 ]] && fact "${_kept} snapshots kept"
exit 0