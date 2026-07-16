#!/bin/bash
# documents.intake.daily.sh — unattended wrapper, run by documents.intake.timer.
#
# Runs scan -> classify -> apply and notifies ntfy ONLY when something was filed, a
# duplicate was removed, something was newly flagged, something failed, or something has
# been stuck at root for >7 days. The normal outcome — nothing arrived — is silent.
# Same contract as immich.fix-rotations.daily.sh.
#
# LOG DISCIPLINE (plan 3.2): full detail goes to journald, which is host-only and NOT a
# restic target. Only hash/enum/destination lines reach the synced log. Never document
# text, never raw prompts, never exception bodies. The reason is architectural, not
# fussiness: /zpool/catallenya/syncthing/data IS a restic target and master/.stignore
# filters only macOS junk, so a log line lands in Backblaze AND on every phone. The log
# is more exposed than the documents it describes.

set -uo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/zpool/catallenya/syncthing/scripts/documents.lib.sh
source "${SCRIPT_DIR}/documents.lib.sh"

MODE="${1:---yes}"

mkdir -p "$STATE_DIR" "$WORK_DIR"

# Serialise: a slow run must not overlap the next.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "another intake run holds the lock; exiting"
    exit 0
fi

cleanup() { rm -f "${WORK_DIR:?}"/*.png "${WORK_DIR:?}"/*.txt 2>/dev/null || true; }
trap cleanup EXIT

SCAN="$("${SCRIPT_DIR}/documents.intake.scan.sh")" || {
    notify "Documents intake failed (scan)" high rotating_light \
        "scan phase errored. journalctl -u documents.intake.service"
    exit 1
}

if [[ "$(jq -r '.skipped // "no"' <<<"$SCAN")" != "no" ]]; then
    log "nothing to do ($(jq -r .skipped <<<"$SCAN")) — silent"
    exit 0
fi

ADJ="$("${SCRIPT_DIR}/documents.intake.classify.sh" <<<"$SCAN")" || {
    notify "Documents intake failed (classify)" high rotating_light \
        "classify phase errored — check auth first: claude auth status
journalctl -u documents.intake.service"
    exit 1
}

RES="$("${SCRIPT_DIR}/documents.intake.apply.sh" "$MODE" <<<"$ADJ")" || {
    notify "Documents intake failed (apply)" high rotating_light \
        "apply phase errored. journalctl -u documents.intake.service"
    exit 1
}

FILED=$(jq -r .filed   <<<"$RES")
REMOVED=$(jq -r .removed <<<"$RES")
FLAGGED=$(jq -r .flagged <<<"$RES")
FAILED=$(jq -r .failed  <<<"$RES")
TRUNC=$(jq -r '.truncated // 0' <<<"$SCAN")

# Anything sitting at root for >7 days: one nudge with a COUNT, not a re-listing.
# Flag once on first adjudication, then stay silent — notification fatigue would defeat
# the silent-unless-it-matters contract that makes this job trustworthy at all.
STUCK=$(jq -r '[.candidates[] | select(.status=="SKIP_SEEN" and (.age_days // 0) >= 7)] | length' <<<"$SCAN")

# --- synced log: enums and destinations only, never content ---
if (( FILED > 0 || REMOVED > 0 )) && [[ "$MODE" == "--yes" ]]; then
    LOGF="${DOCS}/.claude/plans/$(date +%Y-%m-%d)_intake-log.txt"
    {
        printf '%s  automated intake (documents.intake.timer)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        jq -r '.actions[] | select(.action=="filed")   | "  FILED   \(.file) -> \(.detail)"' <<<"$RES"
        jq -r '.actions[] | select(.action=="removed") | "  REMOVED \(.file) (identical to \(.detail))"' <<<"$RES"
        jq -r '.actions[] | select(.action=="flagged") | "  FLAG    \(.file) [\(.reason)]"' <<<"$RES"
        printf '\n'
    } >> "$LOGF"
fi

printf '%s\n' "$RES" | jq .

BODY="$(jq -r '.actions[] | if .action=="filed" or .action=="would-file" then "\(.file) → \(.detail)"
               elif .action=="removed" or .action=="would-remove" then "\(.file) — duplicate, removed"
               elif .action=="flagged" then "\(.file) — needs a look (\(.reason))"
               else "\(.file) — FAILED (\(.reason))" end' <<<"$RES")"

if (( FAILED > 0 )); then
    notify "Documents intake: ${FAILED} failure(s)" high rotating_light "$BODY"
elif (( FILED > 0 || REMOVED > 0 || FLAGGED > 0 )); then
    notify "Documents: ${FILED} filed, ${FLAGGED} flagged" default white_check_mark \
        "${BODY}$( ((TRUNC>0)) && printf '\n\n%s more deferred to tomorrow (per-run cap).' "$TRUNC" )"
elif (( STUCK > 0 )); then
    notify "Documents: ${STUCK} still waiting on you" default hourglass \
        "${STUCK} file(s) have sat at the root of master/documents for over a week."
fi

exit 0
