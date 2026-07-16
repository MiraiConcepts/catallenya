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
    ["documents.intake.timer"]="${REPO_DIR}/systemd/documents.intake.timer"
    ["immich.fix-rotations.timer"]="${REPO_DIR}/systemd/immich.fix-rotations.timer"
    ["restic.backup.timer"]="${REPO_DIR}/restic/backup/restic.backup.timer"
    ["restic.check-data.timer"]="${REPO_DIR}/restic/check/restic.check-data.timer"
    ["restic.check-meta.timer"]="${REPO_DIR}/restic/check/restic.check-meta.timer"
    ["restic.forget.timer"]="${REPO_DIR}/restic/forget/restic.forget.timer"
    ["zpool.scrub.timer"]="${REPO_DIR}/systemd/zpool.scrub.timer"
    # Services
    ["disk.service"]="${REPO_DIR}/systemd/disk.service"
    ["documents.intake.service"]="${REPO_DIR}/systemd/documents.intake.service"
    ["immich.fix-rotations.service"]="${REPO_DIR}/systemd/immich.fix-rotations.service"
    ["restic.backup.service"]="${REPO_DIR}/restic/backup/restic.backup.service"
    ["restic.check@.service"]="${REPO_DIR}/restic/check/restic.check@.service"
    ["restic.forget.service"]="${REPO_DIR}/restic/forget/restic.forget.service"
    ["system-ntfy@.service"]="${REPO_DIR}/ntfy/system-ntfy@.service"
    ["zpool.scrub.service"]="${REPO_DIR}/systemd/zpool.scrub.service"
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

echo "Enabling timers..."
for timer in "${TIMERS[@]}"; do
    systemctl enable "$timer"
    echo "  Enabled ${timer}"
done

echo ""
echo "Done. Summary:"
echo "  - catallenya.service written and enabled"
echo "  - ${#SYMLINKS[@]} symlinks created"
echo "  - ${#TIMERS[@]} timers enabled"
echo ""
echo "Verify with:"
echo "  systemctl status catallenya"
echo "  systemctl list-timers ${TIMERS[*]}"
