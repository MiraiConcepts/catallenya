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
    ["immich.fix-rotations.timer"]="${REPO_DIR}/systemd/immich.fix-rotations.timer"
    ["restic.backup.timer"]="${REPO_DIR}/restic/backup/restic.backup.timer"
    ["restic.check-data.timer"]="${REPO_DIR}/restic/check/restic.check-data.timer"
    ["restic.check-meta.timer"]="${REPO_DIR}/restic/check/restic.check-meta.timer"
    ["restic.forget.timer"]="${REPO_DIR}/restic/forget/restic.forget.timer"
    ["zpool.scrub.timer"]="${REPO_DIR}/systemd/zpool.scrub.timer"
    ["capture.sweep.timer"]="${REPO_DIR}/capture/systemd/capture.sweep.timer"
    # Paths (event-triggered, not scheduled)
    ["capture.triage.path"]="${REPO_DIR}/capture/systemd/capture.triage.path"
    # documents is two path units and no timer: one watches the folder root for a
    # dropped document, the other watches for an approval marker the container wrote.
    # Nothing here is scheduled — a document is proposed when it arrives and filed
    # when you tap, not overnight.
    ["documents.triage.path"]="${REPO_DIR}/systemd/documents.triage.path"
    ["documents.apply.path"]="${REPO_DIR}/systemd/documents.apply.path"
    # Services
    ["disk.service"]="${REPO_DIR}/systemd/disk.service"
    ["documents.triage.service"]="${REPO_DIR}/systemd/documents.triage.service"
    ["documents.apply.service"]="${REPO_DIR}/systemd/documents.apply.service"
    ["immich.fix-rotations.service"]="${REPO_DIR}/systemd/immich.fix-rotations.service"
    ["restic.backup.service"]="${REPO_DIR}/restic/backup/restic.backup.service"
    ["restic.check@.service"]="${REPO_DIR}/restic/check/restic.check@.service"
    ["restic.forget.service"]="${REPO_DIR}/restic/forget/restic.forget.service"
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
