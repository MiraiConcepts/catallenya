#!/bin/bash
set -euo pipefail

# Boot orchestrator for catallenya
# Runs after ZFS mount + Docker are ready.
# Re-reads systemd unit files (symlinks into /zpool now resolve),
# starts project timers, brings up Docker Compose, and notifies via ntfy.

COMPOSE_DIR="/zpool/catallenya"
LOG_TAG="catallenya-boot"

TIMERS=(
    disk.timer
    restic.backup.timer
    restic.check-data.timer
    restic.check-meta.timer
    restic.forget.timer
    zpool.scrub.timer
)

log() { echo "[${LOG_TAG}] $*"; }
fail() { log "FAIL: $*"; ERRORS+=("$*"); }

ERRORS=()

# --- Step 1: Reload systemd so symlinked units resolve ---
log "Reloading systemd daemon..."
if ! systemctl daemon-reload; then
    fail "daemon-reload failed"
fi

# --- Step 2: Start all project timers ---
log "Starting project timers..."
for timer in "${TIMERS[@]}"; do
    if systemctl start "$timer" 2>/dev/null; then
        log "  Started $timer"
    else
        fail "Failed to start $timer"
    fi
done

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
CONTAINER_TOTAL=$(runuser -u carrein -- docker compose -f "${COMPOSE_DIR}/docker-compose.yml" ps -q 2>/dev/null | wc -l)

if [[ ${#ERRORS[@]} -eq 0 ]]; then
    TITLE="Boot Success"
    TAG="green_heart"
    PRIORITY="default"
    BODY="All systems nominal.
Timers: ${TIMER_COUNT}/${#TIMERS[@]} active
Containers: ${CONTAINER_TOTAL} running"
else
    TITLE="Boot Failure"
    TAG="mending_heart"
    PRIORITY="high"
    BODY="Errors:
$(printf '  - %s\n' "${ERRORS[@]}")
Timers: ${TIMER_COUNT}/${#TIMERS[@]} active
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
