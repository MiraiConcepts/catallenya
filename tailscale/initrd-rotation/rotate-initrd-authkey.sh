#!/bin/bash
#
# Rotate the signed auth key embedded in /etc/tailscale/initramfs/config.
#
# Mints a fresh tskey-auth-* via the Tailscale OAuth client, wraps it with
# `tailscale lock sign` so new nodes registering with it are auto-signed by TKA,
# replaces the AUTHKEY line in the initramfs config, rebuilds all kernels'
# initramfs, and notifies ntfy.
#
# Runs as root (via systemd). Idempotent — partial failures leave the box
# in a working state (current key remains valid until its 90-day expiry).

set -euo pipefail

ROOT_ENV="/zpool/catallenya/.env"
INITRD_CONFIG="/etc/tailscale/initramfs/config"
KEY_EXPIRY_SECONDS=7776000   # 90 days = max allowed by Tailscale
NTFY_TOPIC="boot"

# --- Source secrets ---
if [[ ! -f "$ROOT_ENV" ]]; then
    echo "FATAL: $ROOT_ENV not found" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$ROOT_ENV"

: "${TAILSCALE_OAUTH_CLIENT_ID:?missing in .env}"
: "${TAILSCALE_OAUTH_CLIENT_SECRET:?missing in .env}"
: "${TAILSCALE_TAILNET:=-}"
: "${TAILNET_DOMAIN:?missing in .env}"
: "${TAILNET_DNS_NAME:?missing in .env}"
: "${NTFY_REVERSE_PROXY_PORT:?missing in .env}"

NTFY_URL="https://${TAILNET_DOMAIN}.${TAILNET_DNS_NAME}:${NTFY_REVERSE_PROXY_PORT}/${NTFY_TOPIC}"

# --- Helper: notify ntfy and optionally exit ---
notify() {
    local title="$1"
    local body="$2"
    local priority="${3:-default}"
    local tag="${4:-key}"
    curl -fsS \
        -H "Title: $title" \
        -H "Priority: $priority" \
        -H "Tags: $tag" \
        -d "$body" \
        "$NTFY_URL" >/dev/null 2>&1 || true
}

fail() {
    local msg="$1"
    echo "FATAL: $msg" >&2
    notify "initrd rotation failed" "$msg" "high" "warning"
    exit 1
}

trap 'fail "unexpected error at line $LINENO (cmd: $BASH_COMMAND)"' ERR

# --- Preflight ---
[[ $EUID -eq 0 ]] || fail "must run as root"
command -v jq    >/dev/null || fail "jq not installed"
command -v curl  >/dev/null || fail "curl not installed"
command -v tailscale >/dev/null || fail "tailscale not installed"
[[ -f "$INITRD_CONFIG" ]] || fail "$INITRD_CONFIG not found"

# --- 1. Get OAuth access token (~1h lifetime) ---
echo "[1/5] Exchanging OAuth client credentials for access token..."
ACCESS_TOKEN="$(curl -fsS \
    -u "${TAILSCALE_OAUTH_CLIENT_ID}:${TAILSCALE_OAUTH_CLIENT_SECRET}" \
    -d "grant_type=client_credentials" \
    "https://api.tailscale.com/api/v2/oauth/token" \
    | jq -r '.access_token')" \
    || fail "OAuth token exchange failed"
[[ -n "$ACCESS_TOKEN" && "$ACCESS_TOKEN" != "null" ]] || fail "OAuth returned empty access_token"

# --- 2. Mint a fresh auth key tagged tag:initrd ---
echo "[2/5] Minting fresh auth key (expiry: ${KEY_EXPIRY_SECONDS}s)..."
MINT_RESPONSE="$(curl -fsS \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
        \"capabilities\": {
            \"devices\": {
                \"create\": {
                    \"reusable\": true,
                    \"ephemeral\": true,
                    \"preauthorized\": true,
                    \"tags\": [\"tag:initrd\"]
                }
            }
        },
        \"expirySeconds\": ${KEY_EXPIRY_SECONDS}
    }" \
    "https://api.tailscale.com/api/v2/tailnet/${TAILSCALE_TAILNET}/keys")" \
    || fail "auth key mint API call failed"

RAW_AUTHKEY="$(echo "$MINT_RESPONSE" | jq -r '.key')"
KEY_ID="$(echo "$MINT_RESPONSE" | jq -r '.id')"
EXPIRES="$(echo "$MINT_RESPONSE" | jq -r '.expires')"
[[ -n "$RAW_AUTHKEY" && "$RAW_AUTHKEY" != "null" ]] || fail "mint returned empty key: $MINT_RESPONSE"

# --- 3. Sign the auth key with TKA so new nodes register pre-signed ---
echo "[3/5] Wrapping auth key with tailscale lock sign..."
SIGNED_AUTHKEY="$(tailscale lock sign "$RAW_AUTHKEY")" \
    || fail "tailscale lock sign failed (is this node a TKA signer? check 'tailscale lock status')"
[[ -n "$SIGNED_AUTHKEY" ]] || fail "tailscale lock sign returned empty"

# --- 4. Atomically replace the AUTHKEY line in the initramfs config ---
echo "[4/5] Replacing AUTHKEY in $INITRD_CONFIG..."
TMP_CONFIG="$(mktemp /tmp/initrd-config.XXXXXX)"
chmod 600 "$TMP_CONFIG"
awk -v k="$SIGNED_AUTHKEY" '
    /^TAILSCALE_AUTHKEY=/ { print "TAILSCALE_AUTHKEY=" k; replaced=1; next }
    { print }
    END { if (!replaced) print "TAILSCALE_AUTHKEY=" k }
' "$INITRD_CONFIG" > "$TMP_CONFIG"

# Backup current config alongside (single rolling backup)
cp -a "$INITRD_CONFIG" "${INITRD_CONFIG}.bak"
mv "$TMP_CONFIG" "$INITRD_CONFIG"
chmod 600 "$INITRD_CONFIG"

# Sanity check that the new line is present and well-formed
grep -q '^TAILSCALE_AUTHKEY=tskey-' "$INITRD_CONFIG" \
    || fail "post-write grep failed; restore from ${INITRD_CONFIG}.bak"

# --- 5. Rebuild all kernels' initramfs to bake the new key in ---
echo "[5/5] Running update-initramfs -u -k all..."
update-initramfs -u -k all || fail "update-initramfs failed; old initramfs still works but new config not deployed"

# --- Success ---
EXPIRES_HUMAN="$(date -d "$EXPIRES" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || echo "$EXPIRES")"
notify "initrd auth key rotated" \
    "New signed auth key installed.
Key ID: $KEY_ID
Expires: $EXPIRES_HUMAN
Source: $(hostname -s)" \
    "default" "key,white_check_mark"

echo "Rotation complete. New key expires: $EXPIRES_HUMAN"
exit 0
