#!/bin/bash
set -euo pipefail

# Reproducible systemd setup for catallenya.
# Writes the boot orchestrator unit (must live on root fs),
# creates all timer/service symlinks, and enables everything.
# Idempotent — safe to re-run.

SYSTEMD_DIR="/etc/systemd/system"
REPO_DIR="/zpool/catallenya"

if [[ $EUID -ne 0 ]]; then
    echo "Error: must run as root (sudo bash systemd/install.sh)"
    exit 1
fi

# --- Write catallenya.service stub (cannot be symlinked — chicken-and-egg) ---
echo "Writing catallenya.service..."
cat > "${SYSTEMD_DIR}/catallenya.service" <<'EOF'
[Unit]
Description=Catallenya Boot Orchestrator
After=zfs-mount.service docker.service network-online.target
Requires=zfs-mount.service docker.service
Wants=network-online.target
ConditionPathIsMountPoint=/zpool

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/zpool/catallenya/systemd/catallenya.sh
StandardOutput=journal
StandardError=journal
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

# --- Create symlinks ---
declare -A SYMLINKS=(
    # Timers
    ["disk.timer"]="${REPO_DIR}/systemd/disk.timer"
    # changedetection cannot self-report a broken watch — every fetch error just sets
    # last_error and notifies nobody. This is the only thing that looks.
    ["changedetection.health.timer"]="${REPO_DIR}/systemd/changedetection.health.timer"
    # Not a schedule for the documents pipeline — that is event-driven. This is the
    # once-a-day look for a file type the path unit's globs cannot see.
    ["documents.backstop.timer"]="${REPO_DIR}/documents/systemd/documents.backstop.timer"
    ["immich.fix-rotations.timer"]="${REPO_DIR}/systemd/immich.fix-rotations.timer"
    ["restic.backup.timer"]="${REPO_DIR}/restic/backup/restic.backup.timer"
    ["restic.check-data.timer"]="${REPO_DIR}/restic/check/restic.check-data.timer"
    # The quarterly meta check retired 2026-08-07. check-subset runs the identical
    # structural pass monthly, so meta was strictly redundant; the yearly data check
    # stays because only a full read closes the n/12 partition gap.
    ["restic.check-subset.timer"]="${REPO_DIR}/restic/check/restic.check-subset.timer"
    ["restic.forget.timer"]="${REPO_DIR}/restic/forget/restic.forget.timer"
    ["restic.staleness.timer"]="${REPO_DIR}/restic/staleness/restic.staleness.timer"
    ["zpool.scrub.timer"]="${REPO_DIR}/systemd/zpool.scrub.timer"
    ["capture.sweep.timer"]="${REPO_DIR}/capture/systemd/capture.sweep.timer"
    ["documents.sweep.timer"]="${REPO_DIR}/documents/systemd/documents.sweep.timer"
    # Paths (event-triggered, not scheduled)
    ["capture.triage.path"]="${REPO_DIR}/capture/systemd/capture.triage.path"
    # documents is two path units and no timer: one watches the folder root for a
    # dropped document, the other watches for an approval marker the container wrote.
    # Nothing here is scheduled — a document is proposed when it arrives and filed
    # when you tap, not overnight.
    ["documents.triage.path"]="${REPO_DIR}/documents/systemd/documents.triage.path"
    ["documents.apply.path"]="${REPO_DIR}/documents/systemd/documents.apply.path"
    # Services
    ["disk.service"]="${REPO_DIR}/systemd/disk.service"
    ["changedetection.health.service"]="${REPO_DIR}/systemd/changedetection.health.service"
    ["documents.triage.service"]="${REPO_DIR}/documents/systemd/documents.triage.service"
    ["documents.apply.service"]="${REPO_DIR}/documents/systemd/documents.apply.service"
    ["documents.sweep.service"]="${REPO_DIR}/documents/systemd/documents.sweep.service"
    ["immich.fix-rotations.service"]="${REPO_DIR}/systemd/immich.fix-rotations.service"
    ["restic.backup.service"]="${REPO_DIR}/restic/backup/restic.backup.service"
    ["restic.check@.service"]="${REPO_DIR}/restic/check/restic.check@.service"
    ["restic.forget.service"]="${REPO_DIR}/restic/forget/restic.forget.service"
    ["restic.staleness.service"]="${REPO_DIR}/restic/staleness/restic.staleness.service"
    ["system-ntfy@.service"]="${REPO_DIR}/ntfy/system-ntfy@.service"
    ["zpool.scrub.service"]="${REPO_DIR}/systemd/zpool.scrub.service"
    ["capture.triage.service"]="${REPO_DIR}/capture/systemd/capture.triage.service"
    ["capture.sweep.service"]="${REPO_DIR}/capture/systemd/capture.sweep.service"
)

