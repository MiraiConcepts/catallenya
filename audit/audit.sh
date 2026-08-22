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

echo "--- 13. Every job's alerts reach a subscribed ntfy topic ---"
# Rewritten when the job factory landed. This used to parse a `case` allowlist out
# of system-ntfy.sh and cross-check it against OnFailure= lines in unit files.
# Neither side of that exists now: OnFailure= is inherited from
# systemd/policy/10-base.conf so no unit declares it, and the allowlist is derived
# from whether a unit's FragmentPath is under the repo.
#
# What still cannot be derived is whether a PHONE is subscribed, because ntfy
# accepts a publish to any topic with a 200 OK and drops it if nobody listens. So
# system-ntfy.sh keeps a SUBSCRIBED list and ROUTES an unknown topic to
# HOST_TOPIC rather than refusing it — refusing guarantees the alert is lost,
# routing guarantees it is delivered.
#
# That makes the old failure mode impossible and leaves two real ones, which is
# what this now checks.
SNTFY="${COMPOSE_DIR}/ntfy/system-ntfy.sh"
SUBSCRIBED=$(sed -n 's/^SUBSCRIBED="\(.*\)"$/\1/p' "$SNTFY" | sed 's/\${HOST_TOPIC}//' )
HOST_TOPIC=$(sed -n 's/^HOST_TOPIC="\(.*\)"$/\1/p' "$SNTFY")

if [[ -z "$SUBSCRIBED" || -z "$HOST_TOPIC" ]]; then
  echo "  ✗ could not parse SUBSCRIBED / HOST_TOPIC out of ntfy/system-ntfy.sh"
  FAIL=1
else
  # 1. The fallback must itself be subscribed, or routing is a black hole and every
  #    alert it catches is lost — the exact failure this design removes elsewhere.
  if grep -qw "$HOST_TOPIC" <<<"$SUBSCRIBED $HOST_TOPIC"; then
    echo "  ✓ fallback topic '${HOST_TOPIC}' is itself subscribed"
  else
    echo "  ✗ fallback topic '${HOST_TOPIC}' is NOT in SUBSCRIBED — routed alerts go nowhere"
    FAIL=1
  fi

  # 2. Report which jobs route rather than publish direct. Not a failure — it is
  #    correct behaviour — but a growing list means the SUBSCRIBED set has drifted
  #    behind the fleet, and every routed alert lands on a channel shared with
  #    others rather than its own.
  ROUTED=0
  while read -r u; do
    grep -q '^Class=' "${COMPOSE_DIR}/${u}" 2>/dev/null || continue
    n=$(basename "$u"); n="${n%.service}"
    t="${n%%.*}"
    if ! grep -qw "$t" <<<"$SUBSCRIBED $HOST_TOPIC"; then
      echo "  · '${n}' derives topic '${t}' (unsubscribed) → routed to '${HOST_TOPIC}'"
      ROUTED=$((ROUTED + 1))
    fi
  done < <(git -C "$COMPOSE_DIR" ls-files '*.service')
  (( ROUTED == 0 )) && echo "  ✓ every job's derived topic is directly subscribed"
fi
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

echo "--- 17. The tracked git hooks are installed ---"
# .git/hooks/ is never tracked by git, so every hook here exists twice: a tracked
# master that survives a rebuild, and an installed copy that actually runs. The
# installed one can silently go missing — most plausibly after a rebuild-and-
# restore, when the corpus the secret guard protects has just been put back and
# the guard has not. Both are reported because they fail differently:
#
#   pre-commit  the second lock on secrets, and the only one acting BEFORE a
#               push. This repo is public and force-pushes to five mirrors, so
#               CI cannot help — it runs after the push, which is after the leak.
#   pre-push    runs ci/shellcheck.sh, the same check CI runs. Losing it costs a
#               round trip, not a secret, so it is the less severe of the two —
#               but a check believed present and absent is its own fault.
#
# core.hooksPath wins over .git/hooks when set, so ask git rather than assume.
HOOKS_DIR=$(git -C "$COMPOSE_DIR" config --get core.hooksPath || true)
if [[ -z "$HOOKS_DIR" ]]; then
  HOOKS_DIR="$(git -C "$COMPOSE_DIR" rev-parse --git-common-dir)/hooks"
fi
[[ "$HOOKS_DIR" != /* ]] && HOOKS_DIR="${COMPOSE_DIR}/${HOOKS_DIR}"
for HOOK_ENTRY in "audit/pre-commit:pre-commit" "ci/pre-push:pre-push"; do
  MASTER_REL="${HOOK_ENTRY%%:*}"
  HOOK_NAME="${HOOK_ENTRY#*:}"
  INSTALLED_HOOK="$(realpath -m "${HOOKS_DIR}/${HOOK_NAME}")"
  MASTER_HOOK="${COMPOSE_DIR}/${MASTER_REL}"
  if [[ ! -f "$INSTALLED_HOOK" ]]; then
    echo "  ✗ no ${HOOK_NAME} hook at ${INSTALLED_HOOK}"
    echo "    install: bash audit/install-hooks.sh"
    FAIL=1
  elif [[ ! -x "$INSTALLED_HOOK" ]]; then
    # A hook that is present but not executable is not run, and git says nothing.
    echo "  ✗ ${INSTALLED_HOOK} is not executable — git will skip it silently"
    FAIL=1
  elif ! cmp -s "$INSTALLED_HOOK" "$MASTER_HOOK"; then
    echo "  ✗ installed ${HOOK_NAME} hook differs from ${MASTER_REL}"
    echo "    reinstall: bash audit/install-hooks.sh"
    FAIL=1
  else
    echo "  ✓ ${HOOK_NAME} installed and matches ${MASTER_REL}"
  fi
done
echo

if [[ "$FAIL" -ne 0 ]]; then
  echo "=== Audit Complete — DRIFT FOUND ==="
  echo "Audit FAILED — see $LOG_FILE" >&3
  exit 1
fi
echo "=== Audit Complete ==="
