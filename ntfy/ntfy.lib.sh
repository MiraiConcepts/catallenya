#!/usr/bin/env bash
# shellcheck disable=SC2034  # config vars are consumed by the scripts that source this
# Shared ntfy transport. Sourced, never executed.
#
# This is the one place in the repo that publishes to or deletes from ntfy on behalf
# of a job. Four consumers today:
#
#   afterimage/scripts/afterimage.lib.sh   screenshot -> calendar proposal
#   pigeonhole/scripts/pigeonhole.lib.sh   document   -> filing proposal
#   liquidroom/scripts/liquidroom.lib.sh   track      -> stems (receipts only)
#   immich/scripts/immich.fix-rotations.daily.sh      rotation bake outcome
#
# WHY IT EXISTS. These four carried four copies of notify(), and copies drift in
# exactly the way that is hardest to notice: silently, one at a time, and only in
# the copy nobody revisited. Measured on 2026-08-10, three of the four had
# --max-time and one did not, so a hung ntfy would stall that job until systemd
# killed it an hour later — and report failure for work that had already succeeded.
# The same copy also skipped hdr_safe entirely. Neither was a decision; both were
# a line that landed in three files and not the fourth.
#
# WHY HERE AND NOT IN ai.lib.sh, where hdr_safe and md_escape used to live: neither
# sanitiser has anything to do with the API. They were written there because that is
# where untrusted text first met a notification, not because they belong to the
# transport that fetched it. liquidroom made that visible — it sourced the entire
# AI layer, and calls no API at all, purely to reach two functions about ntfy.
#
# CONTRACT for anything sourcing this file:
#   - Set NTFY_TOPIC before calling notify() or retract().
#   - Set NTFY_MARKDOWN=no if your bodies are plain text; see below.
#   - curl must exist. Assert that in the entrypoint script, not here — a missing
#     binary should fail the run loudly and once, not per-notification.
#   - Source this near the TOP of your own lib, before your own log(). The
#     definition below is guarded, so yours wins and stays authoritative.

declare -F log >/dev/null || log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

# The title constructors ride along with the transport. Consumers source this file and
# get both — see the header of kinds.sh for why they are not asked to source two.
# Resolved from THIS file's location rather than an absolute path, because
# ntfy/tests/run.sh sources the transport relatively and would otherwise reach a
# different copy than the one it is testing.
# shellcheck source=/zpool/catallenya/ntfy/kinds.sh
source "$(dirname "${BASH_SOURCE[0]}")/kinds.sh"

# Markdown rendering, per consumer. The three intake pipelines write bodies FOR
# rendering — italic asides, numbered lists — and escape anything untrusted on the
# way in. immich does not: its bodies are lines like
#
#     IMG_1234.jpg — rotated 90°
#     photo_2026_08_01.jpg — needs a look (SKIP_NO_EXIF)
#
# straight from a photo library, unescaped, and camera filenames are mostly
# underscores. Rendering those would eat the underscores and italicise the middle of
# every name; worse, an unescaped body under a renderer is somewhere a filename can
# hide a real link. Off is both correct and safer for that caller — but it is opt-out
# rather than opt-in, so a new consumer gets the escaping-aware default.
NTFY_MARKDOWN="${NTFY_MARKDOWN:-yes}"

# Only the three keys the transport needs, extracted rather than sourced. `source`
# on the root .env pulls in every database credential and service token the stack
# has — roughly forty values, to use three — and it is arbitrary code execution if
# that file ever grows a $(...), which a data file should never be able to do. The
# intake pipelines each learned this separately; immich still had the wholesale
# source when this was written.
#
# Named _ntfy_env, not _load_env: three consumers already define a _load_env of
# their own that reads their own extra keys, and a shared function that silently
# depended on which file was sourced last would be a bug waiting for a rename.
#
# _ntfy_env [extra-key...] — the trio, plus whatever else the caller names.
#
# The EXTRA KEYS are an argument, and the callers' _load_env wrappers are what keep
# it that way: afterimage needs its own port, pigeonhole needs its own, and this
# function must never grow a list that tries to know which. What is shared is the
# LOOP — the `grep -m1` + quote-strip + `printf -v` shape that each consumer had
# written out longhand, in one case with a subtly different quote-strip. What stays
# per-consumer is the set of names, which is the only part that carries meaning.
# Only the trio is asserted: an extra key that is absent is the caller's business,
# and both callers already say so by name (see capture_base_url / pigeonhole_base_url).
#
# SC2120 is disabled because the extra keys arrive from OTHER FILES — this lib's own
# notify()/retract() need only the trio, so shellcheck, reading one file at a time,
# concludes the parameter is dead. It is not: see the _load_env one-liners in
# afterimage.lib.sh and pigeonhole.lib.sh, which are what it exists for.
# shellcheck disable=SC2120
_ntfy_env() {
    local root_env="/zpool/catallenya/.env" k v line
    [[ -f "$root_env" ]] || { log "no .env"; return 1; }
    # "$@" with no positional parameters is empty, not an error, even under set -u.
    for k in TAILNET_DOMAIN TAILNET_DNS_NAME NTFY_REVERSE_PROXY_PORT "$@"; do
        line="$(grep -m1 "^${k}=" "$root_env" 2>/dev/null)" || continue
        v="${line#*=}"; v="${v%\"}"; v="${v#\"}"
        printf -v "$k" '%s' "$v"
    done
    [[ -n "${TAILNET_DOMAIN:-}" && -n "${TAILNET_DNS_NAME:-}" && -n "${NTFY_REVERSE_PROXY_PORT:-}" ]]
}

