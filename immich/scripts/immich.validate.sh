#!/bin/bash
# Validate connectivity and credentials against the Immich API.
# Read-only — performs no mutations.
#
# Exit codes:
#   0  all checks passed
#   1  a check failed (first failure aborts; stderr explains why)
#
# Usage:
#   bash immich/scripts/immich.validate.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=immich.lib.sh
. "${SCRIPT_DIR}/immich.lib.sh"

pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }
info() { printf '    %s\n' "$*"; }
step() { printf '\n[%d/%d] %s\n' "$1" "$TOTAL_STEPS" "$2"; }

TOTAL_STEPS=6

echo "Immich API validation — ${IMMICH_API_URL}"

# 1. Required commands -------------------------------------------------------
step 1 "Checking required commands"
imapi_require_cmd curl jq
pass "curl and jq present"

# 2. API key resolution ------------------------------------------------------
step 2 "Resolving API key"
# Capture origin BEFORE imapi_load_key, since it exports IMMICH_API_KEY either way.
if [[ -n "${IMMICH_API_KEY:-}" ]]; then
  key_source="\$IMMICH_API_KEY env var"
else
  key_source="${IMMICH_API_KEY_FILE}"
fi
imapi_load_key
info "source: ${key_source}"
pass "API key loaded (${#IMMICH_API_KEY} chars)"

# 3. Ping --------------------------------------------------------------------
step 3 "Server ping (GET /api/server/ping)"
ping_resp="$(imapi GET /api/server/ping)"
ping_val="$(echo "${ping_resp}" | jq -r '.res // empty')"
if [[ "${ping_val}" != "pong" ]]; then
  fail "unexpected ping response: ${ping_resp}"
  exit 1
fi
pass "server alive — res=pong"

# 4. Version -----------------------------------------------------------------
step 4 "Server version (GET /api/server/version)"
version_resp="$(imapi GET /api/server/version)"
ver_major="$(echo "${version_resp}" | jq -r '.major // empty')"
ver_minor="$(echo "${version_resp}" | jq -r '.minor // empty')"
ver_patch="$(echo "${version_resp}" | jq -r '.patch // empty')"
if [[ -z "${ver_major}" ]]; then
  fail "could not parse version: ${version_resp}"
  exit 1
fi
pass "version v${ver_major}.${ver_minor}.${ver_patch}"

# 5. Auth — current user -----------------------------------------------------
step 5 "API key auth (GET /api/users/me)"
me_resp="$(imapi GET /api/users/me)"
me_email="$(echo "${me_resp}" | jq -r '.email // empty')"
me_name="$(echo "${me_resp}" | jq -r '.name // empty')"
me_admin="$(echo "${me_resp}" | jq -r '.isAdmin // false')"
if [[ -z "${me_email}" ]]; then
  fail "could not parse user info: ${me_resp}"
  exit 1
fi
pass "authenticated as ${me_email} (${me_name})"
info "admin: ${me_admin}"

# 6. Read access — stats if admin, else minimal search -----------------------
step 6 "Library read access"
if [[ "${me_admin}" == "true" ]]; then
  if stats_resp="$(imapi GET /api/server/statistics)"; then
    photos="$(echo "${stats_resp}" | jq -r '.photos // 0')"
    videos="$(echo "${stats_resp}" | jq -r '.videos // 0')"
    usage_bytes="$(echo "${stats_resp}" | jq -r '.usage // 0')"
    usage_gib="$(awk -v b="${usage_bytes}" 'BEGIN{printf "%.2f", b/1073741824}')"
    pass "library stats: ${photos} photos, ${videos} videos, ${usage_gib} GiB"
  else
    fail "admin user but /api/server/statistics failed — see error above"
    exit 1
  fi
else
  # Non-admin path: prove search works by asking for one asset
  if search_resp="$(imapi POST /api/search/metadata \
        -H 'Content-Type: application/json' \
        --data '{"size":1,"page":1,"withExif":false}')"; then
    count="$(echo "${search_resp}" | jq -r '.assets.items | length // 0')"
    pass "search/metadata reachable (returned ${count} item)"
    info "note: server-wide statistics requires an admin API key"
  else
    fail "could not read library via /api/search/metadata — see error above"
    exit 1
  fi
fi

echo
echo "All checks passed."
