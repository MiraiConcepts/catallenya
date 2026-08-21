#!/bin/bash
# Unattended daily wrapper for immich.fix-rotations.sh — run by
# immich.fix-rotations.timer (units in systemd/). Bakes pending rotate edits
# with --yes and notifies ntfy ONLY when something was baked, something
# failed, or a rotate was skipped for a reason that needs a human
# (ambiguous direction, missing render/original, exiftool failure).
# The normal daily outcome — nothing to bake, or only intentional
# crop/mirror edits present — is silent.
set -uo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Notification transport is shared; this script no longer builds a URL or reads .env
# itself. It used to `source` the root .env wholesale — forty-odd credentials, to use
# three of them — which the intake pipelines each stopped doing separately. ntfy.lib.sh
# extracts only the three keys it needs.
#
# MARKDOWN IS ON, and the flag that used to turn it off here is gone (2026-08-20).
# It was set because these bodies are camera filenames — "IMG_1234.jpg — rotated 90°"
# straight from the library, never escaped, and mostly underscores. A renderer ate
# them: underscores vanished and the middle of every name went italic. Worse,
# unescaped text under a renderer is where a filename could hide a live link.
#
# body_list() in ntfy/kinds.sh escapes every item, so the reason no longer holds. This
# was the file the whole opt-out was written for.
# shellcheck disable=SC2034  # read by ntfy.lib.sh, sourced below
NTFY_TOPIC="immich"

# A STABLE SEQUENCE ID, so a condition that persists is ONE message that keeps being
# replaced rather than a pile. Runs DAILY, and whatever breaks a bake usually breaks the next one too.
#
# It does NOT self-clear when the condition goes away. A fault has no buttons, and a
# notification without buttons is never withdrawn by the system: an absent message is
# ambiguous — fixed, mis-swiped, or never sent — and a stale one is not. See
# ntfy/MESSAGES.md.
BAKE_NTFY_ID="immich-bake-failed"
# And one for the photos a run could not settle. Same argument: this runs daily, and
# the same unreadable photo is flagged every morning until someone looks at it.
FLAGGED_NTFY_ID="immich-flagged"
# shellcheck source=/zpool/catallenya/ntfy/ntfy.lib.sh
source "/zpool/catallenya/ntfy/ntfy.lib.sh"

OUT="$(bash "${SCRIPT_DIR}/immich.fix-rotations.sh" --yes 2>&1)"
RC=$?
printf '%s\n' "${OUT}"

BAKED="$(sed -n 's|^Planned/updated: \([0-9]*\).*|\1|p' <<<"${OUT}")"
# Skips that need a human. Crop/mirror (SKIP_NON_ROTATE) and net-zero
# rotations (SKIP_NET_ZERO) are intentional edits — stay silent on those.
CONCERNS="$(grep -E '^  (SKIP|FAIL) ' <<<"${OUT}" | grep -vE 'SKIP_NON_ROTATE|SKIP_NET_ZERO' || true)"

# notify() moved to ntfy/ntfy.lib.sh. This was the last of four copies and the one
# that had drifted furthest: no --max-time, so a stalled ntfy blocked the run until
# systemd killed it at TimeoutStartSec=1h and reported failure for a bake that had
# already succeeded — and no hdr_safe on the title. Both come free with the move.
# Human-readable summaries: "photo.jpg — rotated 90°" / "photo.jpg — needs a look (...)"
# --- what happened, as items --------------------------------------------------
# TWO DIFFERENT THINGS come out of a run and they used to share one message: photos
# that were rotated, and photos the run could not settle. The title counted only the
# first, so `Baked: 2 Rotations` could sit above three lines. They are different kinds
# — one is a receipt with nothing owed, the other wants a human — and both pigeonhole
# and liquidroom already split exactly this way.
#
# Items are "name<TAB>detail", which is what body_list() renders indented.
BAKED_ITEMS=()
while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    BAKED_ITEMS+=("$line")
done < <(sed -n 's/^  DONE \(.*[^ ]\)  *net= *\([0-9]*\).*/\1\tRotated: \2°/p' <<<"${OUT}")

# Every line that made CONCERNS non-empty must reach a notification. Three shapes come
# out of immich.fix-rotations.sh:
#   "  SKIP <fn> net=90 ori=6 SKIP_AMBIGUOUS(...)"   verdict form (has net=)
#   "  SKIP <fn>       original missing"             no net=
#   "  FAIL <fn>       exiftool failed"              no net=
# A single sed requiring " net=" handled only the first, so the other two vanished:
# an empty body when they were the only findings, and — worse — silent omission in
# mixed runs. The fallback splits filename from reason on the %-20s padding gap; a
# line neither pattern understands passes through whole, so a concern can read rough
# but can never disappear.
FLAG_ITEMS=()
while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    pretty="$(sed -n 's/^  \(SKIP\|FAIL\) \(.*[^ ]\)  *net=.* \([A-Z_]*[A-Z_(].*\)$/\2\tReason: \3/p' <<<"${line}")"
    if [[ -z "${pretty}" ]]; then
        pretty="$(sed -n 's/^  \(SKIP\|FAIL\) \(.*[^ ]\) \{2,\}\([^ ].*\)$/\2\tReason: \3/p' <<<"${line}")"
    fi
    FLAG_ITEMS+=("${pretty:-${line}}")
done <<<"${CONCERNS}"

# --- notify --------------------------------------------------------------------
# THE FAILURE BODY NO LONGER REPEATS THE OUTPUT. It carried `tail -n 8` of the run
# plus a pointer to the journal — and since 2026-08-20 the COURIER's message, which
# arrives alongside this one because a failed worker always trips OnFailure=, is
# exactly the job's last eight lines of stdout. Two messages saying the same thing is
# worse than one saying it and one adding what the other cannot: the parsed counts.
if [[ ${RC} -ne 0 ]]; then
    fail_body=""
    (( ${#FLAG_ITEMS[@]} )) && fail_body="$(body_list "${FLAG_ITEMS[@]}")"$'\n'
    fail_body+="Baked ${BAKED:-0} before the run stopped. Output is in the alert beside this one."
    notify_fault "$(title_state "Rotation Bake" Failed)" "$fail_body" "$BAKE_NTFY_ID"
else
    # A receipt for the rotations that landed. Silent when there were none — a bake
    # that did nothing is not news.
    if (( ${#BAKED_ITEMS[@]} )); then
        notify_receipt "$(title_count Baked "${#BAKED_ITEMS[@]}" Rotation)" \
            "$(body_list "${BAKED_ITEMS[@]}")"
    fi
    # ...and a FAULT for the photos it could not settle, separately, because that is a
    # different kind: this one wants a human. A stable id, so the same unreadable photo
    # replaces itself each morning rather than stacking.
    if (( ${#FLAG_ITEMS[@]} )); then
        notify_fault "$(title_count Flagged "${#FLAG_ITEMS[@]}" Rotation)" \
            "$(body_list "${FLAG_ITEMS[@]}")" "$FLAGGED_NTFY_ID"
    fi
fi
exit "${RC}"
