#!/usr/bin/env bash
# shellcheck disable=SC2034  # config vars are consumed by the scripts that source this
# The shared Syncthing quiet gate. Sourced, never executed.
#
# Two pipelines drop work into the SAME synced folder — pigeonhole watches
# master/documents, liquidroom watches master/liquidroom — and both must answer the
# same question before they touch anything: has Syncthing finished with this file?
# Acting mid-transfer classifies a truncated document or hands the separator half a
# FLAC, and a move INSIDE a synced folder propagates to every peer, so a bad move is
# never local.
#
# WHY IT EXISTS. This was two byte-identical copies — st_apikey, st_api_base,
# st_folder_idle, the config path, the folder id, the test seam — in
# pigeonhole.lib.sh and liquidroom.lib.sh, differing in exactly one thing: which
# directory the .tmp glob looked at. That difference is now an argument. Copies of
# this size drift the way ntfy.lib.sh's four notify()s drifted: silently, one at a
# time, and only in the copy nobody revisited. The folder id in particular is a
# value that has to change in both places on the day Syncthing is reconfigured, and
# nothing would have said which copy was missed.
#
# WHY HERE AND NOT IN EITHER PIPELINE. Neither owns Syncthing; both are its
# customers, and the pipeline that happened to be written first is not a home for a
# fact about the sync daemon. Same boundary the ntfy transport draws — the sink owns
# it — and the same reason liquidroom stopped sourcing the AI layer to reach two
# functions about notifications.
#
# CONTRACT for anything sourcing this file:
#   - Pass the directory you actually watch to syncthing_quiet(). It is the only
#     per-consumer value left.
#   - curl, jq and grep -P must exist. Assert that in the entrypoint script, not
#     here.
#   - Source this near the TOP of your own lib, before your own log()/die(). Both
#     definitions below are guarded, so yours win and stay authoritative.
#   - Do NOT source the ntfy transport to get here and do not expect it: this gate
#     publishes nothing. It reads .env with its own three-key extractor for that
#     reason (see _st_env).

declare -F log >/dev/null || log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
declare -F die >/dev/null || die() { log "FATAL: $*"; exit 1; }

# The config dir is carrein:carrein 0700 — readable as ourselves, no elevation.
SYNCTHING_CONFIG="/zpool/catallenya/syncthing/data/config/config.xml"
# master/documents and master/liquidroom both sit INSIDE the "master" folder, so one
# folder id answers for both pipelines. It is here, once, for the same reason the
# rest of this file is.
SYNCTHING_FOLDER_ID="3j1oy-9cefl"   # label "master"

# How long a caller should wait for the folder to settle before giving up, and how
# often to ask. Giving up is a RETRY, not a loss: both consumers are driven by .path
# units that re-fire while their glob still matches, so the run that walks away
# leaves the work exactly where the next fire will find it. Waiting in-process turns
# what would be a spin into one sleeping run, and each consumer's flock keeps the
# spins from overlapping.
QUIET_WAIT_S="${QUIET_WAIT_S:-180}"
QUIET_POLL_S=15

# Only the three keys this gate needs, extracted rather than sourced. `source` on
# the root .env pulls in every database credential and service token the stack has —
# roughly forty values, to use three — and it is arbitrary code execution if that
# file ever grows a $(...), which a data file should never be able to do. Both
# copies of st_api_base did exactly that until 2026-08-19, five functions above a
# comment in the same file explaining why nothing else may.
#
# This is a second small extraction loop, not a call into ntfy.lib.sh's _ntfy_env,
# and deliberately: borrowing it would make the Syncthing gate depend on the
# notification transport being sourced first, and on NTFY_REVERSE_PROXY_PORT being
# set, neither of which has anything to do with asking whether a folder is idle.
# The three keys are asserted rather than left empty — an unset one used to abort
# the whole run under `set -u`, from inside a health check.
_st_env() {
    local root_env="/zpool/catallenya/.env" k v line
    [[ -f "$root_env" ]] || { log "no .env"; return 1; }
    for k in TAILNET_DOMAIN TAILNET_DNS_NAME SYNCTHING_REVERSE_PROXY_PORT; do
        line="$(grep -m1 "^${k}=" "$root_env" 2>/dev/null)" || continue
        v="${line#*=}"; v="${v%\"}"; v="${v#\"}"     # tolerate quoted values
        printf -v "$k" '%s' "$v"
    done
    [[ -n "${TAILNET_DOMAIN:-}" && -n "${TAILNET_DNS_NAME:-}" ]] || {
        log "TAILNET_DOMAIN/TAILNET_DNS_NAME unset in .env"; return 1; }
    [[ -n "${SYNCTHING_REVERSE_PROXY_PORT:-}" ]] || {
        log "SYNCTHING_REVERSE_PROXY_PORT unset in .env"; return 1; }
}

