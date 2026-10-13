#!/usr/bin/env bash
# Offline suite for the calendar feeds (radicale/feeds/). Sends nothing and writes
# nothing outside a temp dir: the sink runs against an in-process fake CalDAV
# server, the notifier against a stub, Filmhouse against a saved copy of its page.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NTFY_DISABLE=1
# The fake server is on 127.0.0.1; a sandbox or corporate proxy must not intercept it.
export NO_PROXY="127.0.0.1,localhost" no_proxy="127.0.0.1,localhost"
out="$(python3 -I "${SELF_DIR}/test_feeds.py" 2>&1)" && rc=0 || rc=$?
total="$(grep -oE '^Ran [0-9]+' <<<"$out" | grep -oE '[0-9]+' || echo 0)"
if (( rc != 0 )); then
    printf '%s\n' "$out"
    failed="$(grep -oE '(failures|errors)=[0-9]+' <<<"$out" | grep -oE '[0-9]+' | paste -sd+ | bc)"
    echo "$(( total - failed )) passed, ${failed} failed"
    exit 1
fi
echo "${total} passed, 0 failed"
