#!/bin/bash
# Exit immediately if a command fails, or if unset variables are used
set -euo pipefail

# Health check for changedetection watches.
#
# changedetection CANNOT self-report a broken watch. Verified empirically 2026-08-02
# with unmuted throwaway watches rechecked past the 6-failure threshold: a DNS failure,
# an HTTP 404, a re-gated endpoint and a filter that stops matching ALL leave
# notification_alert_count at 0. Every error branch in worker.py just writes last_error
# onto the watch and returns; only FilterNotFoundInResponse notifies, and that is raised
# solely by `if not filtered_content.strip()` — which a jq filter building an array can
# never satisfy, because it returns the two-character string "[]". So a dead watch is
# indistinguishable from a quiet one unless something outside asks. This is that thing.
#
# Publishes to the SAME topic changedetection itself uses. Deliberate: a new topic is one
# more thing to subscribe to on the phone, and a monitoring alert nobody is subscribed to
# is worse than no alert at all (ntfy creates topics on first publish and returns 200).

# Source root .env
ROOT_ENV="/zpool/catallenya/.env"
if [[ -f "$ROOT_ENV" ]]; then
    # shellcheck source=/dev/null  # runtime-only file, not in the repo
    source "$ROOT_ENV"
else
    echo "Root .env not found at $ROOT_ENV"
    exit 1
fi

# Interpolate NTFY_URL after sourcing
NTFY_URL="https://${TAILNET_DOMAIN}.${TAILNET_DNS_NAME}:${NTFY_REVERSE_PROXY_PORT}"
TOPIC="${CHANGEDETECTION_NTFY_TOPIC}"

CONTAINER="changedetection"

send_alert() {
    curl -H "Tags: warning" \
         -H "Title: Changedetection Health" \
         -H "Priority: high" \
         -d "$1" \
         "${NTFY_URL}/${TOPIC}"
}

# The container being gone is itself the loudest failure, and it must be reported by us
# rather than by dying: an exec against a stopped container would abort the script, and
# OnFailure= would then send a systemctl dump that says nothing about watches.
if [[ "$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)" != "running" ]]; then
    send_alert "changedetection container is not running — no watch is being checked at all."
    exit 0
fi

# Everything runs INSIDE the container: the API token is a root-owned 0600 file this
# script (User=carrein) cannot read, the container has no curl, and its IP changes on
# every recreate. Talking to 127.0.0.1:5000 from within sidesteps all three.
# -i is load-bearing: without it docker exec does not forward stdin, python reads an
# empty program, prints nothing and exits 0 — the health check would report "all clear"
# forever while looking at nothing. Caught by live-fire test 2026-08-09.
REPORT="$(docker exec -i "$CONTAINER" python3 - <<'PY'
import json
import time
import urllib.request

BASE = "http://127.0.0.1:5000/api/v1"
# A watch legitimately quiet for a month is possible; a filter silently returning frozen
# data looks exactly the same, so this nags rather than warns. Tune if it gets noisy.
QUIET_AFTER = 30 * 86400
# Floor for "should have checked by now". Every check interval here is minutes, but a
# future weekly watch would false-positive on a fixed floor, hence max(3x interval, 6h).
STALL_FLOOR = 6 * 3600

with open("/datastore/changedetection.json") as fh:
    token = json.load(fh)["settings"]["application"]["api_access_token"]


def api(path):
    req = urllib.request.Request(BASE + path, headers={"x-api-key": token})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def interval_seconds(watch, default_seconds):
    if watch.get("time_between_check_use_default", True):
        return default_seconds
    spec = watch.get("time_between_check") or {}
    mult = {"weeks": 604800, "days": 86400, "hours": 3600, "minutes": 60, "seconds": 1}
    total = sum(mult[k] * v for k, v in spec.items() if v)
    return total or default_seconds


now = time.time()
problems = []

try:
    watches = api("/watch")
except Exception as exc:  # noqa: BLE001 - any failure here means we cannot judge health
    print(f"BROKEN: cannot reach the changedetection API ({exc})")
    raise SystemExit(0)

# An EMPTY watch list is byte-identical to a clean bill of health: the loop below
# never runs, `problems` stays empty, nothing prints, and the check reports all
# clear. That is the same door as the `docker exec -i` bug — python read an empty
# program, printed nothing, exited 0, and the health check said fine forever while
# looking at nothing.
#
# But zero watches is also a LEGITIMATE state if you deleted the last one on
# purpose, so "zero is broken" would cry wolf every day. What is never legitimate
# is the count SILENTLY FALLING to zero. So remember it, and report the drop.
#
# The count lives here, not in the watchdog: the watchdog's job is "did this script
# run", and it has no business knowing what a watch is.
COUNT_FILE = "/zpool/catallenya/systemd/state/.changedetection-watch-count"
previous = None
try:
    with open(COUNT_FILE) as fh:
        previous = int(fh.read().strip())
except Exception:  # noqa: BLE001 - first run, or unreadable: treat as unknown
    pass

if not watches:
    if previous:
        problems.append(
            f"BROKEN: the watch list is EMPTY (was {previous} last run) — "
            "every check below has nothing to look at, and silence here would "
            "otherwise read as all clear"
        )
    # previous 0 or unknown: a deliberate empty list, or the first run. Say nothing.

try:
    with open(COUNT_FILE, "w") as fh:
        fh.write(str(len(watches)))
except Exception:  # noqa: BLE001 - a bookkeeping failure must not fail the check
    pass

# The API exposes no global check interval, so assume a conservative 3h for watches
# left on "use default". Only ever widens the stall window, never narrows it.
global_default = 3 * 3600

for uuid in watches:
    w = api("/watch/" + uuid)
    title = w.get("title") or w.get("url") or uuid[:8]

    if w.get("paused"):
        continue

    if w.get("last_error"):
        problems.append(f"BROKEN: {title}\n  {str(w['last_error'])[:200]}")
        continue

    last_checked = w.get("last_checked") or 0
    overdue_after = max(3 * interval_seconds(w, global_default), STALL_FLOOR)

    if not last_checked:
        # Never checked at all — the most complete failure there is, and invisible if
        # this branch just skips it. Allow a grace window so a watch created minutes
        # before this run is not reported before it has had a chance to fetch.
        if now - (w.get("date_created") or 0) > overdue_after:
            problems.append(f"BROKEN: {title}\n  has NEVER been checked since it was created")
        continue

    age = now - last_checked
    if age > overdue_after:
        problems.append(
            f"STALLED: {title}\n  last checked {age / 3600:.1f}h ago — worker may be stuck"
        )
        continue

    last_changed = w.get("last_changed") or 0
    if last_changed and (now - last_changed) > QUIET_AFTER:
        days = (now - last_changed) / 86400
        problems.append(
            f"QUIET: {title}\n  no change in {days:.0f}d — may be fine, or the filter may be "
            f"returning frozen data (check the snapshot looks right)"
        )

    if w.get("notification_muted"):
        problems.append(f"MUTED: {title}\n  changes are detected but nothing is sent")

for line in problems:
    print(line)
PY
)"

# Silence is the healthy state, matching restic.staleness — no OnSuccess chatter.
if [[ -n "${REPORT//[[:space:]]/}" ]]; then
    send_alert "$REPORT"
fi