# Test seam. Every suite exports NTFY_DISABLE=1, and it is placed immediately before
# the curl in both functions rather than at the top, so header construction,
# hdr_safe and ntfy_id_safe still execute under test — only the wire call is
# suppressed. This was learned expensively: the pigeonhole suite runs the REAL
# triage and apply against a scratch tree, so while its FILES went to /tmp, every
# notification it raised went to the live topic, and a full run put dozens of pings
# on the owner's phone. Never set in production.
ntfy_muted() { [[ "${NTFY_DISABLE:-}" == "1" ]]; }

# hdr_safe <string> — make a caller-derived string safe to put in an HTTP header.
# Strips CR/LF and caps length. curl forwards raw CR/LF in a header verbatim, so a
# title containing "\r\nActions: http, Add, https://evil/" would inject a SECOND
# Actions header — and Go's Header.Get returns the FIRST, so the injected buttons
# would REPLACE the real ones and the user's tap would POST to the attacker.
#
# Every title reaching this function is untrusted somewhere: a screenshot can show
# anything, a document filename arrives over Syncthing from another device, and a
# track name is typed into a filename by hand.
hdr_safe() {
    tr -d '\r\n' <<<"${1:-}" | cut -c1-200
}

# md_escape <string> — neutralise Markdown in caller-derived text.
# Bodies are sent with Markdown rendering on (see NTFY_MARKDOWN), so a
# `[tap here](https://evil.example)` lifted out of a document or a screenshot would
# otherwise become a REAL link inside a notification the user already trusts — the
# same class as the header injection above, arriving through a renderer that was
# switched on for cosmetic reasons. Emphasis leaking is cosmetic; the link is why
# this exists. Backslash is escaped first, or every other escape doubles wrong.
md_escape() {
    sed -e 's/\\/\\\\/g' -e 's/\([][*_`~()#>|]\)/\\\1/g' <<<"${1:-}"
}

# ntfy_id_safe <id> — reduce an id to what is safe in BOTH a header value and a URL
# path segment. Every current caller passes a UUID or a fixed literal, so this
# changes nothing today; it is here because the id reaches ntfy through two
# different syntaxes and a stray slash would silently retract the wrong path.
#
# Leading dots go too, which is not fussiness: the charset alone leaves ".." whole,
# and DELETE on <topic>/.. resolves to the topic root rather than to a message.
# Stripping them empties that value, and retract() declines an empty id.
ntfy_id_safe() { tr -cd 'A-Za-z0-9._-' <<<"$1" | sed 's/^\.*//'; }

