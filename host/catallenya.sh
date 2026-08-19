#!/bin/bash
set -euo pipefail

# Boot orchestrator for catallenya
# Runs after ZFS mount + Docker are ready.
# Re-reads systemd unit files (symlinks into /zpool now resolve),
# starts project timers, brings up Docker Compose, and notifies via ntfy.

COMPOSE_DIR="/zpool/catallenya"
SYSTEMD_DIR="/etc/systemd/system"
LOG_TAG="catallenya-boot"

# Notification transport is shared. Step 5 used to `source` the root .env wholesale —
# forty-odd database credentials and service tokens, into a root process, to build one
# URL out of three of them — and then hand-roll a curl with no --max-time, which on a
# half-started ntfy would have hung the boot until TimeoutStartSec=20min killed it.
# ntfy.lib.sh extracts only those three keys and carries the timeout and hdr_safe.
#
# Sourced FIRST, before this script's own log(): the library's definition is guarded
# (`declare -F log || log() {...}`), so the one below wins and stays authoritative.
#
# NTFY_MARKDOWN=no, the immich opt-out: the body is a built report of counts and
# error strings, never authored as Markdown.
# shellcheck disable=SC2034  # both are read by ntfy.lib.sh, sourced below
NTFY_TOPIC="host"
# shellcheck disable=SC2034
NTFY_MARKDOWN=no
# shellcheck source=/zpool/catallenya/ntfy/ntfy.lib.sh
source "/zpool/catallenya/ntfy/ntfy.lib.sh"

log() { echo "[${LOG_TAG}] $*"; }
fail() { log "FAIL: $*"; ERRORS+=("$*"); }

ERRORS=()

# --- Step 1: Reload systemd so symlinked units resolve ---
log "Reloading systemd daemon..."
if ! systemctl daemon-reload; then
    fail "daemon-reload failed"
fi

