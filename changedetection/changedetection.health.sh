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

ROOT_ENV="/zpool/catallenya/.env"
if [[ ! -f "$ROOT_ENV" ]]; then
    echo "Root .env not found at $ROOT_ENV" >&2
    exit 1
fi

# One key from the root .env, extracted rather than sourced. This script used to
# `source` that file wholesale to reach a single topic name: forty-odd database
# credentials and service tokens pulled into the process, and arbitrary code
# execution if a data file ever grew a $(...). Same shape as _ntfy_env in
# ntfy.lib.sh, which does exactly this for the three keys the transport needs; it
# is written out again here rather than shared because the shared one deliberately
# reads a fixed list, and one extra key is not a reason to make that list dynamic.
env_key() {                       # env_key <KEY>
    local line v
    line="$(grep -m1 "^${1}=" "$ROOT_ENV" 2>/dev/null)" || return 1
    v="${line#*=}"; v="${v%\"}"; v="${v#\"}"
    printf '%s' "$v"
}

# The SAME topic changedetection itself publishes to — see the header for why.
# `|| true`: env_key returns non-zero for a key that is not there, and under `set -e`
# that would abort here with no message rather than reaching the check below.
# shellcheck disable=SC2034  # read by ntfy.lib.sh, sourced below
NTFY_TOPIC="$(env_key CHANGEDETECTION_NTFY_TOPIC || true)"

# NTFY_MARKDOWN=no, the immich opt-out. Every line of the body carries text this box
# does not author: a watch title chosen on someone else's website, a URL, and a
# `last_error` string echoed back from a remote server. Under a renderer that is a
# place a link can hide inside a notification the owner already trusts, and watch
# titles are full of underscores that would italicise half the report.
# shellcheck disable=SC2034
NTFY_MARKDOWN=no
# shellcheck source=/zpool/catallenya/ntfy/ntfy.lib.sh
source "/zpool/catallenya/ntfy/ntfy.lib.sh"

if [[ -z "$NTFY_TOPIC" ]]; then
    echo "CHANGEDETECTION_NTFY_TOPIC not found in ${ROOT_ENV}" >&2
    exit 1
fi

CONTAINER="changedetection"

# Where the watch count is remembered between runs — see the WATCH_COUNT marker
# below for what it is for. systemd/state/ is this box's one place for a job's own
# runtime record, and 10-base.conf grants every unit write access to it, which is
# what makes this writable under the monitor class's ProtectSystem=strict.
COUNT_FILE="/zpool/catallenya/systemd/state/.changedetection-watch-count"

# A findings alert is the only output this job has. It is silent when healthy, so a
# publish that fails leaves an hour indistinguishable from a clean bill of health —
# and notify() is best-effort by design (every path ends in `|| true`) because for
# the intake pipelines a dropped notification must never fail work that succeeded.
# Here the notification IS the work, so the transport's silence is the test: curl
# -fsS prints nothing on a successful publish and prints the failure otherwise, and
# _ntfy_env logs when it declines. Anything it says is an undelivered alert, and
# failing means no completion stamp — so the watchdog reports this job within its 36h
# MaxAge even when ntfy itself is what is down.
# report_title <report> -> the fault title for a report of N problems.
#
# The subject may not repeat the topic, so on topic `changedetection` it names what is
# actually wrong rather than the service. With exactly ONE bad watch that is the watch
# itself — the most useful thing a lock screen can say — and with more it is a count,
# because two names is a list and three is a paragraph. The old title was the literal
# `Changedetection Health`, which said neither.
#
# A report with no recognisable problem line still counts as one finding: something was
# reported, and `0 Findings` would read as a clean bill of health for an alert that
# fired.
report_title() {
    local report="$1" n line state watch
    n="$(grep -cE '^(BROKEN|STALLED|QUIET|MUTED):' <<<"$report" || true)"
    (( n < 1 )) && n=1
    if (( n == 1 )) && line="$(grep -m1 -E '^(BROKEN|STALLED|QUIET|MUTED):' <<<"$report")"; then
        state="${line%%:*}"; watch="${line#*: }"
        # BROKEN -> Broken. Title Case, matching every other state in the contract.
        state="${state:0:1}$(tr '[:upper:]' '[:lower:]' <<<"${state:1}")"
        # The API-level failures name no watch — "cannot reach the changedetection
        # API (…)", "the watch list is EMPTY (…)" — so there is nothing to put in the
        # subject slot and the count form is the honest one.
        case "$watch" in
            cannot\ reach* | the\ watch\ list*) title_state Watches "1 Finding" ;;
            *)                                  title_state "$watch" "$state" ;;
        esac
    else
        title_state Watches "${n} Finding$( (( n == 1 )) || printf s )"
    fi
}

