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
# The point of this check is WHICH variables look secret-shaped, never their values.
# It used to pipe `docker inspect` straight into grep, and grep prints the whole
# matching line — so every run wrote live credentials into $LOG_FILE (mode 0664,
# world-readable), including ZIPLINE_CORE_SECRET, MEMOKA_DB_PASSWORD and two
# POSTGRES_PASSWORDs. Seven such logs existed going back to 2025-11-10. Masked
# 2026-08-10.
#
# The masking sed CANNOT go on the end of the existing pipeline: `|| echo "No
# obvious secrets found"` fires on GREP's exit status, and sed always exits 0, so
# appending it would silently kill that branch for every container. Capture the
# result first, then decide — same output, exit codes intact.
docker ps --format '{{.Names}}' | sort | while read container; do
  echo "Container: $container"
  # `|| true` is load-bearing: this script runs under `set -euo pipefail`, and a
  # container with no matching vars makes grep exit 1, which under pipefail fails
  # the whole substitution and would kill the run mid-section. The original code
  # survived only because `|| echo ...` consumed grep's status.
  found=$(docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | grep -iE 'password|secret|key|token|psk' \
    | sed -E 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\1=<set>/' || true)
  if [[ -n "$found" ]]; then
    echo "$found"
  else
    echo "   No obvious secrets found"
  fi
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

# ── Pipeline Convention Drift (see docs/intake-playbook.md) ─────

echo "--- 13. OnFailure topics match the system-ntfy allowlist ---"
# system-ntfy@<topic>.<job> derives its ntfy topic from the unit name and refuses
# anything not in its case allowlist — so a unit wiring OnFailure= to a topic
# missing there has alerts that die silently ("Unknown service type", and systemd
# reports a failed OnFailure= handler nowhere). That was live for four units until
# 2026-08-01; this check keeps the allowlist and the units in step, BOTH ways: an
# allowlisted topic no unit wires anymore is a stale entry to remove.
ALLOWED=$(sed -n 's/^ *\([a-z][a-z|]*\)) ;;$/\1/p' "${COMPOSE_DIR}/ntfy/system-ntfy.sh" | tr '|' '\n')
WIRED=$(git -C "$COMPOSE_DIR" ls-files '*.service' '*.timer' '*.path' \
  | while read -r u; do
      grep -oP '^OnFailure=system-ntfy@\K[a-z-]+' "${COMPOSE_DIR}/${u}" 2>/dev/null || true
    done | sort -u)
if [[ -z "$ALLOWED" ]]; then
  echo "  ✗ could not parse the allowlist out of ntfy/system-ntfy.sh"
  FAIL=1
fi
for t in $WIRED; do
  if grep -qx "$t" <<<"$ALLOWED"; then
    echo "  ✓ topic '$t' is wired and allowlisted"
  else
    echo "  ✗ topic '$t' has OnFailure= units but is NOT in the system-ntfy.sh allowlist — those alerts die silently"
    FAIL=1
  fi
done
for t in $ALLOWED; do
  if ! grep -qx "$t" <<<"$WIRED"; then
    echo "  ✗ topic '$t' is allowlisted but no tracked unit wires OnFailure= to it — stale entry"
    FAIL=1
  fi
done
echo

echo "--- 14. Every pipeline has an offline test suite ---"
# A pipeline is a top-level directory that ships systemd units. ai/ carries the
# shared transport suite and is asserted alongside.
PIPELINES=$(git -C "$COMPOSE_DIR" ls-files | grep -oP '^[^/]+(?=/systemd/)' | sort -u)
for d in $PIPELINES ai; do
  if git -C "$COMPOSE_DIR" ls-files --error-unmatch "${d}/tests/run.sh" >/dev/null 2>&1; then
    echo "  ✓ ${d}/tests/run.sh"
  else
    echo "  ✗ ${d}/ has no tracked tests/run.sh"
    FAIL=1
  fi
done
echo

echo "--- 15. Installed units resolve to git-tracked files ---"
# Every project unit in /etc/systemd/system is a symlink into the repo. A dangling
# link means a move happened without install.sh; a target that exists but is not
# tracked means the .gitignore allowlist missed it — green CI, file never
# committed, unit unreproducible from the repo. Both were near-misses in the
# 2026-08-01 move.
# maxdepth 2, not just the top level: `systemctl enable` writes its links into
# timers.target.wants/ and paths.target.wants/ one directory down, and those are the
# ones `systemctl disable` cannot clean after a unit file is deleted. Scanning only
# the top level passed green on 2026-08-07 while two dangling enable links sat
# underneath — documents.intake's since July. install.sh now prunes them; this is
# what notices if it ever stops.
while IFS= read -r link; do
  target=$(readlink "$link")
  [[ "$target" == /zpool/catallenya/* ]] || continue
  unit=${link#/etc/systemd/system/}
  if [[ ! -e "$target" ]]; then
    echo "  ✗ ${unit}: symlink dangles (${target})"
    FAIL=1
  elif ! git -C "$COMPOSE_DIR" ls-files --error-unmatch "${target#/zpool/catallenya/}" >/dev/null 2>&1; then
    echo "  ✗ ${unit}: target exists but is NOT git-tracked (${target})"
    FAIL=1
  else
    echo "  ✓ ${unit}"
  fi
done < <(find /etc/systemd/system -maxdepth 2 -type l | sort)
echo

echo "--- 16. No pipeline code is silently gitignored ---"
# The deny-by-default .gitignore means a forgotten allowlist line fails SILENTLY:
# the file works locally, CI is green, and it simply never reaches the repo. Any
# code-shaped file sitting ignored under a pipeline directory is that mistake.
# Runtime state (data/, intake-state/) is ignored on purpose and excluded here.
IGNORED_CODE=$(git -C "$COMPOSE_DIR" status --ignored --porcelain $PIPELINES ai 2>/dev/null \
  | sed -n 's/^!! //p' \
  | grep -vE '/(data|intake-state)/|__pycache__|\.pyc$' \
  | grep -E '\.(sh|ts|py|json|service|timer|path)$|Dockerfile$' || true)
if [[ -n "$IGNORED_CODE" ]]; then
  while read -r f; do
    echo "  ✗ ${f} is on disk but gitignored — add an allowlist line or remove it"
  done <<<"$IGNORED_CODE"
  FAIL=1
else
  echo "  ✓ nothing code-shaped is sitting ignored"
fi
echo

if [[ "$FAIL" -ne 0 ]]; then
  echo "=== Audit Complete — DRIFT FOUND ==="
  echo "Audit FAILED — see $LOG_FILE" >&3
  exit 1
fi
echo "=== Audit Complete ==="
