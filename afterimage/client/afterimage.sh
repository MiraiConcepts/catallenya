#!/usr/bin/env bash
# Desktop capture client — drag-select a region, send it to the pipeline.
#
# THIS RUNS ON YOUR LAPTOP, NOT ON THE SERVER. Copy it to the machine you take
# screenshots on, install one screenshot tool (below), and bind it to a hotkey.
# See afterimage/README.md for the per-OS install + binding steps.
#
# Fire-and-forget by design: it grabs a region, uploads, and exits. Everything
# else (reading the image, proposing an event, the Add/Discard notification)
# happens server-side, and the result arrives as an ntfy push.
set -euo pipefail

# The capture service on your tailnet. Port matches AFTERIMAGE_REVERSE_PROXY_PORT in
# the server's .env; the host must be reachable over Tailscale.
#
# The literal default is a deliberate exception to the repo's no-hardcoded-hosts
# rule, which exists so SERVER config comes from .env. This script runs on a
# laptop, which cannot read the server's .env, so the host has to live somewhere —
# and requiring an env var would leave the hotkey silently broken until it is set.
# Override with AFTERIMAGE_URL if you run it from elsewhere. The name is not a secret:
# .ts.net certificates are published in Certificate Transparency logs.
AFTERIMAGE_URL="${AFTERIMAGE_URL:-https://catallenya.kamori-mulley.ts.net:10000/afterimage}"

shot="$(mktemp --suffix=.png 2>/dev/null || mktemp -t capture)"
# Whatever happens next, don't leave the screenshot lying around.
trap 'rm -f "$shot"' EXIT

# Region select, in order of preference. The pipeline requires PNG.
if   command -v grim  >/dev/null && command -v slurp >/dev/null; then
    grim -g "$(slurp)" "$shot"                 # Wayland (sway, Hyprland, GNOME-wl)
elif command -v maim  >/dev/null; then
    maim -s "$shot"                            # X11
elif command -v scrot >/dev/null; then
    scrot -s -o "$shot"                        # X11 fallback
elif command -v screencapture >/dev/null; then
    screencapture -i -t png "$shot"            # macOS
elif command -v spectacle >/dev/null; then
    spectacle -rbno "$shot"                    # KDE
else
    echo "capture: no screenshot tool found (install grim+slurp, maim, or use macOS)" >&2
    exit 1
fi

# A cancelled selection leaves an empty or missing file — exit quietly rather
# than uploading nothing and burning an API call server-side.
[[ -s "$shot" ]] || { echo "capture: cancelled" >&2; exit 0; }

# X-Afterimage: 1 is required by the server on every route. Not auth — it forces a
# CORS preflight the server never answers, so a web page on a tailnet device
# can't fire an upload cross-origin. See the comment in src/server.ts.
if resp="$(curl -fsS --max-time 30 -H 'Content-Type: image/png' -H 'X-Afterimage: 1' \
                --data-binary "@$shot" "$AFTERIMAGE_URL" 2>&1)"; then
    echo "capture: sent ($(du -h "$shot" | cut -f1)) — watch the 'capture' ntfy topic"
else
    echo "capture: upload failed — $resp" >&2
    exit 1
fi
