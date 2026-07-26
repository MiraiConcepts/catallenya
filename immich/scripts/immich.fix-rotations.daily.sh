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

# Source root .env for the ntfy URL (same pattern as ntfy/disk-ntfy.sh)
ROOT_ENV="/zpool/catallenya/.env"
if [[ -f "$ROOT_ENV" ]]; then
    # shellcheck source=/dev/null  # runtime-only file, not in the repo
    source "$ROOT_ENV"
else
    echo "Root .env not found at $ROOT_ENV" >&2
    exit 1
fi
NTFY_URL="https://${TAILNET_DOMAIN}.${TAILNET_DNS_NAME}:${NTFY_REVERSE_PROXY_PORT}"
TOPIC="immich"

OUT="$(bash "${SCRIPT_DIR}/immich.fix-rotations.sh" --yes 2>&1)"
RC=$?
printf '%s\n' "${OUT}"

BAKED="$(sed -n 's|^Planned/updated: \([0-9]*\).*|\1|p' <<<"${OUT}")"
# Skips that need a human. Crop/mirror (SKIP_NON_ROTATE) and net-zero
# rotations (SKIP_NET_ZERO) are intentional edits — stay silent on those.
CONCERNS="$(grep -E '^  (SKIP|FAIL) ' <<<"${OUT}" | grep -vE 'SKIP_NON_ROTATE|SKIP_NET_ZERO' || true)"

notify() { # $1=title $2=priority $3=tags $4=body
    # --data-raw, never -d: curl reads a -d value beginning with "@" as a FILENAME
    # and POSTs that file's contents. The body starts with an asset filename, so a
    # file named "@/zpool/catallenya/.env" would exfiltrate it to the ntfy topic.
    # --data-raw is byte-identical except it never interprets a leading @.
    curl -sS -H "Title: $1" -H "Priority: $2" -H "Tags: $3" \
         --data-raw "$(tail -c 3500 <<<"$4")" "${NTFY_URL}/${TOPIC}" >/dev/null || true
}

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
