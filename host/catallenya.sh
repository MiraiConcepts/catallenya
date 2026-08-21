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
# NTFY_MARKDOWN is GONE (2026-08-21). It was `no` here because the body is a built
# report of counts and error strings, never authored as Markdown. body_list() and
# body_fact() escape every line they render, which is what made the opt-out
# unnecessary — escaping in one place is what makes rendering safe everywhere.
# shellcheck disable=SC2034  # read by ntfy.lib.sh, sourced below
NTFY_TOPIC="host"

# A STABLE SEQUENCE ID, so a condition that persists is ONE message that keeps being
# replaced rather than a pile. A box that fails to come up cleanly, is power-cycled and fails again should read as
# one unresolved boot rather than as two.
#
# It does NOT self-clear when the condition goes away. A fault has no buttons, and a
# notification without buttons is never withdrawn by the system: an absent message is
# ambiguous — fixed, mis-swiped, or never sent — and a stale one is not. See
# ntfy/MESSAGES.md.
BOOT_NTFY_ID="boot-failed"
# shellcheck source=/zpool/catallenya/ntfy/ntfy.lib.sh
source "/zpool/catallenya/ntfy/ntfy.lib.sh"

log() { echo "[${LOG_TAG}] $*"; }
# An error is a BODY ITEM, so it may carry a detail after a TAB — that is the shape
# body_list() renders indented beneath the name. The journal flattens the tab, because
# a log line is read in a terminal rather than by a markdown renderer.
fail() { log "FAIL: ${*//$'\t'/ }"; ERRORS+=("$*"); }

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
    fail "No project timers found under ${SYSTEMD_DIR}"$'\t'"Expected: symlinks into ${COMPOSE_DIR}"
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
    fail "docker compose ps failed"$'\t'"Reason: stderr is in the journal above"
    PS_OUT=""
fi

if [[ -z "${PS_OUT//[[:space:]]/}" ]]; then
    fail "The stack is not up"$'\t'"Reason: docker compose ps listed no containers at all"
else
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        name="${line%% *}"
        state="${line##* }"
        if [[ "$state" == "running" ]]; then
            RUNNING=$((RUNNING + 1))
        else
            NOT_RUNNING+=("${name}"$'\t'"State: ${state}")
        fi
    done <<<"$PS_OUT"
fi

# ONE FINDING PER CONTAINER, not one line listing them all. `Containers not running:
# a(exited) b(exited) c(created)` was a comma-joined run in a body that now numbers its
# items, and the numbers are what let you check a list against the count in the title.
if [[ ${#NOT_RUNNING[@]} -gt 0 ]]; then
    for entry in "${NOT_RUNNING[@]}"; do fail "$entry"; done
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

# SILENT ON SUCCESS since 2026-08-20, matching every other job on the box. This was
# the only notification in the repo that fired on success unconditionally.
#
# The consequence is real and was accepted deliberately: this host does NOT auto-power
# on when mains returns, so after a cut, silence no longer distinguishes "came back
# clean" from "still dark". Nothing else changes — the watchdog still covers this job
# by ActiveState (Freshness=boot), which does not depend on a notification arriving.
NOTIFY=1
if [[ ${#ERRORS[@]} -eq 0 ]]; then
    NOTIFY=0
    log "Boot clean: ${TIMER_COUNT}/${#TIMERS[@]} timers, ${PATH_COUNT}/${#PATHS[@]} paths, ${RUNNING}/${CONTAINER_TOTAL} containers — not notifying"
fi

# `Boot: 2 Containers Down`, not `Boot Failure`. The subject is `Boot` and not the
# topic — this publishes to `host`, which also carries the watchdog and rerouted
# alerts — and the state carries the count, which is the fact the old literal made you
# open the notification to learn.
DOWN=$(( CONTAINER_TOTAL - RUNNING ))
if (( DOWN > 0 )); then
    TITLE="$(title_state Boot "${DOWN} Container$( (( DOWN == 1 )) || printf s ) Down")"
else
    # Errors that are not a container: a timer that would not start, a failed
    # daemon-reload. Counting them keeps the state slot honest rather than reporting
    # zero containers down on a run that plainly failed.
    TITLE="$(title_state Boot "${#ERRORS[@]} Error$( (( ${#ERRORS[@]} == 1 )) || printf s )")"
fi
# Findings as ITEMS, then the run's counts as FACTS. The `Errors:` heading is gone —
# the title already says how many, and a heading above a numbered list says it twice.
#
# Facts are self-describing and carry no stub label: `▪ 24/26 containers running`,
# never `▪ Containers: 24/26`. A fact stands alone, so it has to describe itself,
# where a detail can lean on the item above it. See ntfy/MESSAGES.md § 3.
BODY="$(body_join \
    "$(body_list "${ERRORS[@]}")" \
    "$(body_fact \
        "${RUNNING}/${CONTAINER_TOTAL} containers running" \
        "${TIMER_COUNT}/${#TIMERS[@]} timers active" \
        "${PATH_COUNT}/${#PATHS[@]} paths active")")"

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
if (( NOTIFY )); then
log "Sending ntfy notification..."
for attempt in 1 2 3; do
    send_out="$(notify_fault "$TITLE" "$BODY" "$BOOT_NTFY_ID" 2>&1)"
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
fi

# --- Exit ---
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    log "Boot completed with ${#ERRORS[@]} error(s)"
    exit 1
fi

log "Boot completed successfully"