send_alert() {
    local out
    echo "$1"
    out="$(notify "$1" "" warning "$2" 2>&1)"
    if [[ -n "$out" ]]; then
        echo "changedetection.health: ntfy publish FAILED, the report above was not delivered: ${out}" >&2
        exit 1
    fi
}

# The container being gone is itself the loudest failure, and it must be reported by us
# rather than by dying: an exec against a stopped container would abort the script, and
# OnFailure= would then send a systemctl dump that says nothing about watches.
if [[ "$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)" != "running" ]]; then
    send_alert "$(title_state Changedetection "Not Running")" \
        "changedetection container is not running — no watch is being checked at all."
    exit 0
fi

# The previous run's watch count, read HOST-SIDE and passed in.
#
# It used to be read and written by the python below, at this same absolute path —
# which does not exist INSIDE the container: /zpool is not mounted there. Both the
# open-for-read and the open-for-write were wrapped in bare `except: pass`, so the
# feature never worked and never said so. `previous` was None on every run, the
# empty-watch-list alert could therefore never fire, and the file was never created.
# State that belongs to the JOB stays with the job; only the question crosses into
# the container.
previous=""
if [[ -f "$COUNT_FILE" ]]; then
    previous="$(<"$COUNT_FILE")"
    previous="${previous//[^0-9]/}"
fi

# Everything runs INSIDE the container: the API token is a root-owned 0600 file this
# script (User=carrein) cannot read, the container has no curl, and its IP changes on
# every recreate. Talking to 127.0.0.1:5000 from within sidesteps all three.
# -i is load-bearing: without it docker exec does not forward stdin, python reads an
# empty program, prints nothing and exits 0 — the health check would report "all clear"
# forever while looking at nothing. Caught by live-fire test 2026-08-09.
#
# The count rides in as an ENVIRONMENT VARIABLE, and the heredoc stays quoted ('PY')
# so the program text is never interpolated. Splicing the value into the source would
# have been the shorter change and would have made a file this script writes into a
# place a python literal can be escaped from.
REPORT="$(docker exec -i -e PREVIOUS_COUNT="$previous" "$CONTAINER" python3 - <<'PY'
import json
import os
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

# The current count, reported on a marker line the host parses off and remembers.
# It is printed only once the API has actually answered: the failure branch above
# exits before this, so a run that could not reach the API leaves the host's
# remembered count untouched rather than overwriting it with a zero it did not see.
print(f"WATCH_COUNT={len(watches)}")

# An EMPTY watch list is byte-identical to a clean bill of health: the loop below
# never runs, `problems` stays empty, nothing prints, and the check reports all
# clear. That is the same door as the `docker exec -i` bug — python read an empty
# program, printed nothing, exited 0, and the health check said fine forever while
# looking at nothing.
#
# But zero watches is also a LEGITIMATE state if you deleted the last one on
# purpose, so "zero is broken" would cry wolf every day. What is never legitimate
# is the count SILENTLY FALLING to zero. So compare against what the host remembers.
#
# The count lives with this job, not in the watchdog: the watchdog's job is "did this
# script run", and it has no business knowing what a watch is.
try:
    previous = int(os.environ.get("PREVIOUS_COUNT") or 0)
except ValueError:  # not a number: treat as unknown, exactly like a first run
    previous = 0

if not watches:
    if previous:
        problems.append(
            f"BROKEN: the watch list is EMPTY (was {previous} last run) — "
            "every check below has nothing to look at, and silence here would "
            "otherwise read as all clear"
        )
    # previous 0 or unknown: a deliberate empty list, or the first run. Say nothing.

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

# Split the marker off the findings. A run that could not reach the API prints no
# marker at all, and `current` stays empty — which is why the write below is
# conditional: the remembered count must survive an outage, or the first hour of a
# dead API would erase the very number the empty-list check compares against.
current="$(sed -n 's/^WATCH_COUNT=\([0-9][0-9]*\)$/\1/p' <<<"$REPORT" | head -1)"
# `|| true`: grep -v exits 1 when it emits nothing, which is the ordinary case of a
# healthy run whose only output was the marker.
REPORT="$(grep -v '^WATCH_COUNT=' <<<"$REPORT" || true)"

if [[ -n "$current" ]]; then
    # A bookkeeping failure must not fail the check — the watches were read and the
    # findings are real either way. It is not silent, though: an unwritable count
    # file means the empty-list alert is disarmed from the next run onwards, and
    # that is exactly the kind of quiet disarming this whole script exists to catch.
    if ! printf '%s\n' "$current" > "$COUNT_FILE" 2>/dev/null; then
        echo "changedetection.health: could not write ${COUNT_FILE} — the empty-watch-list check is disarmed until this is fixed" >&2
    fi
fi

# Silence is the healthy state, matching restic.staleness — no OnSuccess chatter.
if [[ -n "${REPORT//[[:space:]]/}" ]]; then
    send_alert "$(report_title "$REPORT")" "$REPORT"
fi
