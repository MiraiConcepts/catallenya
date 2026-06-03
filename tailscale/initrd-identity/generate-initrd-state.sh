#!/bin/bash
#
# generate-initrd-state.sh
#
# Create (or recover) the PERSISTENT "catallenya-initrd" Tailscale identity used by the
# initramfs remote-LUKS-unlock path, and capture its tailscaled.state so it can be baked
# into the initramfs (see /etc/initramfs-tools/hooks/initrd-tailscale-state).
#
# Result: /etc/tailscale/initramfs/tailscaled.state (mode 600) for a NON-ephemeral,
# tag:initrd node named "catallenya-initrd", anchored by a SigDirect under THIS host's
# durable tailnet-lock "self" key (tlpub:b090...). Because it's anchored directly to the
# host key, the node does not depend on any per-authkey wrapped TLK and survives removal
# of the leftover "(pre-auth key ...)" signers.
#
# Replaces the old rotate-initrd-authkey.sh + monthly timer: this runs ON DEMAND only
# (once at setup; again only in the rare "identity went stale" recovery case).
#
# Isolation: runs a SEPARATE throwaway tailscaled (userspace-networking, its own
# --state/--socket) so it NEVER touches this host's primary tailscaled state.
#
# Usage (run as root): always supply a key you minted in the admin console
# (Settings -> Keys -> Generate auth key: tag:initrd, reusable OFF, ephemeral OFF, preauthorized).
# Minting was removed in the 2026-06-03 teardown (state-only posture, no OAuth client).
#   sudo bash generate-initrd-state.sh --authkey=tskey-auth-XXXX
#   sudo bash generate-initrd-state.sh --authkey=tskey-auth-XXXX --rebuild   # also update-initramfs
#
set -euo pipefail

STATE_DEST="/etc/tailscale/initramfs/tailscaled.state"
NODE_HOSTNAME="catallenya-initrd"
TAG="tag:initrd"
# Host-daemon (TKA signer) commands use the tailscale CLI's DEFAULT socket; only the
# throwaway daemon below is addressed explicitly via --socket="$THROW_SOCK".

TMPDIR="$(mktemp -d /tmp/initrd-ts.XXXXXX)"
THROW_SOCK="$TMPDIR/sock"
THROW_STATE="$TMPDIR/state"

AUTHKEY_IN=""
DO_REBUILD=0
for arg in "$@"; do
  case "$arg" in
    --authkey=*) AUTHKEY_IN="${arg#--authkey=}";;
    --rebuild)   DO_REBUILD=1;;
    *) echo "unknown arg: $arg" >&2; exit 2;;
  esac
done

THROW_PID=""
cleanup() {
  if [[ -n "$THROW_PID" ]]; then
    kill -TERM "$THROW_PID" 2>/dev/null || true
    for _ in 1 2 3 4 5; do kill -0 "$THROW_PID" 2>/dev/null || break; sleep 1; done
    kill -9 "$THROW_PID" 2>/dev/null || true
  fi
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

fail() { echo "FATAL: $*" >&2; [[ -f "$TMPDIR/tailscaled.log" ]] && { echo "--- tailscaled.log ---"; cat "$TMPDIR/tailscaled.log"; }; exit 1; }

[[ $EUID -eq 0 ]] || fail "run as root (sudo)"
for c in tailscale tailscaled jq; do command -v "$c" >/dev/null || fail "$c not installed"; done

# --- 1. Require a RAW tagged auth key (mint a one-off in the admin console) ---
if [[ -z "$AUTHKEY_IN" ]]; then
  fail "no --authkey provided. Minting was removed in the 2026-06-03 teardown (state-only; no OAuth client).
  Mint a ONE-OFF key in the admin console (Settings -> Keys -> Generate auth key:
  tag:initrd, reusable OFF, ephemeral OFF, preauthorized), then re-run:
      sudo bash $0 --authkey=tskey-auth-XXXX --rebuild"
fi
echo "[1/6] Using provided --authkey."
RAW_AUTHKEY="$AUTHKEY_IN"

# --- 2. TKA-wrap the key so the throwaway node comes up signed (not locked out) ---
echo "[2/6] Wrapping auth key with 'tailscale lock sign' (host is a TKA signer)..."
WRAPPED_AUTHKEY="$(tailscale lock sign "$RAW_AUTHKEY")" \
  || fail "tailscale lock sign failed (is this host a TKA signer? check 'tailscale lock status')"
[[ -n "$WRAPPED_AUTHKEY" ]] || fail "lock sign returned empty"

# --- 3. Start an isolated throwaway tailscaled (does NOT touch host state) ---
echo "[3/6] Starting throwaway tailscaled (userspace-networking)..."
tailscaled --tun=userspace-networking --state="$THROW_STATE" --socket="$THROW_SOCK" --port=0 \
  >"$TMPDIR/tailscaled.log" 2>&1 &
THROW_PID=$!
for _ in $(seq 1 30); do [[ -S "$THROW_SOCK" ]] && break; sleep 0.5; done
[[ -S "$THROW_SOCK" ]] || fail "throwaway tailscaled socket never appeared"

# --- 4. Register the node (comes up signed via the wrapped key) ---
echo "[4/6] Registering '$NODE_HOSTNAME'..."
tailscale --socket="$THROW_SOCK" up --authkey="$WRAPPED_AUTHKEY" \
  --hostname="$NODE_HOSTNAME" --advertise-tags="$TAG" --timeout=45s \
  || fail "tailscale up failed (see throwaway up output above)"

# --- 5. Anchor the node DIRECTLY under the host self key, then capture state ---
NODEKEY="$(tailscale --socket="$THROW_SOCK" status --json | jq -r '.Self.PublicKey // empty')"
[[ -n "$NODEKEY" ]] || fail "could not read node key from throwaway status"
[[ "$NODEKEY" == nodekey:* ]] || NODEKEY="nodekey:$NODEKEY"
echo "[5/6] Anchoring node under host self key:  $NODEKEY"
tailscale lock sign "$NODEKEY" \
  || fail "direct node-key lock sign failed"

# confirm it's authenticated, then persist the identity
for _ in $(seq 1 40); do
  [[ "$(tailscale --socket="$THROW_SOCK" status --json | jq -r '.BackendState // empty')" == "Running" ]] && break
  sleep 0.5
done
install -d -m700 "$(dirname "$STATE_DEST")"
install -m600 "$THROW_STATE" "$STATE_DEST"
echo "       wrote $STATE_DEST"

# --- 6. Optional initramfs rebuild ---
if [[ "$DO_REBUILD" == 1 ]]; then
  echo "[6/6] update-initramfs -u -k all ..."
  update-initramfs -u -k all
else
  echo "[6/6] (skipping initramfs rebuild; do that in the wiring step)"
fi

echo
echo "DONE."
echo "  Node key : $NODEKEY"
echo "  Verify in the admin console: '$NODE_HOSTNAME' is tag:initrd, Expiry: Disabled, NOT locked out."
echo "  (It will show OFFLINE once this script's throwaway daemon stops — that is expected.)"
