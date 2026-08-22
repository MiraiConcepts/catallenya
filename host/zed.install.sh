#!/bin/bash
# Put host/zed-functions.sh in place at /etc/zfs/zed.d/zed-functions.sh.
#
# ZED is the only thing that notices a dying disk, and its notification path had four
# defects — see the header of host/zed-functions.sh for what they were and why the file
# is tracked here at all.
#
# IDEMPOTENT: re-running when the two already match does nothing and says so.
#
# It backs up first, and the backup name is dated rather than a bare `.bak` — there is
# already a `zed-functions.sh.bak` on this box from whoever added ntfy support in 2024,
# and overwriting someone else's backup with your own is how the original is lost.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/zed-functions.sh"
DST="/etc/zfs/zed.d/zed-functions.sh"

[[ $EUID -eq 0 ]] || { echo "zed.install: needs root (it writes ${DST})" >&2; exit 1; }
[[ -f "$SRC" ]]   || { echo "zed.install: missing ${SRC}" >&2; exit 1; }

# Refuse a file that will not parse, BEFORE it can replace a working one. zed sources
# this on every event; a syntax error here silences every pool alarm on the box.
sh -n "$SRC" || { echo "zed.install: ${SRC} is not valid POSIX sh, refusing" >&2; exit 1; }

# ...and refuse one whose ntfy sender is missing entirely, which `sh -n` cannot see.
grep -q '^zed_notify_ntfy()' "$SRC" || {
    echo "zed.install: ${SRC} defines no zed_notify_ntfy(), refusing" >&2; exit 1; }

if [[ -f "$DST" ]] && cmp -s "$SRC" "$DST"; then
    echo "zed.install: already in place, nothing to do"
    exit 0
fi

if [[ -f "$DST" ]]; then
    backup="${DST}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$DST" "$backup"
    echo "zed.install: backed up to ${backup}"
fi

install -m 0644 -o root -g root "$SRC" "$DST"
echo "zed.install: installed ${DST}"

# ZED reads the zedlets fresh per event, but the daemon caches nothing we changed; a
# reload is still the honest way to be sure the next event uses the new file.
if systemctl is-active --quiet zfs-zed; then
    systemctl restart zfs-zed
    echo "zed.install: restarted zfs-zed"
else
    echo "zed.install: zfs-zed is not running, nothing to restart"
fi

# A dpkg upgrade that offers a new upstream file leaves it beside ours rather than
# applying it — see the header. Say so if one is waiting.
if [[ -f "${DST}.dpkg-dist" ]]; then
    echo "zed.install: NOTE ${DST}.dpkg-dist exists — upstream has changed, diff it" >&2
fi