# --- Step 1b: Discover project timers and path units ---
# Don't hardcode the list. Any *.timer or *.path symlinked from this repo into
# systemd is ours; vendor units (logrotate, etc.) point elsewhere and are skipped.
# Adding a service that ships one (+ running systemd/install.sh) makes it show up
# here automatically — started below and counted in the ntfy message.
#
# Path units need this exactly as much as timers do, for the same reason the whole
# orchestrator exists: a symlink into /zpool does not resolve when PID1 builds the
# initial boot transaction, so paths.target drops the unit and nothing re-queues it
# after the daemon-reload above. afterimage.triage.path is what fires the screenshot
# triage — without this loop the capture pipeline is silently dead after every
# reboot, container healthy and Caddy routing, while this script still reports
# "All systems nominal."
log "Discovering project units..."
TIMERS=()
PATHS=()
for unit in "${SYSTEMD_DIR}"/*.timer "${SYSTEMD_DIR}"/*.path; do
    [[ -L "$unit" ]] || continue
    [[ "$(readlink "$unit")" == "${COMPOSE_DIR}/"* ]] || continue
    case "$unit" in
        *.timer) TIMERS+=("$(basename "$unit")") ;;
        *.path)  PATHS+=("$(basename "$unit")") ;;
    esac
done
if [[ ${#TIMERS[@]} -eq 0 ]]; then
    fail "No project timers found under ${SYSTEMD_DIR} (expected symlinks into ${COMPOSE_DIR})"
else
    log "  Found ${#TIMERS[@]} timer(s): ${TIMERS[*]}"
fi
# Zero path units is a legitimate state (they are newer and optional), so unlike
# timers this is not a failure.
if [[ ${#PATHS[@]} -gt 0 ]]; then
    log "  Found ${#PATHS[@]} path unit(s): ${PATHS[*]}"
else
    log "  No path units found"
fi

# --- Step 2: Bring up Docker Compose ---
log "Starting Docker Compose services..."
if ! runuser -u carrein -- docker compose -f "${COMPOSE_DIR}/docker-compose.yml" up -d 2>&1; then
    fail "docker compose up -d failed"
fi

# --- Step 3: Verify containers ---
log "Waiting 10s for containers to settle..."
sleep 10

log "Checking container states..."
NOT_RUNNING=()
RUNNING=0
# --all, not the default. `docker compose ps` lists RUNNING containers only, so a
# container that exited seconds after starting simply was not in this loop's input:
# the loop found nothing wrong and the boot reported "All systems nominal". The one
# state this check exists to catch was the one it could not see.
#
# The old shape also sent stderr to /dev/null and read the result through a process
# substitution, so a `docker compose ps` that failed outright produced an empty
# stream, no error anywhere, and the same clean bill of health. Now the command's own
# failure is a finding, its stderr reaches the journal, and — separately — an empty
# result is a finding too, because "no containers at all" is never a healthy boot.
PS_OUT=""
if ! PS_OUT="$(runuser -u carrein -- docker compose -f "${COMPOSE_DIR}/docker-compose.yml" ps --all --format '{{.Name}} {{.State}}')"; then
    fail "docker compose ps failed (stderr is in the journal above)"
    PS_OUT=""
fi

if [[ -z "${PS_OUT//[[:space:]]/}" ]]; then
    fail "docker compose ps listed no containers at all — the stack is not up"
else
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        name="${line%% *}"
        state="${line##* }"
        if [[ "$state" == "running" ]]; then
            RUNNING=$((RUNNING + 1))
        else
            NOT_RUNNING+=("${name}(${state})")
        fi
    done <<<"$PS_OUT"
fi

if [[ ${#NOT_RUNNING[@]} -gt 0 ]]; then
    fail "Containers not running: ${NOT_RUNNING[*]}"
fi

# Both counts come from the ONE read above rather than a second `ps -q`. Two reads
# could disagree — a container that dies between them makes the totals contradict
# each other in the same message — and the second read is the one that used to omit
# --all, so "26 running" was counted from a list that excluded anything stopped.
CONTAINER_TOTAL=$((RUNNING + ${#NOT_RUNNING[@]}))

# --- Step 4: Start all project timers and path units ---
#
# AFTER the stack, deliberately, and the order is load-bearing in one direction only.
#
# Every project timer sets Persistent=true, so starting one here fires its missed run
# IMMEDIATELY — and almost every one of those runs needs a container: the sweeps read
# spools their pipelines fill, changedetection.health `docker exec`s into the
# container, restic.backup dumps memoka's postgres. Started before `compose up`, a
# catch-up run raced the stack it depends on and failed for no reason but the order of
# these two blocks.
#
# The cost is that a boot which dies inside compose never arms the watchers at all.
# That is the safe direction: the unit fails, the inherited OnFailure= fires, and
# catallenya.service is not `active`, which is exactly what the watchdog's
# Freshness=boot reads. A silently mis-timed catch-up run has no such tell.
log "Starting project timers..."
for timer in "${TIMERS[@]}"; do
    if systemctl start "$timer" 2>/dev/null; then
        log "  Started $timer"
    else
        fail "Failed to start $timer"
    fi
done
if [[ ${#PATHS[@]} -gt 0 ]]; then
    log "Starting project path units..."
    for pathunit in "${PATHS[@]}"; do
        if systemctl start "$pathunit" 2>/dev/null; then
            log "  Started $pathunit"
        else
            fail "Failed to start $pathunit"
        fi
    done
fi

# --- Step 5: Notify via ntfy ---
TIMER_COUNT=$(systemctl list-timers "${TIMERS[@]}" --no-pager 2>/dev/null | grep -c "\.timer" || true)
# Path units have no list-timers equivalent, so ask systemd directly. Guarded on a
# non-empty array: a bare `systemctl is-active` with no arguments would report on
# every unit on the box.
PATH_COUNT=0
if [[ ${#PATHS[@]} -gt 0 ]]; then
    PATH_COUNT=$(systemctl is-active "${PATHS[@]}" 2>/dev/null | grep -c '^active$' || true)
fi

if [[ ${#ERRORS[@]} -eq 0 ]]; then
    TITLE="Boot Success"
    TAG="green_heart"
    BODY="All systems nominal.
Timers: ${TIMER_COUNT}/${#TIMERS[@]} active
Paths: ${PATH_COUNT}/${#PATHS[@]} active
Containers: ${RUNNING}/${CONTAINER_TOTAL} running"
else
    TITLE="Boot Failure"
    TAG="mending_heart"
    BODY="Errors:
$(printf '  - %s\n' "${ERRORS[@]}")
Timers: ${TIMER_COUNT}/${#TIMERS[@]} active
Paths: ${PATH_COUNT}/${#PATHS[@]} active
Containers: ${RUNNING}/${CONTAINER_TOTAL} running"
fi

# No priority argument: an empty one sends no Priority header, which is the same
# weight the explicit "default" used to ask for. Nothing in this repo shouts.
#
# Three attempts, because ntfy is a container THIS SCRIPT just started and may still
# be binding its port — the one publisher on the box with a legitimate reason to
# retry. The transport is silent on a successful publish, so anything it says (a
# curl error, or _ntfy_env declining to build a URL) is this attempt failing.
#
# An undelivered boot notification deliberately does NOT fail the unit: the failure
# would be reported through the same ntfy that just refused the message, and the
# watchdog covers this job by ActiveState (Freshness=boot) rather than by anything
# that arrives on the phone.
log "Sending ntfy notification..."
for attempt in 1 2 3; do
    send_out="$(notify "$TITLE" "" "$TAG" "$BODY" 2>&1)"
    if [[ -z "$send_out" ]]; then
        log "Notification sent (attempt ${attempt})"
        break
    fi
    log "Notification attempt ${attempt} failed: ${send_out}"
    if [[ "$attempt" -lt 3 ]]; then
        sleep 5
    else
        log "Notification UNDELIVERED after ${attempt} attempts — the boot report above is the only record"
    fi
done

# --- Exit ---
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    log "Boot completed with ${#ERRORS[@]} error(s)"
    exit 1
fi

log "Boot completed successfully"
