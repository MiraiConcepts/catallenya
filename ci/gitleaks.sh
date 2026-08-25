#!/usr/bin/env bash
# The secret scan, defined ONCE. Both callers run this same file:
#   .github/workflows/ci.yml  — the authority; the mirror publish `needs:` it
#   ci/pre-push               — the same scan, before the push leaves this box
#   a human, by hand          — `bash ci/gitleaks.sh`, any time
#
# Same reasoning as ci/shellcheck.sh: a check written twice is a check that
# drifts. CLAUDE.md used to carry the local command as PROSE beside a CI job
# that invoked the scanner a different way, which is two definitions wearing
# one name — the local run and CI agreed only for as long as someone kept them
# in sync by hand.
set -euo pipefail

# WHY THIS IS NOT gitleaks/gitleaks-action (changed 2026-08-24):
# The wrapper is free for repos owned by a PERSONAL account and requires a
# licence key for repos owned by an ORGANIZATION. Nothing about the scan
# differs — the wrapper downloads this same binary — so moving this repo from
# carrein/ to MiraiConcepts/ broke the job on ownership alone:
#   [MiraiConcepts] is an organization. License key is required.
# A free single-repo tier exists, but it puts an external licence server in
# front of the one check that guards a PUBLIC repo which force-pushes to six
# public mirrors. The scanner itself is MIT and has never been licensed.
#
# WHAT WAS LOST: the wrapper's PR comments and its SARIF upload to code
# scanning. Neither was in use — ci.yml declares `permissions: contents: read`
# with no `security-events: write`, so no SARIF has ever been uploaded.
#
# WHAT WAS GAINED: the wrapper scanned only the PUSH DIFF on a push and the
# full history only on workflow_dispatch. This scans full history every run.
# That gap is not theoretical — the 2026-08-15 rename broke a .gitleaksignore
# fingerprint and sailed through four green pushes before the next manual
# dispatch caught it, three weeks later. Measured cost of closing it: 323
# commits, 2.2 MB, ~0.3s.

# Pinned deliberately. Bumping this is one edit and both callers move together.
# NOTE: dependabot does NOT watch this. It is configured for the
# `github-actions` ecosystem only, so it bumped the old wrapper's SHA weekly
# and cannot see a version string inside a shell script. This pin ages until a
# human moves it — the same deal ci/shellcheck.sh already makes, and the reason
# both files say so out loud rather than looking maintained.
GITLEAKS_VERSION="v8.30.1"

# Bumped 8.24.3 -> 8.30.1 on 2026-08-25, eleven releases in one step, and the
# safety of it was MEASURED rather than assumed. Both versions were run over the
# full history twice: with .gitleaksignore in place both exit 0, and with it
# masked by an empty file both find the SAME THREE findings — same rule, same
# file, same line — so the newer scanner has not gone quiet and all three
# fingerprints still match (they are commit:path:rule:line, and none of those
# moved). That test is the one to repeat before any future bump.
#
# It also disproved the reason the pin was being held. CLAUDE.md and
# .gitleaksignore both claimed "8.30.1 does not flag" the generic-api-key false
# positive at capture.lib.sh:230. It does. The claim dates from a 2026-07-27 CI
# failure and whatever it described, it was not this; both copies are corrected.
#
# ghcr rather than Docker Hub, and the images are the SAME BYTES — verified
# 2026-08-24 on v8.24.3, identical manifest and identical linux/amd64 digest.
# Tag digest at time of pinning, so a moved tag is detectable:
#   sha256:b109bc5f8f76a38196a3e413704fc5b9e3c32360bce4e4b603bd6f45b3721dbb
# Docker Hub rate-limits anonymous pulls per source IP and GitHub's runners
# share theirs, so the Hub path fails intermittently for reasons that have
# nothing to do with this repository. ghcr has no such limit from Actions.
# CLAUDE.md documented `zricethezav/gitleaks` for years; that image is not
# wrong, it is just the one that can 429 in CI.
GITLEAKS_IMAGE="ghcr.io/gitleaks/gitleaks:${GITLEAKS_VERSION}"

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# A checker that CANNOT RUN must fail, never pass quietly — the same rule
# ci/shellcheck.sh states for the same reason. A secret scan that exits 0
# because docker is absent reports a check that never happened, on the repo
# where that failure is least affordable.
if ! command -v docker >/dev/null 2>&1; then
    echo "ci/gitleaks.sh: docker not found — the pinned scanner cannot run" >&2
    echo "  CI runs ${GITLEAKS_IMAGE}; there is no fallback binary on this box," >&2
    echo "  and .gitleaksignore fingerprints are version-sensitive, so scanning" >&2
    echo "  with whatever gitleaks happens to be installed proves nothing." >&2
    exit 1
fi

# `detect` walks git history; --redact keeps a finding's value out of the log,
# which matters because this repo's CI logs are public. .gitleaksignore is read
# from the repo root automatically — verified by masking it with an empty file,
# which turns this same scan from 0 findings into 3.
# Exit 1 on findings is what fails the job.
exec docker run --rm -v "${ROOT}:/repo" -w /repo "${GITLEAKS_IMAGE}" detect --redact
