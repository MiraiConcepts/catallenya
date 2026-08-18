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
# NTFY_MARKDOWN=no is deliberate and must stay. The bodies below are lines like
# "IMG_1234.jpg — rotated 90°" taken straight from the library and never escaped, and
# camera filenames are mostly underscores: rendered as Markdown they would lose the
# underscores and italicise the middle of every name. Unescaped text under a renderer
# is also where a filename could hide a real link.
# shellcheck disable=SC2034  # both are read by ntfy.lib.sh, sourced below
NTFY_TOPIC="immich"
# shellcheck disable=SC2034
NTFY_MARKDOWN=no
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
BAKED_LINES="$(sed -n 's/^  DONE \(.*[^ ]\)  *net= *\([0-9]*\).*/\1 — rotated \2°/p' <<<"${OUT}")"
CONCERN_LINES="$(sed -n 's/^  \(SKIP\|FAIL\) \(.*[^ ]\)  *net=.* \([A-Z_]*[A-Z_(].*\)$/\2 — needs a look (\3)/p' <<<"${CONCERNS}")"

if [[ ${RC} -ne 0 ]]; then
    notify "Immich rotation bake failed" high rotating_light \
        "$(tail -n 8 <<<"${OUT}")"$'\n\n'"Full log: journalctl -u immich.fix-rotations.service"
elif [[ -n "${BAKED}" && "${BAKED}" -gt 0 ]] || [[ -n "${CONCERNS}" ]]; then
    notify "Immich: ${BAKED:-0} rotation(s) baked" default white_check_mark \
        "${BAKED_LINES}${BAKED_LINES:+$'\n'}${CONCERN_LINES}"
fi
exit "${RC}"