st_apikey() {
    [[ -r "$SYNCTHING_CONFIG" ]] || die "cannot read $SYNCTHING_CONFIG"
    grep -oPm1 '(?<=<apikey>)[^<]+' "$SYNCTHING_CONFIG"
}

# Reaching the Syncthing API from the host is fiddlier than it looks:
#   - :8384 is EXPOSED but NOT PUBLISHED (docker ps shows a bare "8384/tcp"), so
#     127.0.0.1:8384 reaches nothing. Consistent with commit 8051401's tailnet-only
#     posture.
#   - The container IP (172.18.x) works but is dynamic — it moves on `compose up -d`.
#     Resolving it at runtime needs `docker inspect`, i.e. the docker socket, i.e.
#     root-equivalent access for these units. Not worth it for a health check.
#   - So: go through Caddy on loopback with the correct SNI. Stable, cert validates,
#     no hardcoded IP, no docker socket. Port comes from .env like everything else.
# Sets ST_HOST / ST_PORT / ST_BASE as globals. Must NOT be called via $(...) — a
# subshell would set them and throw them away.
ST_HOST=""; ST_PORT=""; ST_BASE=""
st_api_base() {
    _st_env || return 1
    ST_HOST="${TAILNET_DOMAIN}.${TAILNET_DNS_NAME}"
    ST_PORT="${SYNCTHING_REVERSE_PROXY_PORT}"
    ST_BASE="https://${ST_HOST}:${ST_PORT}"
}

# The API's own answer: the folder is settled when it is idle with nothing needed.
st_folder_idle() {
    local key json state need
    key="$(st_apikey)" || return 1
    st_api_base || return 1   # sets globals; NOT $(...) — see st_api_base
    json="$(curl -sS --max-time 15 --resolve "${ST_HOST}:${ST_PORT}:127.0.0.1" \
            -H "X-API-Key: ${key}" \
            "${ST_BASE}/rest/db/status?folder=${SYNCTHING_FOLDER_ID}" 2>/dev/null)" || return 1
    state="$(jq -r '.state // "unknown"' <<<"$json" 2>/dev/null)"
    need="$(jq -r '.needFiles // 1' <<<"$json" 2>/dev/null)"
    [[ "$state" == "idle" && "$need" == "0" ]]
}

# syncthing_quiet <watched-directory> — 0 when it is safe to touch that directory.
#
# Two signals, both cheap: no scratch files alongside (Syncthing writes
# .syncthing.*.tmp then renames, so their presence means the folder is mid-work),
# and the API's own idle state. This replaced an hour-long MIN_AGE_SECONDS proxy for
# "probably finished"; asking Syncthing directly is both faster and an actual answer.
#
# The DIRECTORY is the argument because it is the one thing the two consumers
# disagreed about — and it has to be the local one, not the folder root: the API
# answers for the whole "master" folder while the .tmp glob answers for the
# directory this run is about to write into.
syncthing_quiet() { # $1 = the directory this run is about to touch
    # Fail CLOSED on a missing argument, which is the one new way this can be got
    # wrong now that the directory is a parameter. Without it the glob would read
    # "/.syncthing.*.tmp" — a check of the filesystem root that always says "quiet",
    # i.e. the gate silently answering yes to a question nobody asked. Returning
    # "busy" instead makes the caller wait and walk away, leaving the work for the
    # next .path fire; under `set -u` the bare "${1}" would have killed the run
    # mid-drain, which is worse for a pipeline whose whole invariant is draining.
    [[ -n "${1:-}" ]] || { log "syncthing_quiet: called with no directory"; return 1; }
    compgen -G "${1}/.syncthing.*.tmp" >/dev/null 2>&1 && return 1
    # Test seam, same rationale as pigeonhole's DOCS and liquidroom's LR_ROOT: a
    # scratch tree has no Syncthing to ask. Never set in production — without the
    # real idle check, a mid-transfer file gets classified truncated.
    [[ "${SKIP_SYNCTHING_GATE:-}" == "1" ]] && return 0
    st_folder_idle
}