# notify <title> <priority> <tags> <body> [actions] [sequence-id]
#
# An EMPTY priority sends no Priority header at all, which is the default weight.
# Best-effort by design: a failed notification must never fail the job that raised
# it, so every path ends in `|| true`.
notify() {
    _ntfy_env || { log "skipping notify"; return 0; }
    local url="https://${TAILNET_DOMAIN}.${TAILNET_DNS_NAME}:${NTFY_REVERSE_PROXY_PORT}"
    local -a hdr=(-H "Title: $(hdr_safe "$1")" -H "Tags: $3")
    [[ "$NTFY_MARKDOWN" == "yes" ]] && hdr+=(-H "Markdown: yes")
    [[ -n "${2:-}" ]] && hdr+=(-H "Priority: $2")
    # Sanitised here, not left to callers. Every current caller whitelists the
    # strings it splices in, but see hdr_safe above for what a CR/LF reaching this
    # particular header does.
    [[ -n "${5:-}" ]] && hdr+=(-H "Actions: $(tr -d '\r\n' <<<"$5")")
    # X-Sequence-ID, and only this spelling family. `X-ID` looks like the obvious
    # name, is accepted with a 200, and is SILENTLY IGNORED — the message comes back
    # with no sequence_id and every later retract addresses nothing. Verified
    # against 2.27.0 by diffing our header against the CLI's own --sequence-id:
    # X-Sequence-ID / Sequence-ID / Sid work, X-ID / X-Seq / Seq do not.
    [[ -n "${6:-}" ]] && hdr+=(-H "X-Sequence-ID: $(ntfy_id_safe "$6")")
    ntfy_muted && return 0
    # --data-raw, never -d: curl reads a -d value beginning with "@" as a FILENAME
    # and POSTs that file's contents. Bodies here are derived from model output and
    # from filenames that arrive over Syncthing, so a document named
    # "@/zpool/catallenya/.env" would exfiltrate that file to this (unauthenticated)
    # topic. --data-raw is byte-identical except it never interprets a leading @.
    #
    # --max-time is not optional. Without it, an ntfy that accepts the connection and
    # then stops answering blocks the caller until systemd's own timeout kills it —
    # for immich that was an hour, reported as a failure, for work that had already
    # succeeded and simply could not say so.
    curl -fsS --max-time 15 "${hdr[@]}" \
        --data-raw "$(tail -c 3500 <<<"$4")" "${url}/${NTFY_TOPIC}" >/dev/null || true
}

# retract <id> — take a previously tagged notification off the phone.
#
# ntfy has no per-message expiry and no scheduled delete (checked against 2.27.0,
# our server): the only way a notification disappears is an explicit DELETE
# addressed to its sequence id, which the server broadcasts to subscribers as a
# message_delete event. That is why every retractable notification has to carry an
# X-Sequence-ID in the first place.
#
# Best-effort, like notify(): a failed retract leaves clutter, never a wrong
# outcome. The server answers 200 for an id it has never seen, so a speculative
# call is free — which is what makes "retract, then publish the replacement" a safe
# unconditional pair even for a record that was never notified solo.
#
# Known gap: the delete event is cached like any message, so a phone offline longer
# than the cache window (NTFY_CACHE_DURATION, widened to 72h in docker-compose.yml
# for exactly this reason) never receives it and keeps the stale notification. The
# app's own auto-delete mops up that straggler.
retract() {
    local id="${1:-}"
    [[ -n "$id" ]] || return 0
    _ntfy_env || return 0
    local url="https://${TAILNET_DOMAIN}.${TAILNET_DNS_NAME}:${NTFY_REVERSE_PROXY_PORT}"
    ntfy_muted && return 0
    curl -fsS --max-time 15 -X DELETE \
        "${url}/${NTFY_TOPIC}/$(ntfy_id_safe "$id")" >/dev/null || true
}

# --- shared message shapes --------------------------------------------------
# A desk failure is ONE fact arriving on several topics, so it reads the same on all
# of them. This is a deliberate exception to the intake playbook's "the shared part
# is the discipline, not the vocabulary" — that rule is right for things a pipeline
# owns (Staged, Binned, Already Passed), and wrong here, because "out of credits" is
# not an afterimage fact or a pigeonhole fact. Before this, the same billing error
# produced "Capture Failed — check the API key" on one topic and "Blocked: 1
# Document — The model call failed" on the other, and only one of them was even
# pointing at the right problem.
#
# Two things vary and must: the NOUN, because they are different things, and the
# day-7 clause, because the outcomes genuinely differ — a document survives in bin/
# and a screenshot's image does not. Flattening that would make the message
# consistent by hiding the part you most need to know.

# How many items to name before summarising. Five is what afterimage's "Already
# Passed" note already uses, so it is a shape the owner has read before; the cap
# matters because ntfy silently converts a body over 4096 bytes into an attachment.
PAUSED_LIST_MAX="${PAUSED_LIST_MAX:-5}"

