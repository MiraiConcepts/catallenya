#!/usr/bin/env bash
# Regression tests for the systemd job factory: the gate and the watchdog.
#
# Everything here runs offline and free. The gate is tested by breaking a REAL
# unit and confirming it refuses — a synthetic fixture would only prove the gate
# agrees with a fixture. The watchdog is tested against the per-user systemd
# manager, so real systemd does the parsing and drop-in merging rather than a mock
# that agrees with whatever the script already believes.
#
# Nothing here touches the system manager or /etc/systemd/system. Run before commit:
#   bash systemd/tests/run.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SELF_DIR}/../.." && pwd)"
INSTALL="${REPO}/systemd/install.sh"
HEARTBEAT="${REPO}/ntfy/heartbeat-ntfy.sh"

# Nothing here may reach the real phone. The watchdog cases run the REAL script,
# not a dry-run, so without this a failing round would publish to the live topic
# and the suite would look like it passed.
export NTFY_DISABLE=1

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
has()  { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "contains: $3" "$2"; }
hasnt(){ [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "must not contain: $3" "$2"; }

# ================================================================== the gate
#
# Each case mutates one real unit, runs the gate, and restores. The restore is in
# a trap as well as inline: a suite that leaves a broken unit behind would be
# worse than no suite.

MUTATED="" BACKUP=""
restore() { [[ -n "$MUTATED" && -f "$BACKUP" ]] && mv -f "$BACKUP" "$MUTATED"; MUTATED="" BACKUP=""; }
trap restore EXIT

# gate_says <name> <unit-path> <sed-expr> <expected substring>
gate_says() {
    local name="$1" unit="$2" expr="$3" want="$4"
    MUTATED="$unit"; BACKUP="$(mktemp)"; cp "$unit" "$BACKUP"
    sed -i -E "$expr" "$unit"
    local out; out="$(bash "$INSTALL" --check 2>&1)"
    restore
    has "$name" "$out" "$want"
}

echo "gate — refuses what the contract forbids"

gate_says "no Class= is refused" \
    "${REPO}/systemd/disk.service" '/^Class=monitor$/d' "no [X-Catallenya] Class="

gate_says "unknown Class= is refused" \
    "${REPO}/systemd/disk.service" 's/^Class=monitor$/Class=wibble/' "unknown Class=wibble"

gate_says "scheduled without TimeoutStartSec is refused" \
    "${REPO}/restic/forget/restic.forget.service" '/^TimeoutStartSec=/d' \
    "requires an explicit finite TimeoutStartSec"

gate_says "scheduled without MaxAge is refused" \
    "${REPO}/restic/forget/restic.forget.service" '/^MaxAge=/d' "requires MaxAge="

gate_says "monitor declaring Freshness is refused" \
    "${REPO}/systemd/disk.service" 's/^MaxAge=3h$/MaxAge=3h\nFreshness=stamp:\/tmp\/x/' \
    "must not declare Freshness="

gate_says "monitor setting its own TimeoutStartSec is refused" \
    "${REPO}/systemd/disk.service" 's/^ExecStart=/TimeoutStartSec=5min\nExecStart=/' \
    "must not set TimeoutStartSec"

gate_says "adhoc declaring MaxAge is refused" \
    "${REPO}/capture/systemd/capture.triage.service" 's/^Class=adhoc$/Class=adhoc\nMaxAge=1h/' \
    "must not declare MaxAge="

gate_says "a root job without CapabilityBoundingSet is refused" \
    "${REPO}/systemd/zpool.scrub.service" '/^CapabilityBoundingSet=/d' \
    "runs as root without a CapabilityBoundingSet"

gate_says "a missing User= is refused" \
    "${REPO}/systemd/disk.service" '/^User=/d' "no explicit User="

gate_says "Condition*= is refused in favour of Requires=" \
    "${REPO}/systemd/disk.service" 's/^ExecStart=/ConditionPathExists=\/tmp\nExecStart=/' \
    "A failed Condition is a SKIP"

gate_says "RuntimeMaxSec= is refused as a no-op on oneshot" \
    "${REPO}/systemd/disk.service" 's/^ExecStart=/RuntimeMaxSec=5min\nExecStart=/' \
    "systemd IGNORES on Type=oneshot"

gate_says "re-setting a factory scalar is refused" \
    "${REPO}/systemd/disk.service" 's/^ExecStart=/PrivateTmp=true\nExecStart=/' \
    "the unit's value is silently discarded"

gate_says "an unrecognised Freshness form is refused" \
    "${REPO}/restic/forget/restic.forget.service" 's|^Freshness=.*|Freshness=/tmp/whatever|' \
    "is not a recognised form"

gate_says "a timer without RandomizedDelaySec is refused" \
    "${REPO}/systemd/disk.timer" '/^RandomizedDelaySec=/d' "no RandomizedDelaySec="

gate_says "a timer re-declaring [Install] is refused" \
    "${REPO}/systemd/disk.timer" 's|^\[Timer\]|[Install]\nWantedBy=timers.target\n\n[Timer]|' \
    "declares its own [Install]"

# --- cases the adversarial pass earned; each defeated the gate before the fix ---
gate_says "User=0 counts as root" \
    "${REPO}/systemd/zpool.scrub.service" 's/^User=root$/User=0/;/^CapabilityBoundingSet=/d' \
    "runs as root without a CapabilityBoundingSet"

gate_says "a trailing space does not hide root" \
    "${REPO}/systemd/zpool.scrub.service" 's/^User=root$/User=root /;/^CapabilityBoundingSet=/d' \
    "runs as root without a CapabilityBoundingSet"

gate_says "the LAST User= wins, as systemd does" \
    "${REPO}/systemd/disk.service" 's/^User=carrein$/User=carrein\nUser=root/' \
    "runs as root without a CapabilityBoundingSet"

gate_says "a capability bound outside [Service] does not count" \
    "${REPO}/systemd/zpool.scrub.service" 's|^CapabilityBoundingSet=.*|#moved|;s|^\[Unit\]|[Unit]\nCapabilityBoundingSet=CAP_SYS_ADMIN|' \
    "without a CapabilityBoundingSet= in [Service]"

gate_says "an indented Condition is still refused" \
    "${REPO}/systemd/disk.service" 's/^ExecStart=/  ConditionPathExists=\/tmp\nExecStart=/' \
    "A failed Condition is a SKIP"

gate_says "ExecStart=- is refused (false healthy stamp)" \
    "${REPO}/systemd/disk.service" 's|^ExecStart=|ExecStart=-|' \
    "would be written anyway"

gate_says "SuccessExitStatus= is refused (false healthy stamp)" \
    "${REPO}/systemd/disk.service" 's/^ExecStart=/SuccessExitStatus=1\nExecStart=/' \
    "count as success"

gate_says "a monitor declaring OnSuccess= is refused" \
    "${REPO}/systemd/disk.service" 's|^\[Unit\]|[Unit]\nOnSuccess=system-ntfy@disk.service|' \
    "must not declare OnSuccess="

# The exemption must be EXPLICIT: absent is still refused, acknowledged passes.
# Otherwise "forgot to bound it" and "decided not to" look the same.
gate_says "unbounded root without acknowledgement is still refused" \
    "${REPO}/systemd/zpool.scrub.service" '/^CapabilityBoundingSet=/d' \
    "bound it, or declare"

gate_says "an adhoc watcher without Producer= is refused" \
    "${REPO}/capture/systemd/capture.triage.service" '/^Producer=/d' \
    "must declare Producer= naming what feeds it"

gate_says "MaxAge=infinity is refused (disables its own check)" \
    "${REPO}/systemd/disk.service" 's/^MaxAge=3h$/MaxAge=infinity/' \
    "does not parse to a usable finite timespan"

gate_says "a timer re-setting Persistent= is refused" \
    "${REPO}/systemd/disk.timer" 's/^OnCalendar=/Persistent=true\nOnCalendar=/' \
    "already sets"

# The prune loop once deleted the instance sticker directories this same script
# creates, because a template instance has no unit file of its own. Both restic
# check jobs came out of a real install with no MaxAge and no Freshness.
has "instance stickers are exempt from the orphan prune" \
    "$(grep -c 'template INSTANCE never has a unit file' "$INSTALL")" "1"

# ProtectHome=read-only from the monitor class blocks restic's cache, and restic
# exits 1 rather than degrading — so the job watching your backups failed nightly.
has "restic.staleness keeps its cache writable" \
    "$(cat "${REPO}/restic/staleness/restic.staleness.service")" "ReadWritePaths=/home/carrein/.cache/restic"

# And the other half: the unmutated tree must pass, or every case above is
# meaningless.
out="$(bash "$INSTALL" --check 2>&1)"
has "the real tree satisfies the contract" "$out" "contract satisfied"
hasnt "a passing check installs nothing" "$out" "Creating unit symlinks"

# ============================================================== the watchdog
#
# Fixtures live in the per-user manager so `systemctl --user cat` does the drop-in
# merging for real. HEARTBEAT_SYSTEMD_DIR points enumeration at the same place.

# Fixtures must live in the per-user unit directory for `systemctl --user cat` to
# see them — but enumeration must NOT glob that directory, because it is shared:
# any stray user unit carrying a Class= would join the roll call and break the
# counts. So the unit files go to UD for systemd, and a COPY of each goes to a
# private ENUM dir that the watchdog globs. The suite then sees exactly its own
# fixtures no matter what else is installed.
UD="${HOME}/.config/systemd/user"
STATE="$(mktemp -d)"
ENUM="${STATE}/enum"
FIXTURES=()
mkdir -p "${UD}" "${STATE}/systemd/state" "${ENUM}"

hb_cleanup() {
    for f in "${FIXTURES[@]:-}"; do [[ -n "$f" ]] && rm -f "${UD}/${f}"; done
    rm -rf "$STATE"
    systemctl --user daemon-reload 2>/dev/null
    restore
}
trap hb_cleanup EXIT

# fixture <name> <body...>  — writes a zzhb-prefixed user unit
fixture() {
    local n="$1"; shift
    printf '%s\n' "$@" > "${UD}/${n}"
    cp "${UD}/${n}" "${ENUM}/${n}"
    FIXTURES+=("$n")
}

run_hb() {
    HEARTBEAT_ADOPTED="" \
    HEARTBEAT_SYSTEMD_DIR="$ENUM" \
    HEARTBEAT_REPO_DIR="$STATE" \
    HEARTBEAT_SYSTEMCTL="systemctl --user" \
    bash "$HEARTBEAT" 2>&1
}

echo
echo "watchdog — every finding type"

fixture "zzhb-fresh.service" \
    "[Service]" "Type=oneshot" "ExecStart=/bin/true" \
    "" "[X-Catallenya]" "Class=scheduled" "MaxAge=36h" "Freshness=stamp:${STATE}/fresh"
touch "${STATE}/fresh"

fixture "zzhb-stale.service" \
    "[Service]" "Type=oneshot" "ExecStart=/bin/true" \
    "" "[X-Catallenya]" "Class=scheduled" "MaxAge=1h" "Freshness=stamp:${STATE}/stale"
touch -d '3 days ago' "${STATE}/stale"

fixture "zzhb-never.service" \
    "[Service]" "Type=oneshot" "ExecStart=/bin/true" \
    "" "[X-Catallenya]" "Class=scheduled" "MaxAge=36h" "Freshness=stamp:${STATE}/absent"

fixture "zzhb-nofresh.service" \
    "[Service]" "Type=oneshot" "ExecStart=/bin/true" \
    "" "[X-Catallenya]" "Class=scheduled" "MaxAge=36h"

fixture "zzhb-badage.service" \
    "[Service]" "Type=oneshot" "ExecStart=/bin/true" \
    "" "[X-Catallenya]" "Class=scheduled" "MaxAge=bananas" "Freshness=stamp:${STATE}/fresh"

fixture "zzhb-badfresh.service" \
    "[Service]" "Type=oneshot" "ExecStart=/bin/true" \
    "" "[X-Catallenya]" "Class=scheduled" "MaxAge=36h" "Freshness=telepathy:hope"

# Producer=: an armed watcher proves nothing can reach it.
fixture "zzhb-noproducer.service" \
    "[Service]" "Type=oneshot" "ExecStart=/bin/true" \
    "" "[X-Catallenya]" "Class=adhoc" "Freshness=unit:zzhb-nonexistent.path" \
    "Producer=container:zzhb-no-such-container"

fixture "zzhb-badproducer.service" \
    "[Service]" "Type=oneshot" "ExecStart=/bin/true" \
    "" "[X-Catallenya]" "Class=adhoc" "Freshness=unit:zzhb-nonexistent.path" \
    "Producer=telepathy:hope"

fixture "zzhb-unarmed.service" \
    "[Service]" "Type=oneshot" "ExecStart=/bin/true" \
    "" "[X-Catallenya]" "Class=adhoc" "Freshness=unit:zzhb-nonexistent.path"

# A monitor never declares Freshness — the watchdog must imply the stamp path
# from REPO_DIR, which is the one piece of the contract that lives in two places.
fixture "zzhb-monitor.service" \
    "[Service]" "Type=oneshot" "ExecStart=/bin/true" \
    "" "[X-Catallenya]" "Class=monitor" "MaxAge=1h"
touch -d '5 days ago' "${STATE}/systemd/state/zzhb-monitor"

systemctl --user daemon-reload 2>/dev/null
OUT="$(run_hb)"

has  "a fresh stamp raises nothing"        "$OUT" "ok zzhb-fresh.service"
hasnt "…and appears in no finding"          "$(grep -E '^(STALE|NEVER)' <<<"$OUT")" "zzhb-fresh"
has  "a stale stamp is STALE"              "$OUT" "STALE"
has  "…naming the job and its age"         "$OUT" "zzhb-stale.service — last completed 3d"
has  "a missing stamp is NEVER RAN"        "$OUT" "NEVER RAN     zzhb-never.service"
has  "Class without Freshness is caught"   "$OUT" "NO STICKER    zzhb-nofresh.service"
has  "an unparseable MaxAge is caught"     "$OUT" "BAD STICKER   zzhb-badage.service"
has  "an unknown Freshness form is caught" "$OUT" "BAD STICKER   zzhb-badfresh.service"
has  "a dead .path unit is UNARMED"        "$OUT" "UNARMED       zzhb-unarmed.service"
has  "a missing producer is caught"        "$OUT" "NO PRODUCER   zzhb-noproducer.service"
# A deliberately masked foreign unit (avahi is masked on this box on purpose) must
# not be reported. Only our own units count as a MASKED finding.
hasnt "a foreign masked unit is not reported" "$OUT" "MASKED"
has  "…naming the container"               "$OUT" "zzhb-no-such-container"
has  "an unknown Producer form is caught"  "$OUT" "BAD STICKER   zzhb-badproducer.service"
has  "a monitor's stamp path is implied"   "$OUT" "STALE         zzhb-monitor.service"
# The point of this one: two fixtures have deliberately broken stickers, and a
# round that aborted on the first would still print findings for everything before
# it. Only the count proves every job was reached.
has  "one bad sticker does not abort the round" "$OUT" "checked 10 job(s)"
hasnt "nothing is published under NTFY_DISABLE" "$OUT" "publish failed"
has  "…and it says so"                     "$OUT" "NTFY_DISABLE=1, not publishing"

# All-clear path: remove every unhealthy fixture, leaving only the fresh one.
for f in stale never nofresh badage badfresh unarmed monitor noproducer badproducer; do rm -f "${UD}/zzhb-${f}.service" "${ENUM}/zzhb-${f}.service"; done
systemctl --user daemon-reload 2>/dev/null
CLEAR="$(run_hb)"
has  "a healthy round says all clear" "$CLEAR" "all clear"
hasnt "…and raises no findings"       "$CLEAR" "STALE"

# The adopted units are the two whose documented failure mode is going quiet, and
# neither can appear in the symlink-based drift pass — catallenya.service is a
# regular file, sanoid's fragment lives under /usr. So "absent" must read as a
# finding, not as fine.
ADOPT="$(HEARTBEAT_SYSTEMD_DIR="$ENUM" HEARTBEAT_REPO_DIR="$STATE" \
         HEARTBEAT_SYSTEMCTL="systemctl --user" bash "$HEARTBEAT" 2>&1)"
has  "an adopted unit with no sticker is reported" "$ADOPT" "NO STICKER    sanoid.service"
has  "…including sanoid-prune"                     "$ADOPT" "NO STICKER    sanoid-prune.service"
has  "…and the boot orchestrator"                  "$ADOPT" "catallenya.service"

echo
printf 'systemd factory: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
