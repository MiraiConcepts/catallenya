#!/bin/bash
set -euo pipefail

# --- Setup Log File ---
LOG_FILE="logs/audit-$(date +%Y-%m-%d).log"

# Save original stdout to fd 3 so we can still print to terminal
exec 3>&1

# Redirect stdout (fd 1) and stderr (fd 2) to the log file
exec > "$LOG_FILE" 2>&1
# --- End of Log Setup ---

# Announce to the *original* stdout (fd 3) where the log is
echo "Audit log being written to: $LOG_FILE" >&3

# --- Start of Audit ---
# All subsequent 'echo' commands will go to the $LOG_FILE

echo "=== Docker Security Audit - $(date) ==="
echo

echo "--- 1. Memory & Resource Usage ---"
docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}"
echo

echo "--- 2. OOM Kill Events ---"
echo "dmesg OOM:"
sudo dmesg -T | grep -i "out of memory" | tail -5 || echo "  None found"
echo "Docker service OOM (last 7d):"
sudo journalctl -u docker --since "7 days ago" | grep -i oom || echo "  None found"
echo

echo "--- 3. Container Security Options ---"
docker ps --format '{{.Names}}' | while read container; do
  if [[ "$container" == "archivebox_scheduler" ]]; then
    echo "  (Skipping archivebox_scheduler)"
    continue
  fi
  echo "Container: $container"
  docker inspect "$container" --format '   SecurityOpt: {{.HostConfig.SecurityOpt}}'
  docker inspect "$container" --format '   CapDrop: {{.HostConfig.CapDrop}}'
done
echo

echo "--- 4. Container Health Status ---"
docker compose ps
echo

echo "--- 5. Docker Socket Exposure (in compose) ---"
docker compose config | grep -B 2 -A 2 "docker.sock" || echo "  Not found in compose config"
echo

echo "--- 6. Environment Variable Secrets ---"
docker ps --format '{{.Names}}' | while read container; do
  # Add an exception for the 'flame' container
  if [[ "$container" == "flame" ]]; then
    echo "Container: $container"
    echo "   (Skipping known false positive: PASSWORD env var)"
    continue
  fi
  echo "Container: $container"
  # Grep for common secret keywords.
  docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -iE 'password|secret|key|token|psk' || echo "   No obvious secrets found"
done
echo

echo "--- 7. Read-Only Mounts ---"
docker ps --format '{{.Names}}' | while read container; do
  echo "Container: $container"
  # Use '{{if not .RW}}' to find read-only mounts
  mounts=$(docker inspect "$container" --format '{{range .Mounts}}{{if not .RW}}   {{.Destination}} (ro)
{{end}}{{end}}')
  if [ -n "$mounts" ]; then
    echo -e "$mounts" | sed '/^$/d' # Print mounts and remove blank lines
  else
    echo "   No read-only mounts."
  fi
done
echo

echo "--- 8. Network Isolation ---"
# Grep for non-default networks. Add '|| true' to prevent pipefail if none exist.
docker network ls --format '{{.Name}}' | (grep -v "bridge\|host\|none" || true) | while read network; do
  echo "Network: $network"
  docker network inspect "$network" --format '   Internal: {{.Internal}}   Containers: {{len .Containers}}'
done
echo

echo "--- 9. Exposed Port Review (in compose) ---"
docker compose config | grep -B 1 -A 1 '"ports":' || echo "  No 'ports' section found in compose config"
echo

echo "--- 10. Compose File Validation ---"
if docker compose config > /dev/null; then
  echo "  ✓ Syntax valid"
else
  echo "  ✗ Syntax errors present"
fi
# Show deprecation warnings
docker compose config 2>&1 | grep -i "deprecat" || echo "  No deprecation warnings"
echo

echo "--- 11. Recent Error Logs (24h) ---"
# Show top 20 errors/fatals/panics/exceptions
docker compose logs --since 24h 2>&1 | grep -iwE "error|fatal|panic|exception" | head -20 || echo "  No errors found in last 24h"
echo

echo "--- 12. Volume Backup Status ---"
docker volume ls --format "table {{.Name}}\t{{.Driver}}"
echo

echo "=== Audit Complete ==="