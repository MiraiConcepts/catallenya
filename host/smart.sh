#!/bin/bash
# SMART monitor — the one failure mode ZFS cannot see.
#
# ZED reports a disk that HAS failed; scrub reports corruption in blocks it happens
# to read. Neither knows the flash is approaching its rated write limit, and the two
# pool members are IDENTICAL parts taking identical writes, so the mirror's
# redundancy does not protect against wear-out: they reach the end together. This is
# the only place that trend is visible.
#
# Silent when healthy, like disk.sh and restic.staleness. Publishes to the SAME
# `disk` topic rather than a new one — an unsubscribed monitoring topic swallows
# alerts with a 200 OK, which is the failure this job exists to prevent.
set -euo pipefail

# shellcheck disable=SC2034  # read by ntfy.lib.sh, sourced below
NTFY_TOPIC="disk"

# ONE STABLE ID PER DEVICE. This runs daily and re-alerts on every run while a
# condition holds, so without an id a worn drive would produce a new notification
# every morning forever. With one, the message rewrites itself and the number in it
# climbs — which is also why there is no separate "page" threshold: priority was
# removed from notify() on 2026-08-20 and nothing shouts, so a second threshold
# could not be louder than the first. The number IS the escalation.
#
# Per DEVICE, not per finding: two problems on one drive are one drive to look at,
# and they share a remedy. Two drives are two subjects, exactly as root and zpool
# are in disk.sh, so they must not share an id or whichever crossed second would
# silently replace the first.
SMART_NTFY_ID="smart"
# shellcheck source=/zpool/catallenya/ntfy/ntfy.lib.sh
source "/zpool/catallenya/ntfy/ntfy.lib.sh"

# Test seam, same shape as NTFY_DISABLE in the transport. Point it at a script that
# prints a captured `smartctl -a` report and this whole file runs without root and
# without touching a disk, which is how every branch below was proven before it was
# installed: healthy, worn past threshold, reallocated sectors, a failed
# self-assessment, CRC errors, a vanished wear attribute, and an unreadable device.
#
# There is deliberately no committed suite (owner's call, 2026-08-22) — host/ has no
# test tree and creating one for a single job was not worth the infrastructure. The
# seam stays because it is one line and it is what makes a re-check cheap: capture a
# report, point this at a stub that cats it, run.
#
# It matters more here than it would elsewhere. These drives report "Not in smartctl
# database", so a third of their attributes come back as Unknown_Attribute and no
# percentage-used field exists at all — a parser written against imagined output
# would have been wrong in a way that reads as "all clear". Never set in production.
SMARTCTL="${SMARTCTL:-/usr/sbin/smartctl}"

# Percent of rated endurance consumed before this speaks. 80 leaves a wide runway:
# measured 2026-08-22, the pool pair sit at 0% after 1.94 years and the root NVMe at
# 15%, so nothing here is near it and the first alert will be real.
WEAR_THRESHOLD=80

# Hardcoded rather than discovered from `smartctl --scan`, deliberately. A scan that
# returns fewer devices than yesterday monitors fewer drives and still exits 0 —
# a watcher whose failure reads as health, which is the shape this whole repo hunts.
# Three drives are soldered into the design of this box; a fourth is a change to this
# file. Same reasoning as zpool.scrub.service hardcoding the pool name.
#
# name<TAB>path
DEVICES=(
    "sda"$'\t'"/dev/sda"
    "sdb"$'\t'"/dev/sdb"
    "nvme0n1"$'\t'"/dev/nvme0n1"
)

# attr <report> <id> <field> — one column of one ATA attribute row.
# Field 4 is VALUE (vendor-normalised, counts DOWN from 100), field 10 is RAW_VALUE.
attr() {
    awk -v id="$2" -v f="$3" '$1 == id { print $f; exit }' <<<"$1"
}

FAILED=0
ALERTS=()   # name<TAB>state<TAB>body

