#!/bin/bash
#
# wire-initrd-state.sh [--rebuild]
#
# Wire the persistent catallenya-initrd identity into the initramfs boot path.
#
#   (no flag)   STAGE 1 — reversible, no boot-path change:
#                 * install the bake-in hook       -> /etc/initramfs-tools/hooks/initrd-tailscale-state
#                 * install a patched premount     -> /etc/initramfs-tools/scripts/init-premount/tailscale
#                   (a copy of the apt package script that OMITS --authkey when empty; the
#                    /etc copy overrides the package copy at build time and survives upgrades)
#                 * trim the config: remove TAILSCALE_LOGOUT and TAILSCALE_AUTHKEY lines
#                 * print the resulting files for review. NO initramfs rebuild.
#
#   --rebuild   STAGE 2 — changes the boot path:
#                 * (re-runs STAGE 1 idempotently)
#                 * snapshot every /boot/initrd.img-* to .preunlock-<stamp>
#                 * update-initramfs -u -k all
#                 * verify the state file + patched premount are baked into every image
#
# Run as root.
#
set -euo pipefail

REPO="/zpool/catallenya"
HOOK_SRC="$REPO/tailscale/initramfs-hooks/initrd-tailscale-state"
HOOK_DST="/etc/initramfs-tools/hooks/initrd-tailscale-state"
PREMOUNT_PKG="/usr/share/initramfs-tools/scripts/init-premount/tailscale"
PREMOUNT_DST="/etc/initramfs-tools/scripts/init-premount/tailscale"
CONFIG="/etc/tailscale/initramfs/config"
STATE="/etc/tailscale/initramfs/tailscaled.state"
STAMP="$(date +%Y%m%d-%H%M%S)"

DO_REBUILD=0
[[ "${1:-}" == "--rebuild" ]] && DO_REBUILD=1

fail() { echo "FATAL: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "run as root"
[[ -f "$STATE" ]]        || fail "$STATE missing — run generate-initrd-state.sh first"
[[ -f "$HOOK_SRC" ]]     || fail "$HOOK_SRC missing (repo copy)"
[[ -f "$PREMOUNT_PKG" ]] || fail "package premount $PREMOUNT_PKG missing"
[[ -f "$CONFIG" ]]       || fail "$CONFIG missing"
command -v python3 >/dev/null || fail "python3 needed for the premount patch"

# ---- STAGE 1: install files (idempotent, reversible) ----
echo "== [1] bake-in hook =="
install -m755 "$HOOK_SRC" "$HOOK_DST"
echo "   installed $HOOK_DST"

echo "== [2] patched premount override (omit --authkey when empty) =="
python3 - "$PREMOUNT_PKG" "$PREMOUNT_DST" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
needle = '--authkey="${TAILSCALE_AUTHKEY}"'
lines = open(src).read().splitlines(keepends=True)
out, patched = [], False
for ln in lines:
    if (needle in ln) and ('/bin/tailscale' in ln) and (' up ' in ln):
        indent = ln[:len(ln) - len(ln.lstrip())]
        out.append(indent + 'TS_AUTHKEY_ARG=""\n')
        out.append(indent + '[ -n "${TAILSCALE_AUTHKEY:-}" ] && TS_AUTHKEY_ARG="--authkey=${TAILSCALE_AUTHKEY}"\n')
        out.append(ln.replace(needle, '${TS_AUTHKEY_ARG}'))
        patched = True
    else:
        out.append(ln)
open(dst, 'w').write(''.join(out))
print("   PATCH: applied" if patched else
      "   PATCH: needle not found — installed verbatim (falls back to empty-authkey no-op)")
PYEOF
chmod 755 "$PREMOUNT_DST"

echo "== [3] trim config (remove TAILSCALE_LOGOUT + TAILSCALE_AUTHKEY) =="
cp -a "$CONFIG" "$CONFIG.bak.wire-$STAMP"
sed -i -E '/^[[:space:]]*TAILSCALE_LOGOUT=/d; /^[[:space:]]*TAILSCALE_AUTHKEY=/d' "$CONFIG"
echo "   backed up config -> $CONFIG.bak.wire-$STAMP"

echo
echo "------ REVIEW: hook ($HOOK_DST) ------"
cat "$HOOK_DST"
echo "------ REVIEW: premount authkey logic ($PREMOUNT_DST) ------"
grep -n -E 'TS_AUTHKEY_ARG|/bin/tailscale .* up ' "$PREMOUNT_DST" || true
echo "------ REVIEW: config (authkey redacted; must show NO TAILSCALE_AUTHKEY/LOGOUT) ------"
awk -F= '/^TAILSCALE_AUTHKEY=/{print $1"=<redacted>"; next} {print}' "$CONFIG"
echo "----------------------------------------------------------------"

if [[ "$DO_REBUILD" == 0 ]]; then
  echo
  echo "STAGE 1 done — files installed, NO rebuild. Review the above, then re-run with --rebuild."
  exit 0
fi

# ---- STAGE 2: backup + rebuild + verify (boot path changes here) ----
echo
echo "== [4] snapshot current initramfs images =="
for img in /boot/initrd.img-*; do
  case "$img" in *.preunlock*|*.old) continue ;; esac
  cp -a "$img" "$img.preunlock-$STAMP"
  echo "   $img -> $img.preunlock-$STAMP"
done

echo "== [5] update-initramfs -u -k all =="
update-initramfs -u -k all

echo
echo "== [6] verify baked images =="
allok=1
for kver in $(ls /boot/vmlinuz-* | sed 's|.*vmlinuz-||'); do
  img="/boot/initrd.img-$kver"
  [[ -f "$img" ]] || continue
  listing="$(lsinitramfs "$img")"
  st=$(printf '%s\n' "$listing" | grep -c 'var/lib/tailscale/tailscaled.state' || true)
  pm=$(printf '%s\n' "$listing" | grep -c 'scripts/init-premount/tailscale'   || true)
  echo "   $kver : state=$st premount=$pm (expect 1 1)"
  [[ "$st" == 1 && "$pm" == 1 ]] || allok=0
done
echo
if [[ "$allok" == 1 ]]; then
  echo "STAGE 2 done — identity baked into every image. Ready for the double-reboot test."
else
  echo "WARNING: some images missing state/premount — DO NOT reboot-test; investigate first."
fi
