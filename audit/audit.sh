#!/bin/bash
set -euo pipefail

# --- Setup Log File ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs/$(date +%Y-%m-%d)"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/audit.log"

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

# ── Runtime Health ──────────────────────────────────────────────

echo "--- 1. Memory & Resource Usage ---"
docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}"
echo

echo "--- 2. OOM Kill Events ---"
echo "dmesg OOM:"
dmesg -T 2>/dev/null | grep -i "out of memory" | tail -5 || echo "  None found"
echo "Docker service OOM (last 7d):"
journalctl -u docker --since "7 days ago" 2>/dev/null | grep -i oom || echo "  None found"
echo

echo "--- 3. Container Health Status ---"
docker compose -f "${SCRIPT_DIR}/../docker-compose.yml" ps
echo

echo "--- 4. Recent Error Logs (24h) ---"
# Show top 20 errors/fatals/panics/exceptions
docker compose -f "${SCRIPT_DIR}/../docker-compose.yml" logs --since 24h 2>&1 | grep -iwE "error|fatal|panic|exception" | head -20 || echo "  No errors found in last 24h"
echo

# ── Hardening Drift Detection ──────────────────────────────────

echo "--- 5. Container Security Options ---"
FAIL=0
# Process substitution (not a pipe): a piped `while` runs in a subshell,
# so FAIL=1 set inside it would never reach this shell.
while read -r container; do
  cap_drop=$(docker inspect "$container" --format '{{.HostConfig.CapDrop}}')
  security_opt=$(docker inspect "$container" --format '{{.HostConfig.SecurityOpt}}')
  cap_add=$(docker inspect "$container" --format '{{.HostConfig.CapAdd}}')

  # Watchtower is exempt — needs full Docker socket access for self-update
  # and container lifecycle management. Hardening breaks its operation.
  if [[ "$container" == "watchtower" ]]; then
    echo "  ~ $container: exempt (requires Docker socket privileges)"
    continue
  fi

  # Every other container should have cap_drop ALL
  if [[ "$cap_drop" != *"ALL"* ]]; then
    echo "  ✗ $container: missing cap_drop ALL"
    FAIL=1
  else
    echo "  ✓ $container: cap_drop=ALL cap_add=${cap_add} security_opt=${security_opt}"
  fi
done < <(docker ps --format '{{.Names}}' | sort)
echo

echo "--- 6. Resource Limits ---"
docker ps --format '{{.Names}}' | sort | while read container; do
  mem_limit=$(docker inspect "$container" --format '{{.HostConfig.Memory}}')
  if [[ "$mem_limit" == "0" ]]; then
    echo "  ✗ $container: no memory limit set"
  else
    mem_mb=$((mem_limit / 1024 / 1024))
    echo "  ✓ $container: ${mem_mb}M"
  fi
done
echo

echo "--- 7. Sensitive File Permissions ---"
COMPOSE_DIR="${SCRIPT_DIR}/.."
declare -A FILE_PERMS=(
  ["${COMPOSE_DIR}/.env"]="600"
  ["${COMPOSE_DIR}/rclone/.rclone.conf"]="600"
  ["${COMPOSE_DIR}/watchtower/config.json"]="600"
  ["${COMPOSE_DIR}/radicale/config/users"]="644"  # readable by container UID 2999
)
for f in "${!FILE_PERMS[@]}"; do
  expected="${FILE_PERMS[$f]}"
  if [[ -f "$f" ]]; then
    perms=$(stat -c '%a' "$f")
    if [[ "$perms" == "$expected" ]]; then
      echo "  ✓ $(basename "$f"): $perms"
    else
      echo "  ✗ $(basename "$f"): $perms (expected $expected)"
    fi
  else
    echo "  ? $(basename "$f"): file not found"
  fi
done
echo

echo "--- 8. Hardcoded Secrets in Tracked Files ---"
# Check for hardcoded tailnet name in tracked files
if grep -r "kamori-mulley.ts.net" "${COMPOSE_DIR}/docker-compose.yml" "${COMPOSE_DIR}/caddy/Caddyfile" > /dev/null 2>&1; then
  echo "  ✗ Hardcoded tailnet name found in tracked files"
else
  echo "  ✓ No hardcoded tailnet name in tracked files"
fi
echo

# ── Informational ──────────────────────────────────────────────

echo "--- 9. Docker Socket Exposure (in compose) ---"
docker compose -f "${SCRIPT_DIR}/../docker-compose.yml" config | grep -B 2 -A 2 "docker.sock" || echo "  Not found in compose config"
echo

echo "--- 10. Environment Variable Secrets ---"
docker ps --format '{{.Names}}' | sort | while read container; do
  # Skip known false positives
  if [[ "$container" == "flame" ]]; then
    echo "Container: $container"
    echo "   (Skipping known false positive: PASSWORD env var)"
    continue
  fi
  echo "Container: $container"
  docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -iE 'password|secret|key|token|psk' || echo "   No obvious secrets found"
done
echo

echo "--- 11. Compose File Validation ---"
if docker compose -f "${SCRIPT_DIR}/../docker-compose.yml" config > /dev/null; then
  echo "  ✓ Syntax valid"
else
  echo "  ✗ Syntax errors present"
fi
docker compose -f "${SCRIPT_DIR}/../docker-compose.yml" config 2>&1 | grep -i "deprecat" || echo "  No deprecation warnings"
echo

echo "--- 12. Docker Volume Inventory ---"
docker volume ls --format "table {{.Name}}\t{{.Driver}}"
echo

if [[ "$FAIL" -ne 0 ]]; then
  echo "=== Audit Complete — HARDENING DRIFT FOUND ==="
  echo "Audit FAILED — see $LOG_FILE" >&3
  exit 1
fi
echo "=== Audit Complete ==="