# paused_title <count> <singular-noun> [cause] -> "Model Paused: 3 Documents [Unpaid]"
#
# Verb-first with a count, so the lock screen answers "what happened" before "to
# what". The noun arrives singular and is pluralised by title_count, so no caller has
# to remember the "1 Document" case.
#
# `Model Paused` rather than the old bare `Paused`: this is the shared AI layer's
# outcome, and the prefix is what marks it as one fact arriving on several topics
# rather than a fact about documents or screenshots. See ntfy/MESSAGES.md § 1.
paused_title() {
    local n="${1:-0}" noun="${2:-Item}" cause="${3:-}"
    title_count "Model Paused" "$n" "$noun" "" "$(title_mark "$cause")"
}

# paused_cause <reason>... -> Unpaid | Unreachable | Mixed | ""
#
# The bracketed half of the title. Callers pass every parked record's reason, because
# an outage can be BOTH — the triage rewrites a record's reason on every park, so a
# run that starts unreachable and becomes an empty balance leaves both kinds sitting
# in the spool at once. Reporting only the newest would name one and hide the other.
#
# The substrings are matched against ai_reason()'s output in ai/scripts/ai.lib.sh —
# OUR string, not the API's, which is what makes a prose match acceptable here. It is
# still a coupling across two files, so ntfy/tests/run.sh asserts the mapping against
# ai_reason() directly rather than against a copy of its wording.
paused_cause() {
    local r unpaid=0 unreach=0
    for r in "$@"; do
        case "$r" in
            *credits*)     unpaid=1  ;;
            *unreachable*) unreach=1 ;;
        esac
    done
    if   (( unpaid && unreach )); then printf 'Mixed'
    elif (( unpaid ));            then printf 'Unpaid'
    elif (( unreach ));           then printf 'Unreachable'
    fi
}

# paused_body <reason> <outcome> <item>... -> numbered list + one italic line
#
# `reason` comes from ai_reason() and is therefore byte-identical across topics.
# `outcome` is the caller's own day-7 clause. Neither is escaped: both are ours.
# The ITEMS are not — a filename arrives over Syncthing from another device and an
# id is ours only by convention — so every one goes through md_escape.
#
# "1\." rather than "1." on purpose: an unescaped "1." at the start of a line is
# ordered-list syntax, and the renderer would renumber the list it built for us.
paused_body() {
    local reason="${1:-}" outcome="${2:-}"; shift 2 || true
    local -a items=("$@")
    # Split across statements deliberately: bash expands every right-hand side in a
    # single `local` BEFORE it assigns any of them, so `local n=... shown="$n"` reads
    # the OUTER n and silently yields an empty shown — which here printed the summary
    # line and none of the items.
    local out="" i
    local n="${#items[@]}"
    local shown="$n"
    (( shown > PAUSED_LIST_MAX )) && shown="$PAUSED_LIST_MAX"
    for (( i = 0; i < shown; i++ )); do
        out+="$((i + 1))\\. $(md_escape "${items[$i]}")"$'\n'
    done
    (( n > shown )) && out+="… and $(( n - shown )) more"$'\n'
    printf '%s\n_%s. Retrying daily — %s._' "$out" "$reason" "$outcome"
}

# paused_sync <sequence-id> <noun> <reason> <cause> <outcome> [item...]
#
# The paused summary's whole lifecycle in one call: withdraw whatever summary is
# riding <sequence-id>, then publish the current one — or nothing, when nothing is
# paused any more. Made to be called UNCONDITIONALLY at the end of every run,
# because the bug it replaces was conditional choreography: both triages had the
# retract INSIDE their non-empty branch, so the run that RESOLVED an outage skipped
# the branch and left "Paused: N …" on the phone forever. The unconditional retract
# is free — the server answers 200 for an id it has never seen (see retract) — so
# there is no state to consult and no branch to get wrong.
#
# <reason> and <outcome> feed paused_body in its own arg order and are never read
# when no items remain, so a caller reporting "outage over" may pass them empty.
# The replacement goes out at default priority with the `warning` tag, matching
# every summary this replaces: nothing in this repo shouts, and warning is the one
# deliberate glyph the paused shape already carries.
paused_sync() {
    local id="${1:-}" noun="${2:-Item}" reason="${3:-}" cause="${4:-}" outcome="${5:-}"
    local -a items=("${@:6}")
    # An empty id would publish a summary nothing can ever withdraw — the exact
    # rot this function exists to end — so decline the whole call instead.
    [[ -n "$id" ]] || { log "paused_sync: no sequence id, refusing"; return 0; }
    retract "$id"
    (( ${#items[@]} > 0 )) || return 0
    notify "$(paused_title "${#items[@]}" "$noun" "$cause")" "" warning \
        "$(paused_body "$reason" "$outcome" "${items[@]}")" "" "$id"
}
