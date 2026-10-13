#!/usr/bin/env bash
# shellcheck disable=SC2034  # NTFY_TOPIC and the vocabulary are read by ntfy.lib.sh and systemd/contract.sh
# The calendar feeds' one notification: an event the owner marked "going" in hitome
# has vanished from its source and was set to STATUS:CANCELLED (feeds_sink.py).
#
#   feeds.notify.sh cancelled <summary<TAB>when>...
#
# A separate script because the feeds are Python and the message layer is bash —
# the transport, the title constructors and the renderers live in ntfy/ and are
# checked there by systemd/contract.sh. Reimplementing them in Python would be the
# fifth private copy that rule exists to stop.
#
# A RECEIPT, not a fault: nothing is broken and there is nothing to tap; the
# calendar already shows it crossed out. No buttons and no id, so it is never
# withdrawn — see the withdrawal rule in ntfy/MESSAGES.md.
#
# Silent on success. The caller treats ANY output as an undelivered notice, the same
# test disk.sh applies to the transport's best-effort contract.
set -euo pipefail

# shellcheck source=/zpool/catallenya/ntfy/ntfy.lib.sh
source "/zpool/catallenya/ntfy/ntfy.lib.sh"

NTFY_TOPIC="hitome"
NTFY_VERBS=(Cancelled)
NTFY_NOUNS=(Event)

usage() { echo "usage: feeds.notify.sh cancelled <summary<TAB>when>..." >&2; exit 2; }

# send_cancelled <summary<TAB>when>... — one receipt for every cancelled event in
# the run. A function so tests can source this file and shadow notify_receipt.
send_cancelled() {
    (( $# >= 1 )) || usage
    local name=""
    (( $# == 1 )) && name="${1%%$'\t'*}"
    notify_receipt "$(title_count Cancelled "$#" Event "$name")" "$(body_list --all "$@")"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        cancelled) shift; send_cancelled "$@" ;;
        *) usage ;;
    esac
fi
