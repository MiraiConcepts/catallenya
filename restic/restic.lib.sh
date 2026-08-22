#!/bin/bash
# Shared plumbing for the restic jobs' NOTIFICATIONS, and nothing else. No restic
# invocation belongs here — each job's command is its own, and burying it would make
# the one thing you check during a restore harder to read.
#
# WHY THIS EXISTS. Every restic job wires OnSuccess=/OnFailure= to
# ntfy/system-ntfy.sh, whose body is the job's own stdout for that invocation
# (scoped to _SYSTEMD_INVOCATION_ID and _TRANSPORT=stdout). restic writes for an
# 80-column terminal — padded columns, progress bars, a snapshot table listing every
# path in every group — and at roughly 40 columns on a phone every line wraps
# mid-content and the padding becomes noise. `forget` was the worst: its stdout is
# the entire keep/remove table across 18 groups.
#
# THE SPLIT. restic's own output goes to STDERR, so the journal keeps every word for
# forensics and the courier never shows it. The job prints a short receipt to STDOUT,
# and that is what reaches the phone.
#
# THE FAILURE PATH IS UNCHANGED, and that is why this is done by REDIRECTING rather
# than by trimming. Every one of these scripts is `set -euo pipefail`, so a restic
# that fails aborts BEFORE its receipt is printed. stdout is then empty, and
# system-ntfy.sh's existing fallback re-queries the journal WITHOUT the transport
# filter — so a failure still shows restic's raw error exactly as it does today. The
# receipt is a success-path nicety; nothing about diagnosis changes.
#
# The same reasoning says why the receipt is BUILT rather than trimmed from restic's
# tail: `tail -n 4` of a prune is four lines of pack arithmetic, which is shorter
# without being an answer.

# The fact marker. MUST match BODY_FACT_MARK in ntfy/kinds.sh — ntfy/tests/run.sh
# asserts the two agree, because a second copy of a constant is how they drift.
#
# Duplicated rather than sourced ON PURPOSE: these scripts do not notify, the courier
# does, so pulling in the whole ntfy transport to read one character would be the
# mistake liquidroom made when it sourced the entire AI layer to reach two functions
# about ntfy.
RESTIC_FACT_MARK='•'

# restic_run <capture-file> <restic-args...>
#
# Runs restic with its output going to STDERR and a copy to <capture-file> for the
# receipt to read. `tee` streams, so the journal fills as the run progresses rather
# than all at once at the end — which matters for a job that can take hours.
#
# `set -o pipefail` in every caller is what makes restic's exit code survive the
# pipe. Without it `tee` would return 0 and a failed backup would look successful,
# which is the single worst thing this file could get wrong.
restic_run() {
    local cap="$1"; shift
    restic "$@" 2>&1 | tee "$cap" >&2
}

# fact <text> — one receipt line on STDOUT.
fact() { printf '%s %s\n' "$RESTIC_FACT_MARK" "$1"; }

# first_match <capture-file> <sed-expression> — the first line the expression
# rewrites, or nothing. Nothing is the safe answer: a receipt line that cannot be
# built is simply absent, and if NONE can be built the job prints no stdout at all,
# which drops the courier onto its full-journal fallback. Failing toward more
# information is the right direction for a backup.
first_match() {
    sed -nE "$2" "$1" 2>/dev/null | head -1
}