echo "Creating symlinks..."
for unit in "${!SYMLINKS[@]}"; do
    target="${SYMLINKS[$unit]}"
    link="${SYSTEMD_DIR}/${unit}"

    if [[ -L "$link" && "$(readlink "$link")" == "$target" ]]; then
        echo "  OK  ${unit} (already correct)"
    else
        ln -sf "$target" "$link"
        echo "  NEW ${unit} → ${target}"
    fi
done

# --- Prune symlinks for retired units ---
# This script created and repaired links but never removed them, so retiring a unit
# left its symlink behind pointing at a deleted file. That includes the enable links
# systemd writes under */.wants/, which `systemctl disable` can no longer clean once
# the unit file is gone — the disable fails with "not-found" and orphans the link.
# Two had accumulated by 2026-08-07 (documents.intake since July, check-meta that day)
# and both were invisible: nothing breaks, systemd just carries a ghost entry forever.
#
# Runs AFTER the creation loop on purpose, so anything just linked resolves and is
# safe by construction. Guard is deliberately narrow — a link is only removed if it
# points into the repo AND its target is gone.
#
# The mount check is not paranoia: every target lives on /zpool, so if ZFS is not
# mounted then EVERY project link looks dangling and this loop would delete the lot.
# install.sh is never run at boot (catallenya.service runs catallenya.sh, which does
# not call this), so that only happens if a human runs it on an unmounted pool — but
# a root-level rm loop should not have that shape at all.
if [[ ! -f "${REPO_DIR}/docker-compose.yml" ]]; then
    echo "Error: ${REPO_DIR} looks unmounted or wrong — refusing to prune symlinks"
    exit 1
fi

echo "Pruning symlinks for retired units..."
pruned=0
while IFS= read -r link; do
    target="$(readlink "$link")"
    [[ "$target" == "${REPO_DIR}"/* ]] || continue
    unit="$(basename "$link")"
    # Best-effort: the unit may still be loaded in memory from before its file went.
    systemctl stop "$unit" 2>/dev/null || true
    rm -f "$link"
    echo "  DEL ${link#"${SYSTEMD_DIR}"/} (target gone: ${target})"
    pruned=$((pruned + 1))
done < <(find "${SYSTEMD_DIR}" -maxdepth 2 -xtype l)
(( pruned == 0 )) && echo "  none"

# --- Reload and enable ---
echo "Reloading systemd daemon..."
systemctl daemon-reload

echo "Enabling catallenya.service..."
systemctl enable catallenya.service

# Derive the timer list from SYMLINKS so there's a single source of truth —
# add a service's timer to SYMLINKS above and it's enabled here automatically.
TIMERS=()
for unit in "${!SYMLINKS[@]}"; do
    [[ "$unit" == *.timer ]] && TIMERS+=("$unit")
done

# --now so a NEWLY added timer starts immediately rather than lying dormant until
# the next reboot. Existing timers are active only because catallenya.service
# starts them at boot; without --now, adding a timer here and not rebooting means
# its job silently never runs. (Caught 2026-07-25: capture.sweep.timer was enabled
# but inactive after install, so the pending-capture sweep would never have fired.)
echo "Enabling timers..."
for timer in "${TIMERS[@]}"; do
    systemctl enable --now "$timer"
    echo "  Enabled + started ${timer}"
done

# Same single-source-of-truth trick for .path units. These are event-triggered
# rather than scheduled, so they must also be STARTED — an enabled-but-unstarted
# path unit watches nothing until the next boot, and the pipeline would look
# installed while silently doing nothing.
PATHS=()
for unit in "${!SYMLINKS[@]}"; do
    [[ "$unit" == *.path ]] && PATHS+=("$unit")
done

if (( ${#PATHS[@]} )); then
    echo "Enabling path units..."
    for p in "${PATHS[@]}"; do
        systemctl enable --now "$p"
        echo "  Enabled + started ${p}"
    done
fi

echo ""
echo "Done. Summary:"
echo "  - catallenya.service written and enabled"
echo "  - ${#SYMLINKS[@]} symlinks created"
echo "  - ${#TIMERS[@]} timers enabled"
echo ""
echo "Verify with:"
echo "  systemctl status catallenya"
echo "  systemctl list-timers ${TIMERS[*]}"
