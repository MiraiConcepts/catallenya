#!/usr/bin/env bash
# The intake code contract, sourced by systemd/install.sh (the gate) and by
# systemd/tests/run.sh (which stages violations against a fixture directory).
#
# It lives in its own file for one reason: install.sh runs an installer when sourced,
# so a suite that wanted to call this directly would have had to test it through a
# subprocess and a mutated unit tree — which cannot express "this SCRIPT is wrong",
# only "this UNIT is wrong". Every rule below is about code the unit points at.
#
# Requires err() from the caller: the gate accumulates into ERRORS and refuses to
# install if any are present, and the suite inspects the same array.

# NTFY_IRREGULAR_VERBS, for the past-participle rule below. Sourced rather than
# duplicated: the whole point of that rule is that the allowlist has exactly one
# entry and is visible where the constructors are, and a second copy here would be
# the drift the message contract exists to end. kinds.sh defines functions and arrays
# and runs nothing, so sourcing it from the gate is free — and it means `--check`
# fails loudly if the file it is enforcing has gone missing.
# shellcheck source=/zpool/catallenya/ntfy/kinds.sh
source "$(dirname "${BASH_SOURCE[0]}")/../ntfy/kinds.sh"

# --- the intake contract ----------------------------------------------------
# Everything above validates a UNIT. This validates the CODE an intake job runs,
# because the three things most likely to drift back are properties of the script and
# invisible from the unit file.
#
# Written as a function over a directory so it can be tested against a fixture: the
# suite's check tree copies units, not scripts, so a violation cannot otherwise be
# staged without editing the live pipeline.
#
# Each rule is here because it has already gone wrong once:
#   - a private notify() drifted four ways, two of them missing --max-time and one
#     missing hdr_safe entirely
#   - `high` on everything is how a topic gets muted, and a muted topic loses the
#     loud messages first
#   - a consumer that reads the API's verdict as pass/fail treats an unpaid account
#     as a broken document, archives it, and prunes the evidence a week later
intake_contract() {
    local dir="$1" label="${2:-$1}" f
    # shopt is global, not function-scoped: restore it or every glob after this call
    # silently changes behaviour.
    # `shopt -p nullglob` EXITS 1 when the option is off — that is how it reports the
    # state — so under the gate's `set -euo pipefail` this line killed the whole
    # validation silently, printing the header and nothing else. It only showed up
    # under the suite, because by then something upstream had already turned nullglob
    # on and the same line returned 0.
    local had_nullglob; had_nullglob="$(shopt -p nullglob)" || true
    shopt -s nullglob
    for f in "$dir"/scripts/*.sh "$dir"/*.sh; do
        [[ -f "$f" ]] || continue
        local base code
        base="$(basename "$f")"
        # Comments are stripped for the content checks. Both intake libs legitimately
        # DISCUSS api_post and high priority, in the notes explaining why they no
        # longer do either — and a rule that cannot tell code from prose about code
        # fires on the very comments left to prevent the regression.
        #
        # Continuation lines are then JOINED and blank runs squeezed, because the
        # checks below are line-shaped and bash is not: `notify "…" \` with `high`
        # on the next line is ONE command to the shell and was invisible to a
        # line-based grep — the one live `high` in the repo shipped in exactly
        # that wrapped form and passed --check clean. Comments come off FIRST: a
        # backslash at the end of a comment continues nothing in bash, and joining
        # before stripping would glue the next code line into the comment and
        # delete both.
        code="$(sed 's/#.*//' "$f" \
                | sed -e ':j' -e '/\\$/ { N; s/\\\n[[:space:]]*/ /; bj }' \
                | tr -s '[:blank:]' ' ')"

        # 1. one transport, not a fifth copy
        if grep -q '^notify() {' "$f"; then
            err "${label}: ${base} defines its own notify() — source ntfy/ntfy.lib.sh instead; four private copies drifted before this rule existed."
        fi
        if grep -q '^retract() {' "$f"; then
            err "${label}: ${base} defines its own retract() — source ntfy/ntfy.lib.sh instead."

        # 2. nothing shouts
        fi
        if grep -qE 'notify "[^"]*" high|Priority: high|priority="high"' <<<"$code"; then
            err "${label}: ${base} sends a notification at high priority — nothing in this repo does. Urgency belongs in what the message says, not in how hard it knocks."

        fi

        # 3. a caller of the API must read all four verdicts, not two
        if grep -q 'api_post' <<<"$code"; then
            grep -qE '== 3|rc 3' <<<"$code" ||
                err "${label}: ${base} calls api_post but never branches on rc 3 — an account that cannot pay would be read as a broken item, resolved instead of parked, and its evidence pruned a week later."
        fi

        # 4. every title comes from a constructor
        #
        # THIS RULE IS THE LAYERING. Everything else in the message contract is a
        # convention the constructors happen to implement; without this, nothing at
        # runtime stops a caller passing notify() a hand-built string, and the six
        # grammars grow back one call site at a time. Unlike systemd/policy/, there
        # is no merge engine underneath to make the layering true on its own.
        #
        # ntfy/system-ntfy.sh is the single exemption and is checked separately below:
        # it sources nothing on purpose, so it cannot call a constructor.
        if [[ "$base" != system-ntfy.sh && "$base" != kinds.sh && "$base" != ntfy.lib.sh ]]; then
            local call var
            while IFS= read -r call; do
                [[ -n "$call" ]] || continue
                # Inline constructor — the common shape.
                grep -qE 'notify (")?\$\((title_count|title_state|title_quote)' <<<"$call" && continue
                # Or a variable, PROVIDED this file assigns it from a constructor.
                # Two call sites legitimately need one: pigeonhole picks between
                # `Blocked` and `Model Failed` on the blocked code, and afterimage
                # builds a quotation once and reuses it. The title still comes from a
                # constructor; only the literal is not at the call site.
                var="$(sed -nE 's/.*notify "?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"?.*/\1/p' <<<"$call")"
                if [[ -n "$var" ]] \
                   && grep -qE "(^| )${var}=\"?\\\$\((title_count|title_state|title_quote)" <<<"$code"; then
                    continue
                fi
                err "${label}: ${base} builds a notification title by hand: ${call:0:70} — every title comes from title_count, title_state or title_quote in ntfy/kinds.sh. See ntfy/MESSAGES.md."
            done < <(grep -oE '(^| )notify ("[^"]*"|\$\([^)]*\)|"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?)' <<<"$code" || true)
        fi

        # 5. a declared verb is a past participle
        #
        # The gate can check that a title's verb is one the feature declared, but the
        # declaration itself is where a new service would otherwise break the rule
        # silently. 21 of the 22 verbs in the repo end in "ed", so the shape IS
        # checkable; NTFY_IRREGULAR_VERBS in ntfy/kinds.sh carries the one that does
        # not. A looser check — rejecting "-ing" only — would have passed `Stray` and
        # `Unclear`, both of which were proposed during design and are adjectives.
        if grep -q 'NTFY_VERBS=(' <<<"$code"; then
            local verbs v
            verbs="$(sed -n 's/.*NTFY_VERBS=(\([^)]*\)).*/\1/p' <<<"$code")"
            for v in $verbs; do
                v="${v//\"/}"
                [[ "$v" == *ed ]] && continue
                grep -qw -- "$v" <<<"${NTFY_IRREGULAR_VERBS[*]:-}" && continue
                err "${label}: ${base} declares NTFY_VERBS entry '${v}', which is not a past participle — a title reports what happened; the button carries the imperative. Add it to NTFY_IRREGULAR_VERBS in ntfy/kinds.sh only if it genuinely is one."
            done
        fi
    done
    eval "$had_nullglob"
    return 0
}
