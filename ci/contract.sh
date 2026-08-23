#!/usr/bin/env bash
# The job-contract check, defined ONCE. Both callers run this same file:
#   .github/workflows/ci.yml  — the authority; the mirror publish `needs:` it
#   ci/pre-push               — the convenience; the same check, before the push
#
# Same shape and same reasoning as ci/shellcheck.sh beside it: a check written
# twice is a check that drifts, and this repo has paid for that twice already.
#
# WHY IT EXISTS AT ALL. `systemd/install.sh --check` validates every unit against
# its class contract, and until 2026-08-23 it ran ONLY when a human typed it —
# CLAUDE.md documented it as "run this before committing any unit change", which is
# discipline rather than a gate. That failed on the first unit change after the rule
# was written: commit 32e92f6 removed a required RandomizedDelaySec=, the gate
# refuses it, and it pushed GREEN because none of the three checkpoints look at unit
# files. audit/pre-commit frisks for secrets, ci/pre-push ran shellcheck, and CI ran
# neither. A refused unit on main is one `sudo bash systemd/install.sh` away from
# aborting the entire install, because the gate creates NO links if any unit fails.
#
# WHAT IS DELIBERATELY NOT HERE: systemd/tests/run.sh, the 101-case offline suite
# that proves the gate refuses each forbidden shape. It belongs in CI and is run
# there as its own step — but MEASURED ON THIS BOX IT TAKES 72 SECONDS, against
# 1.7s for the gate and 5.9s for shellcheck. Putting it in the pre-push path would
# make every push wait over a minute, and ci/pre-push's own header explains why that
# is worse than useless: "a check that fires on every docs typo is a check people
# learn to skip with --no-verify, which would cost the secret guard its credibility
# too, since that is the same flag." The gate is what catches the violation; the
# suite is what catches a broken gate, and only one of those is a per-push concern.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# INSTALL_CHECK_REPO is install.sh's own seam, honored ONLY under --check, and it is
# what lets this run anywhere — a CI runner's workspace, a fresh clone, a scratch
# tree. Without it install.sh validates the units at the hardcoded /zpool/catallenya,
# which on a runner does not exist and on a developer box would silently check the
# INSTALLED tree rather than the one being pushed. Verified from a fresh shallow
# clone at an unrelated path as a non-root user: 40 units, rc 0.
#
# --check needs no root and no docker, which is a stated design property of
# install.sh rather than an accident, and is what makes a bare runner enough.
INSTALL_CHECK_REPO="$ROOT" exec bash systemd/install.sh --check
