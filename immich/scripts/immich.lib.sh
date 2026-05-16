#!/bin/bash
# Shared helpers for immich/scripts/*.sh. Source this; do not execute.
#
# Provides:
#   imapi_load_key      — resolves the API key from env or file; sets IMMICH_API_KEY
#   imapi <METHOD> <path> [curl-args...]
#                       — issues an authenticated API request; prints the JSON
#                         response body to stdout. Returns non-zero on HTTP >= 400
#                         and prints the status + body to stderr.
#   imapi_require_cmd <cmd>...
#                       — exits 1 if any named command is missing on PATH.

set -euo pipefail

# shellcheck source=immich.conf
. "$(dirname "${BASH_SOURCE[0]}")/immich.conf"

imapi_require_cmd() {
  local missing=()
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (( ${#missing[@]} > 0 )); then
    echo "error: missing required command(s): ${missing[*]}" >&2
    return 1
  fi
}

imapi_load_key() {
  if [[ -n "${IMMICH_API_KEY:-}" ]]; then
    return 0
  fi
  if [[ -r "${IMMICH_API_KEY_FILE}" ]]; then
    IMMICH_API_KEY="$(tr -d '[:space:]' < "${IMMICH_API_KEY_FILE}")"
    export IMMICH_API_KEY
    if [[ -z "${IMMICH_API_KEY}" ]]; then
      echo "error: API key file is empty: ${IMMICH_API_KEY_FILE}" >&2
      return 1
    fi
    return 0
  fi
  echo "error: no API key found." >&2
  echo "  Set IMMICH_API_KEY env var, or create ${IMMICH_API_KEY_FILE} (chmod 600)." >&2
  echo "  Generate a key at: ${IMMICH_API_URL} → Account Settings → API Keys." >&2
  return 1
}

# imapi <METHOD> <path> [extra curl args...]
# On success: prints response body to stdout, returns 0.
# On HTTP >= 400 or transport error: prints status + body to stderr, returns 1.
imapi() {
  local method="$1"
  local path="$2"
  shift 2

  local url="${IMMICH_API_URL%/}${path}"
  local tmp_body
  tmp_body="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '${tmp_body}'" RETURN

  local http_code
  http_code="$(curl -sS \
    --max-time "${IMMICH_HTTP_TIMEOUT}" \
    -o "${tmp_body}" \
    -w '%{http_code}' \
    -X "${method}" \
    -H "Accept: application/json" \
    -H "x-api-key: ${IMMICH_API_KEY:-}" \
    "$@" \
    "${url}")" || {
      echo "error: curl transport failure to ${url}" >&2
      return 1
    }

  if [[ "${http_code}" -ge 400 ]]; then
    echo "error: ${method} ${path} → HTTP ${http_code}" >&2
    cat "${tmp_body}" >&2
    echo >&2
    return 1
  fi

  cat "${tmp_body}"
}
