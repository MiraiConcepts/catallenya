#!/usr/bin/env bash
# Installs the tracked git hooks into this clone. Idempotent; safe to re-run.
#
# .git/hooks/ is never tracked by git, so every hook in this repo exists twice:
# a tracked master that survives a rebuild, and an installed copy that actually
# runs. This script copies the first over the second, and `audit.sh` section 17
# reports whenever the two drift apart or the installed copy goes missing —
# most plausibly after a rebuild-and-restore, which is exactly when the corpus
# the secret guard protects has just been put back and the guard has not.
#
#   audit/pre-commit -> refuses to commit secret-shaped paths (the second lock)
#   ci/pre-push      -> runs ci/shellcheck.sh, the same check CI runs
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# core.hooksPath wins over .git/hooks when set, so ask git rather than assume —
# installing into the wrong directory would leave a hook that never runs while
# looking installed. Same resolution as audit.sh section 17, deliberately.
HOOKS_DIR=$(git config --get core.hooksPath || true)
if [[ -z "$HOOKS_DIR" ]]; then
    HOOKS_DIR="$(git rev-parse --git-common-dir)/hooks"
fi
[[ "$HOOKS_DIR" != /* ]] && HOOKS_DIR="${ROOT}/${HOOKS_DIR}"
HOOKS_DIR="$(realpath -m "$HOOKS_DIR")"

mkdir -p "$HOOKS_DIR"

# master:installed-name
HOOKS=(
    "audit/pre-commit:pre-commit"
    "ci/pre-push:pre-push"
)

echo "hooks directory: ${HOOKS_DIR}"
for entry in "${HOOKS[@]}"; do
    master="${entry%%:*}"
    name="${entry#*:}"
    target="${HOOKS_DIR}/${name}"

    if [[ ! -f "$master" ]]; then
        echo "  ✗ ${name}: tracked master ${master} is missing" >&2
        exit 1
    fi

    # Copy rather than symlink: a hook is what has to work while rebuilding a
    # box, and a copy has no path to resolve. The cost is drift, which is
    # precisely what audit.sh section 17 exists to report.
    if cmp -s "$master" "$target" 2>/dev/null && [[ -x "$target" ]]; then
        echo "  = ${name} already current"
    else
        install -m 755 "$master" "$target"
        echo "  + ${name} installed from ${master}"
    fi
done

echo
echo "verify with: bash audit/audit.sh   (section 17)"
