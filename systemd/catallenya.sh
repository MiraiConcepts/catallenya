#!/bin/bash
set -euo pipefail

# Boot orchestrator for catallenya
# Runs after ZFS mount + Docker are ready.
# Re-reads systemd unit files (symlinks into /zpool now resolve),
# starts project timers, brings up Docker Compose, and notifies via ntfy.

COMPOSE_DIR="/zpool/catallenya"
SYSTEMD_DIR="/etc/systemd/system"
LOG_TAG="catallenya-boot"

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
# after the daemon-reload above. capture.triage.path is what fires the screenshot
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

# --- Step 2: Start all project timers and path units ---
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

# --- Step 3: Bring up Docker Compose ---
log "Starting Docker Compose services..."
if ! runuser -u carrein -- docker compose -f "${COMPOSE_DIR}/docker-compose.yml" up -d 2>&1; then
    fail "docker compose up -d failed"
fi

# --- Step 4: Verify containers ---
log "Waiting 10s for containers to settle..."
sleep 10

log "Checking container states..."
NOT_RUNNING=()
while IFS= read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    state=$(echo "$line" | awk '{print $2}')
    if [[ "$state" != "running" ]]; then
        NOT_RUNNING+=("${name}(${state})")
    fi
done < <(runuser -u carrein -- docker compose -f "${COMPOSE_DIR}/docker-compose.yml" ps --format '{{.Name}} {{.State}}' 2>/dev/null)

if [[ ${#NOT_RUNNING[@]} -gt 0 ]]; then
    fail "Containers not running: ${NOT_RUNNING[*]}"
fi

# --- Step 5: Notify via ntfy ---
source "${COMPOSE_DIR}/.env"
NTFY_URL="https://${TAILNET_DOMAIN}.${TAILNET_DNS_NAME}:${NTFY_REVERSE_PROXY_PORT}"
TOPIC="boot"

TIMER_COUNT=$(systemctl list-timers "${TIMERS[@]}" --no-pager 2>/dev/null | grep -c "\.timer" || true)
# Path units have no list-timers equivalent, so ask systemd directly. Guarded on a
# non-empty array: a bare `systemctl is-active` with no arguments would report on
# every unit on the box.
PATH_COUNT=0
if [[ ${#PATHS[@]} -gt 0 ]]; then
    PATH_COUNT=$(systemctl is-active "${PATHS[@]}" 2>/dev/null | grep -c '^active$' || true)
fi
CONTAINER_TOTAL=$(runuser -u carrein -- docker compose -f "${COMPOSE_DIR}/docker-compose.yml" ps -q 2>/dev/null | wc -l)

if [[ ${#ERRORS[@]} -eq 0 ]]; then
    TITLE="Boot Success"
    TAG="green_heart"
    PRIORITY="default"
    BODY="All systems nominal.
Timers: ${TIMER_COUNT}/${#TIMERS[@]} active
Paths: ${PATH_COUNT}/${#PATHS[@]} active
Containers: ${CONTAINER_TOTAL} running"
else
    TITLE="Boot Failure"
    TAG="mending_heart"
    PRIORITY="high"
    BODY="Errors:
$(printf '  - %s\n' "${ERRORS[@]}")
Timers: ${TIMER_COUNT}/${#TIMERS[@]} active
Paths: ${PATH_COUNT}/${#PATHS[@]} active
Containers: ${CONTAINER_TOTAL} running"
fi

log "Sending ntfy notification..."
for attempt in 1 2 3; do
    if curl -sf \
        -H "Tags: ${TAG}" \
        -H "Title: ${TITLE}" \
        -H "Priority: ${PRIORITY}" \
        -d "${BODY}" \
        "${NTFY_URL}/${TOPIC}" >/dev/null 2>&1; then
        log "Notification sent (attempt ${attempt})"
        break
    fi
    log "Notification attempt ${attempt} failed, retrying in 5s..."
    sleep 5
done

# --- Exit ---
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    log "Boot completed with ${#ERRORS[@]} error(s)"
    exit 1
fi

log "Boot completed successfully"
