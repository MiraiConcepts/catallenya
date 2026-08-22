#!/usr/bin/env bash
# The shell check, defined ONCE. Both callers run this same file:
#   .github/workflows/ci.yml  — the authority; the mirror publish `needs:` it
#   ci/pre-push               — the convenience; the same check, before the push
#
# It is a script rather than a line in each because a check written twice is a
# check that drifts, and this repo has already paid for that shape twice: the
# ntfy transport was four private curls, two of which had lost `--max-time` and
# two `-f` by the time they were swept; immich's clue-reading was copied into
# scan and verify, so a pattern taught to one made the other read the same row
# as empty. Version, severity and file list live here and nowhere else, so
# there is nothing for the two callers to disagree about.
set -euo pipefail

# Pinned deliberately, 2026-08-22. The ubuntu-24.04 runner ships shellcheck
# 0.9.0 while `:stable` and `:latest` are both 0.11.0 — so an unpinned CI ran
# two releases BEHIND any local check, and raised an SC2218 false positive that
# 0.11.0 had already fixed (a call flagged as preceding its definition even when
# an earlier definition of that name covers it). That is how a local run came
# back clean while CI raised thirteen findings. Bumping this is one edit and
# both callers move together, which is the whole point of the file.
# Tag digest at time of pinning, so a moved tag is detectable:
#   sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d
SHELLCHECK_VERSION="v0.11.0"
SEVERITY="warning"   # gates warning+error; info/style findings do not block

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# A checker that CANNOT RUN must fail, never pass quietly. A hook that exits 0
# because docker is absent is worse than no hook at all: it reports a check that
# never happened. That is the same fault as an alert dropped by a bare `curl`
# while ExecStartPost= stamps the run healthy — the failure mode this repo keeps
# closing, and it would be self-inflicted here.
if ! command -v docker >/dev/null 2>&1; then
    echo "ci/shellcheck.sh: docker not found — the pinned checker cannot run" >&2
    echo "  CI runs koalaman/shellcheck:${SHELLCHECK_VERSION}; there is no fallback" >&2
    echo "  binary on this box, and checking with a different version is how the" >&2
    echo "  local run and CI stopped agreeing in the first place." >&2
    exit 1
fi

# `git ls-files` is the file list on BOTH sides, so the hook and CI can never
# disagree about what is in scope. -z/-0 because a tracked path may contain
# anything; -r so an empty list is a no-op rather than a bare shellcheck call.
git ls-files -z '*.sh' | xargs -0 -r \
    docker run --rm -v "${ROOT}:/mnt" -w /mnt \
    "koalaman/shellcheck:${SHELLCHECK_VERSION}" -S "${SEVERITY}"