for entry in "${DEVICES[@]}"; do
    name="${entry%%$'\t'*}"
    path="${entry#*$'\t'}"

    # `-H -A`, NEVER `-a`. This is the difference between an exit code that means
    # something and one that does not, and it was found by running the job rather
    # than by reading the manual — the first live run FAILED on a healthy box.
    #
    # `-a` is "everything", which includes the SELF-TEST LOG. The root NVMe does not
    # implement that log page, so it answered "Invalid Field in Command", smartctl
    # set exit bit 2 (some SMART command failed), and this job declared a drive
    # unreadable while holding its complete, perfectly good health report.
    #
    # Worse, and quieter: the drive RECORDS each rejection. Its error-log counter
    # went 238 -> 239 between the capture used to build this and the first live run,
    # so a daily `-a` would have added ~365 entries a year to the very log this job
    # exists to watch — a monitor corrupting its own instrument.
    #
    # `-H -A` asks for exactly the two things parsed below: the overall-health
    # verdict and the attribute/health table. Nothing optional, nothing unsupported.
    # That is what makes the bitmask below trustworthy — with the request narrowed,
    # a bit-2 failure now genuinely means the health or attribute read failed, which
    # IS fatal, rather than meaning some extra the job never wanted was unavailable.
    #
    # SMARTCTL'S EXIT STATUS IS A BITMASK, NOT A SUCCESS CODE. This is the trap that
    # makes `set -e` wrong here: a drive with a pre-fail attribute below threshold —
    # precisely the case worth alerting on — exits NON-ZERO on a command that worked
    # perfectly. Bits 0-2 (parse error, device open failed, SMART command failed)
    # mean the reading did not happen; bits 3-7 (failing, pre-fail below threshold,
    # was below in the past, error log, self-test log) ARE the reading. Treating the
    # whole value as failure would kill the job on the day it finally had something
    # to say.
    rc=0
    report="$("$SMARTCTL" -H -A "$path" 2>&1)" || rc=$?

    if (( rc & 0x07 )); then
        # Cannot read the drive at all. Not a finding — the job could not do its
        # work, so it must fail rather than report a clean bill of health for a disk
        # it never looked at. The inherited OnFailure= carries the journal excerpt.
        #
        # WHAT GOES IN THE JOURNAL IS THE DIAGNOSIS, NOT THE REPORT — decided by
        # reading a real alert on the phone rather than by reasoning about it.
        #
        # system-ntfy.sh builds its message from `journalctl -n 8`, the LAST eight
        # lines. The first attempt printed the whole report and then the verdict, so
        # the verdict survived truncation but arrived under seven lines of NVMe
        # temperature sensors — technically correct and useless to read at a glance.
        #
        # A `smartctl` report is REPRODUCIBLE: anyone can regenerate it in one
        # command, and the command is printed below. What is not reproducible is
        # which device failed, on which run, with which bits set. So the journal
        # carries that, plus the tail of smartctl's own output where its error
        # message actually lives — six lines, all of them load-bearing, which is
        # what the eight-line window is for.
        printf 'smart: cannot read %s — smartctl exit bits %d\n' "$name" "$rc" >&2
        printf 'smart:   bit0=bad-invocation bit1=device-open-failed bit2=command-failed\n' >&2
        printf 'smart:   its last words were —\n' >&2
        tail -3 <<<"$report" | sed 's/^/smart:   /' >&2
        printf 'smart:   reproduce with: smartctl -H -A %s\n' "$path" >&2
        FAILED=1
        continue
    fi

    health="$(sed -n 's/^SMART overall-health self-assessment test result:[[:space:]]*//p' <<<"$report" | head -1)"

    facts=()
    state=""

    if grep -q '^Percentage Used:' <<<"$report"; then
        # --- NVMe. The only device here that reports wear as a percentage. ---
        wear="$(sed -n 's/^Percentage Used:[[:space:]]*\([0-9]\{1,\}\)%.*/\1/p' <<<"$report" | head -1)"
        spare="$(sed -n 's/^Available Spare:[[:space:]]*\([0-9]\{1,\}\)%.*/\1/p' <<<"$report" | head -1)"
        spare_min="$(sed -n 's/^Available Spare Threshold:[[:space:]]*\([0-9]\{1,\}\)%.*/\1/p' <<<"$report" | head -1)"
        critical="$(sed -n 's/^Critical Warning:[[:space:]]*//p' <<<"$report" | head -1)"
        written="$(sed -n 's/^Data Units Written:.*\[\(.*\)\]$/\1/p' <<<"$report" | head -1)"
        defects=0
        link_errors=0
    else
        # --- ATA/SATA. ---
        # These drives report "Device is: Not in smartctl database", so a third of
        # their attributes come back as Unknown_Attribute and there is NO
        # percentage-used field. Wear is only visible through 177's normalised VALUE,
        # which starts at 100 and counts down, so consumed = 100 - VALUE.
        v177="$(attr "$report" 177 4)"
        # An ABSENT wear source fails the unit rather than reporting 0%. A gauge that
        # silently reads zero because its input vanished is worse than no gauge: it
        # says "healthy" forever. Firmware changes and drive swaps are the two ways
        # this happens, and both deserve a human.
        if [[ -z "$v177" ]]; then
            printf 'smart: %s exposes no Wear_Leveling_Count (177) — wear cannot be measured\n' "$name" >&2
            FAILED=1
            continue
        fi
        wear=$(( 100 - v177 ))
        # The defect counters. All four read 0 on both drives as of 2026-08-22, so
        # ANY movement is real news rather than a baseline to tune around.
        defects=$(( $(attr "$report" 5 10) + $(attr "$report" 197 10) + $(attr "$report" 198 10) ))
        link_errors="$(attr "$report" 199 10)"
        written=""
        spare=""
        spare_min=""
        critical=""

        # DELIBERATELY NOT CHECKED, both verified against this box's real output:
        #
        #   232 Available_Reservd_Space  VALUE 000  THRESH 000
        #     The obvious rule "alert when VALUE <= THRESH" is 0 <= 0 — true on both
        #     drives, every run, forever. smartctl itself does not flag it (its
        #     WHEN_FAILED column reads `-`, because the rule applies to Pre-fail
        #     attributes and this is Old_age), so trusting smartctl's own verdict
        #     beats re-deriving it wrongly.
        #
        #   188 Command_Timeout  raw 42 / 11
        #     Non-zero on both, and has been for the life of the drives with zero
        #     corresponding errors anywhere else. Alerting would produce a permanent
        #     notification about a healthy box, which trains you to ignore the topic
        #     that also carries a dying disk.
    fi

    # SEVERITY ORDER decides the title. A drive can trip several of these at once;
    # the title names the worst and the body carries the rest.
    if [[ "$health" != "PASSED" ]]; then
        state="Health Failed"
        facts+=("The drive's own overall-health self-assessment reports ${health:-no result}")
    elif (( defects > 0 )); then
        state="${defects} Bad Sector$( (( defects == 1 )) || printf s )"
        facts+=("$(attr "$report" 5 10) sectors reallocated" \
                "$(attr "$report" 197 10) sectors pending reallocation" \
                "$(attr "$report" 198 10) sectors uncorrectable offline")
    elif [[ -n "$critical" && "$critical" != "0x00" ]]; then
        state="Critical Warning"
        facts+=("The controller raised critical warning flags ${critical}")
    elif [[ -n "$spare" && -n "$spare_min" ]] && (( spare < spare_min )); then
        state="${spare}% Spare Left"
        facts+=("Spare blocks are at ${spare}%, below the drive's own ${spare_min}% floor")
    elif (( wear >= WEAR_THRESHOLD )); then
        state="${wear}% Worn"
        facts+=("${wear}% of rated write endurance consumed" \
                "$(( wear - WEAR_THRESHOLD ))% over the ${WEAR_THRESHOLD}% threshold")
        [[ -n "$written" ]] && facts+=("${written} written over the drive's life")
    elif (( link_errors > 0 )); then
        # Last, because a cable or controller fault is not the drive dying — but it
        # is invisible everywhere else on this box.
        state="${link_errors} Link Error$( (( link_errors == 1 )) || printf s )"
        facts+=("${link_errors} UDMA CRC errors on the SATA link, which usually means a cable rather than the drive")
    else
        continue
    fi

    ALERTS+=("${name}"$'\t'"${state}"$'\t'"$(body_fact "${facts[@]}")")
done

for entry in "${ALERTS[@]:-}"; do
    [[ -n "$entry" ]] || continue
    name="${entry%%$'\t'*}"
    rest="${entry#*$'\t'}"
    state="${rest%%$'\t'*}"
    body="${rest#*$'\t'}"

    # The journal gets it unconditionally and BEFORE the wire, so a failed delivery
    # still leaves a record of what the alert said.
    printf '%s: %s\n%s\n' "$name" "$state" "$body"

    # A DROPPED ALERT MUST FAIL THIS UNIT — the same inversion disk.sh documents.
    # notify() is best-effort by contract, so its SILENCE is the test: curl -fsS
    # prints nothing on success and the error otherwise. Without this an ntfy 5xx
    # would leave a morning indistinguishable from a healthy one while
    # ExecStartPost= stamped the run fresh for the watchdog.
    #
    # Every alert is attempted before exiting, so a down ntfy cannot lose the second
    # drive's alert because the first one was queued ahead of it.
    send_out="$(notify_fault "$(title_state "$name" "$state")" "$body" "${SMART_NTFY_ID}-${name}" 2>&1)"
    if [[ -n "$send_out" ]]; then
        echo "smart: ntfy publish FAILED, the ${name} alert above was not delivered: ${send_out}" >&2
        FAILED=1
    fi
done

(( FAILED == 0 ))
