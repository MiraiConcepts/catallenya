# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Open work is tracked as GitHub issues** (`gh issue list`) — check there before re-deriving open items or proposing new work. This file carries decisions, traps and accepted risks (things that are never "done"); anything with a done-state belongs in an issue, and a decided-not-done issue graduates back into this file as a "do not re-raise" entry when closed.

## Project Overview

catallenya is a self-hosted infrastructure project replacing third-party cloud services with open-source alternatives. It runs on a ZFS-backed storage pool (`/zpool/catallenya`) and is orchestrated entirely through Docker Compose.

## Common Commands

```bash
# Start all services
docker compose up -d

# Start a specific service
docker compose up -d <service-name>

# Rebuild archivebox (only service with a custom Dockerfile)
docker compose up -d --build archivebox

# View logs
docker compose logs -f <service-name>

# Run the security audit
bash audit/audit.sh

# The CI shell check, run locally. Same script and same pinned shellcheck CI runs,
# so a clean result here means a clean result there. ci/pre-push runs this too.
bash ci/shellcheck.sh

# Install the tracked git hooks into this clone (idempotent). audit.sh §17 fails
# if either is missing, non-executable, or drifted from its tracked master.
bash audit/install-hooks.sh

# control plane — validate the job contract without installing (no root needed).
# Run this before committing any unit change; it is the same check install.sh runs.
bash systemd/install.sh --check
bash systemd/tests/run.sh          # offline suite: gate refusals + every watchdog finding
systemctl cat afterimage.triage.service   # see a unit's merged policy layers

# Check backup snapshots
bash restic/misc/restic.snapshots.sh

# Restore from backup
bash restic/misc/restic.restore.sh

# Immich junk-asset cleanup (find → verify → delete pipeline)
# See immich/scripts/README.md for the full pipeline.
bash immich/scripts/immich.find-junk.sh        # nominate candidates (heuristics)
bash immich/scripts/immich.verify-junk.sh      # physical playability check
bash immich/scripts/immich.delete.sh --dry-run # preview; drop --dry-run to act

# Immich date recovery (scan → verify → apply pipeline)
# Reconstructs fileCreatedAt from EXIF / filename / ffprobe / mtime — the clue-reading
# half is shared: immich.dates.lib.sh, sourced by BOTH scan and verify. It used to be
# copied into each, which meant a pattern taught to scan alone made verify re-read the
# row as empty, call it UNSTABLE and rescue it — a whole category of fixes silently
# never applying. Requires exiftool: sudo apt install -y libimage-exiftool-perl
bash immich/scripts/immich.fix-dates.scan.sh   --date-cluster=2023-02-19 --limit=100
bash immich/scripts/immich.fix-dates.verify.sh
bash immich/scripts/immich.fix-dates.apply.sh  --dry-run

# Immich rotation bake (lossless EXIF orientation for UI rotate edits)
# Runs daily at 04:00 SGT via immich.fix-rotations.timer; manual run:
bash immich/scripts/immich.fix-rotations.sh --dry-run   # preview
bash immich/scripts/immich.fix-rotations.sh --yes       # apply now

# Documents intake (drop → propose → tap Accept/Discard)
# Event-driven, not scheduled. pigeonhole.triage.path fires when a file lands at the
# root of syncthing master/documents; the document is staged under its proposed name
# and you approve from ntfy. State IS the directory: root → staging → (folder | bin).
sudo systemctl start pigeonhole.triage.service   # classify + stage whatever is at root now
bash pigeonhole/tests/run.sh                     # offline suite (path safety, state machine)

# Capture pipeline (screenshot → opus-5 vision → ntfy Add/Discard → Radicale)
# Event-driven, not scheduled: afterimage.triage.path fires the moment a PNG lands in
# afterimage/data/incoming/. Laptop hotkey client + notification format in afterimage/README.md.
sudo systemctl start afterimage.triage.service      # drain incoming/ now (systemd injects the API key)
bash afterimage/scripts/afterimage.sweep.sh --dry-run  # nightly 07:30 SGT: re-notify, archive, prune, strays
# Outcome counts. No ledger — each archived record carries its own decision.json.
jq -s 'group_by(.outcome)|map({outcome:.[0].outcome,n:length})' afterimage/data/archive/*/decision.json
```

## Architecture

### Network Topology

Traffic flows through two paths:
- **Tailscale (internal)**: All services are accessed via `${TAILNET_DOMAIN}.${TAILNET_DNS_NAME}:<port>` through Caddy reverse proxy with auto-TLS from Tailscale
- **Cloudflare Tunnel (external)**: Internet-facing services (zipline) route through `cloudflared` to `*.catallenya.com`. For `catallenya.com` itself, cloudflared terminates TLS at the CF edge and forwards to Caddy's internal `http://catallenya.com` block, which path-splits `/api/votes/*` to `upvotes:8080` and everything else to `carrein-blog:80`. Tunnel ingress rules live in the Cloudflare dashboard, not in this repo.

Caddy reads the Tailscale socket directly (`tailscaled.sock`) for certificate management. The Tailscale container must use `hostname: catallenya` because generated certificates are tied to this name.

### Port Assignments (via .env)

| Variable                         | Service     |
|----------------------------------|-------------|
| `NTFY_REVERSE_PROXY_PORT`        | Ntfy        |
| `FLAME_REVERSE_PROXY_PORT`       | Flame       |
| `RADICALE_REVERSE_PROXY_PORT`    | Radicale    |
| `SYNCTHING_REVERSE_PROXY_PORT`   | Syncthing   |
| `IMMICH_REVERSE_PROXY_PORT`      | Immich      |
| `ARCHIVEBOX_REVERSE_PROXY_PORT`  | Archivebox  |
| `MEMOKA_REVERSE_PROXY_PORT`      | Memoka      |
| `CHANGEDETECTION_REVERSE_PROXY_PORT` | Changedetection.io |
| `AFTERIMAGE_REVERSE_PROXY_PORT`     | Capture (10000) |

### Service Dependencies

- **Immich** depends on `redis` (Valkey) and `postgres` (custom pgvector image)
- **Memoka** depends on its own `memoka_postgresql` (pgvector/pg17) and `memoka_redis`
- **Zipline** depends on `zipline_postgresql`
- **Archivebox** uses `archivebox_sonic` for search; scheduler depends on both
- **Caddy** depends on `tailscale` for TLS certificate socket
- **carrein-blog** (`ghcr.io/carrein/carrein-blog`) and **upvotes** (`ghcr.io/carrein/upvotes`, Bun + SQLite) sit behind Caddy's `http://catallenya.com` block — no host port mapping; reached only via the cloudflared tunnel
- **Capture** is a locally-built Bun container (like archivebox, no GHCR image) on `AFTERIMAGE_REVERSE_PROXY_PORT` (10000) with no host `ports:`. It is deliberately dumb — it accepts the uploaded screenshot and, on an ntfy button tap, does one CalDAV `PUT` to `radicale:5232` reusing the same `MITSUME_DAV_B64` Caddy injects for mitsume. All the intelligence (the opus-5 vision call, the `.ics` renderer) lives in the host triage, which shares only the `afterimage/data/` spool with the container; that split is kept so the triage can serve future non-capture consumers
- **Changedetection** has **no browser companion** as of 2026-08-02. The `changedetection-browser` sidecar (sockpuppetbrowser, Chromium via Playwright over WebSocket, `cap_add: SYS_ADMIN` for the user-namespace sandbox) was removed along with the last `html_webdriver` watch — it was idling at ~300M with no consumer. Every remaining watch is a plain `html_requests` fetch of a Shopify JSON endpoint, so **any watch set to `html_webdriver` will error until the sidecar is restored** (git history has the block; it also needs `PLAYWRIGHT_DRIVER_URL` and a `depends_on` back on the main service). The main container still needs `CHOWN/FOWNER/DAC_OVERRIDE` because the image runs as root and writes to a non-root-owned bind mount. Notifications fan out via ntfy using Apprise URL `ntfy://ntfy/${CHANGEDETECTION_NTFY_TOPIC}` — configured in the UI, not in env. **changedetection cannot self-report a broken watch**: fetch errors and site-down never notify, and with `jq:`/`json:` filters the filter-failure push never fires either (a jq array filter returns `[]`, which is non-empty, so `FilterNotFoundInResponse` is never raised).

### Shared AI Layer

`ai/scripts/ai.lib.sh` is the **only** place that talks to `api.anthropic.com`, called by
`afterimage.triage.sh` and `pigeonhole.triage.sh`; `AI_MODEL`/`AI_EFFORT` (opus-5 / high) live
there too, so a model bump is one edit for both pipelines. **Every consumer is now an API
caller**, so a change here has exactly the blast radius the header claims. `md_escape`/`hdr_safe`
moved OUT to `ntfy/ntfy.lib.sh` on 2026-08-10 — they guard the boundary where untrusted text
reaches a NOTIFICATION, which belongs to the sink rather than to the API that fetched the text,
and keeping them here meant `liquidroom.lib.sh` sourced this whole layer while calling no API
at all. It no longer sources it. `ai_reason()` stays here, because only this file knows that
rc 3 means an account that cannot pay rather than a network that will not answer. Requests carry **no `tools` key** —
containment is a property of the endpoint, not something the scripts arrange; never add one.
`ANTHROPIC_API_KEY` is in `/etc/ai.env` (root 0600), never in `.env`. Surface, traps, tests, and why a library rather than a container: `ai/README.md`. Publishes as the `inference` mirror (see § CI/CD) — the directory keeps its short sourceable path, the published name says what it is.

### Secrets Management

Docker secrets are used for sensitive values (stored as gitignored files under their respective service directories). Additional credentials (DB passwords, service secrets) are in `.env`, which is also gitignored.

### Backup System

Restic backs up to cloud storage via Rclone (configured in `restic/restic.conf`). Managed by systemd timers:
- `restic.backup.timer` - scheduled backups. `OnCalendar=daily` + `RandomizedDelaySec=3600`, so the window is **00:00–01:00**, not the "00:20" this line claimed until 2026-08-20 — that was an observed start time, and reasoning about window collisions from it would mislead you
- `restic.check-subset.timer` - monthly (1st, 03:00) full structural check plus a rotating **sixth** of the pack data via `--read-data-subset=$(( ($(date +%-m) - 1) % 6 + 1 ))/6`, so the whole repository is read twice a year and no run holds its exclusive lock longer than ~1h25m. **The month number is what makes it rotate** — a hardcoded `1/6` would re-read the same sixth forever and never touch the other five, looking healthy while verifying 17% of the repo — and the `% 6 + 1` is what folds months 7-12 back onto buckets 1-6; without it those months would name a bucket that does not exist and restic would read **zero packs and still exit 0**. No `10#` guard is needed because `%-m` is unpadded, but a weekly variant on `date +%V` would need one: that pads, `08`/`09` are invalid octal, and the check would hard-fail two weeks a year. The subset replaced `restic.check-meta.timer` (quarterly), retired 2026-08-07, because `check` always does the full structural pass and meta was strictly redundant; `check.sh meta` still exists for a manual run. **`restic.check-data.timer` — the yearly full `--read-data` — was REMOVED 2026-08-22; do not re-raise.** It was justified here and in `check.sh` as "the only thing that closes the gap where `n/12` is recomputed each month against a pack set that keeps changing", and that was simply false: `selectPacksByBucket` in restic's `cmd/restic/cmd_check.go` assigns a pack with `(uint(pack[0]) % totalBuckets) == (bucket - 1)`, the first byte of the pack ID, which is immutable. Nothing is recomputed and nothing drifts, so a completed rotation reads every pack that survived it — exactly what a full read promises. The move to `n/6` is what makes the removal net-neutral: the pair together read two full sweeps a year, and `n/12` alone would have been one. Worst-case time a corrupt pack sits unseen went 12mo → **6mo**, and the longest exclusive lock in the system went 8h30m → 1h25m. `check.sh data` survives for a manual full read, like `meta`. Its scheduling was also the single most awkward thing in the fleet, which is corroboration rather than the reason: it sat on `*-05-01 00:00` until 2026-08-09, colliding with the nightly backup (both drew 00:00–01:00; whichever lost simply died), with `check-subset` from 2027, and with `forget` in years where 1 May is a Monday (2028) — hence the hand-placed second Tuesday of May that is now gone too. Note `t` is capped at 256 (restic buckets on one byte); above that it silently reads nothing
- `restic.forget.timer` - prune old snapshots (retention: 5 daily, 2 weekly, 3 monthly, 1 yearly). **0.19.0 repacks small packfiles more aggressively by default** (Chg #5293; `--repack-small` deprecated), so the first prune after the 2026-08-09 upgrade — Mon 2026-08-10 — will rewrite far more packs than usual: longer run, a one-off spike in B2 transfer. Expected, not a fault, and it does not recur
- `restic.staleness.timer` - daily 09:00, alerts the `restic` ntfy topic when the newest snapshot is >48h old. `OnFailure=` only fires when a run FAILS; a run that never STARTS fails nothing, so this is the only thing that notices a disabled timer, a unit missing after a rebuild, or a box left powered off. No `OnSuccess=` — silence is the healthy state. It reads `max_by(.time)` over **all** snapshots, never `--latest 1`: `--latest` is per *group*, and this repo has 18 groups, so `--latest 1 | .[0]` returns the oldest group's newest and reported the repo 17186h stale while backups ran fine nightly

**restic is hand-managed and OFF apt as of 2026-08-09 — nothing updates it automatically.** `/usr/local/bin/restic` is upstream **0.19.1**, installed by hand; apt's `0.16.4` remains at `/usr/bin/restic` as an untouched fallback. systemd's service `PATH` is `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin`, so units resolve the new binary. Watchtower only manages containers and unattended-upgrades only manages apt, so **neither touches this** — upgrading is a manual job: verify the GPG signature against `restic.net/gpg-key-alex.asc` (key `CF8F18F2…A907`), then `sudo install -m 0755 restic /usr/local/bin/restic`. Rollback is `sudo rm /usr/local/bin/restic`, which silently reverts to 0.16.4 — that silence is the cost of shadowing rather than `apt remove`. Ubuntu 24.04 can never provide a newer restic: apt is frozen at 0.16.4 in every pocket and `self-update` is patched out of the Debian build.

**Locks.** The 2026-08-07 outage: a `timeout 25 … check --read-data-subset` probe was SIGTERM'd 15s after taking an **exclusive** lock, and 0.16.4 registered its cleanup handler for **SIGINT only**, so it died without releasing — three nights of backups then failed at `lock repository`. Upstream fixed this in 0.17.0 (Bugfix #4703) and the 0.19.1 upgrade closes it; verified side-by-side on this box, SIGTERM leaves 0 locks on 0.19.1 and 1 on 0.16.4. **The mitigations stay anyway** — SIGKILL, OOM and power loss still orphan a lock, and this host [has no UPS](.claude/memory/power-loss-hard-off-no-ups.md). `backup.sh`, `check.sh` and `forget.sh` each prepend `restic unlock` and pass `--retry-lock=30m`; the two cover different failures and neither substitutes for the other — **`unlock` deletes a DEAD lock, `--retry-lock` waits out a LIVE one.** A live run is never collected: restic refreshes its own lock every 5 min and self-aborts at 22.5 min if it cannot, so a running job's lock can never reach the 30 min staleness threshold. The staleness rule is age-**first** (`Stale()` returns true on age alone, before hostname or PID are consulted) — the PID probe only decides locks younger than 30 min, so PID reuse cannot strand an old one. Known gap: `unlock` runs once at the start and the retry loop never re-runs it, so a lock going stale *during* a wait costs one cycle and self-heals on the next run.

**The restic jobs print a RECEIPT, not restic's output** (2026-08-22). All three wire
`OnSuccess=`/`OnFailure=` to `ntfy/system-ntfy.sh`, whose body is the job's own stdout
for that invocation — and restic writes for an 80-column terminal, so at phone width
every line wrapped mid-content and the padding became noise. `forget` was the worst:
its stdout is the entire keep/remove table across all 18 groups, **8,238 lines** in the
capture used to build this. `restic/restic.lib.sh` holds the plumbing: restic's output
goes to **stderr** (the journal keeps every word) and a short `•`-marked receipt goes to
**stdout**. **The failure path is unchanged, which is why this is done by redirecting
rather than trimming** — `set -euo pipefail` aborts before the receipt, leaving stdout
empty, and `system-ntfy.sh`'s existing fallback re-queries the journal *without* the
transport filter, so a failure still shows restic's raw error. Verified both ways with a
stubbed `restic`. `pipefail` is load-bearing: without it `tee` returns 0 and a failed
backup reports success. Counts are **summed across groups**, never read from the first
block — `keep N snapshots:` appears once per group, and reading the first is the same
mistake `restic.staleness` made with `--latest 1`. `RESTIC_FACT_MARK` duplicates
`BODY_FACT_MARK` deliberately (these jobs do not notify, the courier does, so sourcing
the whole ntfy transport for one character would be liquidroom's mistake); `ntfy/tests/run.sh`
asserts the two agree.

**Database backup strategy:**
- **Memoka**: `pg_dump` runs before restic on each backup, writing to `memoka/backup/memoka.dump.sql.gz`. Raw `memoka/postgres` and `memoka/redis` dirs are excluded from restic (unsafe to copy live). On restore, start `memoka_postgresql` first, load the dump via `psql`, then start remaining services (see `restic/misc/restic.restore.sh` for exact commands).
- **Immich**: Handles its own DB backup internally — dumps are written to `immich/data/backups/` which restic picks up automatically.
- **Upvotes**: SQLite `VACUUM INTO` runs inside the upvotes container before restic, writing to `upvotes/dump/votes.db`. Live `upvotes/data` is not in restic targets — only the consistent dump is. Restore: stop upvotes, copy dump back to `upvotes/data/votes.db`, remove stale `-wal`/`-shm`, restart.
- **Restore target is `/mnt/restore`, deliberately OFF the pool** (2026-08-10). A full restore measures 1.549 TiB against 1.76T free: `/zpool/restored` fit by only ~210 GiB, pushed the pool past the 75% `disk.timer` alert, and — single dataset — the restored copy was captured by Sanoid, so deleting it reclaimed nothing for 14 days. Mount external media there, or use `--include` for a partial restore. Measured RTO at the throughput seen during a real read-data check (34–40 MiB/s from B2): **~12 hours** for a full restore, transfer time only, before rebuilding a host or recovering the repo password.
- **Syncthing exclude is `config/index-v2`, not the whole `config/` dir** (narrowed 2026-08-10). The old exclude was justified as "unsafe to copy while running" — true of the 213M LevelDB, not of the 36K beside it: `config.xml` holds every folder definition and device share, and `key.pem`/`cert.pem` ARE the device identity. Excluding those meant 567G of data restored fine and came back as a **new device ID**, with every peer re-accepting the node and every folder reconfigured by hand. `index-v2` regenerates by rescanning.
- **Zipline**: Not backed up (intentional).
- **Capture**: Not backed up (intentional). `afterimage/` is deliberately absent from restic's path allowlist — a screenshot can hold anything that was on screen, so none of it leaves the box. ZFS + Sanoid still cover disk failure. Do not add `afterimage/` to restic without revisiting that decision. The same holds for `pigeonhole/intake-state/`: it was never a target either, and the documents themselves are covered via `syncthing/data`.

**B2 versions and retention — investigated 2026-08-07; the first is closed, do not re-raise.** restic's rclone backend spawns `rclone serve restic --stdio --b2-hard-delete` **by default** (the literal string is in the restic binary), so every delete restic makes is a real `b2_delete_file_version`, never a hide. The bucket was verified empty of debris: 102,641 objects live and 102,641 across all versions, byte-identical; zero version-suffixed names; `rclone backend cleanup-hidden --dry-run` found nothing; zero pending multipart uploads. `lifecycleRules` is `[]` and that is correct — nothing accumulates for a rule to reap. `hard_delete = true` was added to `[backblaze]` the same day; it changes **nothing** for restic and only makes a hand-typed `rclone delete` permanent, which is the intended behaviour. A lifecycle rule (`daysFromHidingToDeleting`) and B2 Object Lock were both considered and rejected — the first has near-zero benefit because restic's content-addressed names mean it essentially never overwrites, the second fights `prune`. Separately, and still **open**: `forget` runs with restic's default `--group-by host,paths`, so every historical edit to `RESTIC_BACKUP_TARGETS` starts a new group whose cohort then freezes permanently (nothing new arrives to push it out of "keep last 5 daily"). Result is 80 snapshots across 18 groups reaching back to 2024-08-20 where the written policy alone would keep 8 reaching back to 2026-06-30 — measured cost of that entire stranded history is **239 GiB of 1,685 GiB unique (~14%, roughly $1.50/month)**, because deduplication makes it far cheaper than the snapshot count suggests. Left as-is deliberately; the history is worth more than the saving. Converting it to a chosen policy means `--group-by ''` (optionally with a larger `--keep-yearly`), which is an open decision, not a defect.

ZFS snapshots are managed by Sanoid separately.

### The Control Plane

**Called the control plane for what it does — declare policy, admit or refuse, verify — and living in `systemd/` for what it is made of.** Both names are accurate on different axes; neither replaces the other, and the directory is deliberately not renamed (see § CI/CD). It publishes as the `controlplane` mirror. One caveat on the borrowed term: this plane **reports** drift and does not reconcile it — a watchdog finding is a notification, never a restart.

**Every job inherits its policy from layered drop-ins; no job declares it itself.** `systemd/policy/` holds seven files, linked by `install.sh` into each unit's `.d/` directory:

```
<unit>.service.d/10-base.conf      every job          what it is
<unit>.service.d/20-<class>.conf   how it's triggered scheduled | monitor | adhoc
<unit>.service.d/30-<family>.conf  what it talks to   intake | restic
<unit>.service                     the job itself     (weakest layer)
```

Each layer can **set** (inherited, final) or **require** (the gate refuses to install without it). Class is *how a job is triggered*; family is *what it touches* — they cross-cut, so `afterimage.sweep` is `scheduled`+`intake` while `afterimage.triage` is `adhoc`+`intake`. A job declares `Class=`/`Family=` in its own `[X-Catallenya]` block; nothing repeats that in a map. `system-ntfy@.service` is **plumbing**, not a job — it inherits nothing, or a failed alert would call the courier to complain about the courier.

**`sudo bash systemd/install.sh` is the gate.** It validates every unit against its class contract and **aborts before creating any link** if one fails — never half-configured. `bash systemd/install.sh --check` runs validation only, needs no root, and is what to run before committing a unit change. `bash systemd/tests/run.sh` is the offline suite: it proves the gate refuses each forbidden shape and the watchdog raises each finding type. **The suite's check tree is built from a hardcoded directory list** (`find systemd restic host changedetection ntfy afterimage/systemd …`) — a unit whose directory is missing there is simply absent from the tree, so a mutation case edits a file that is not there and the gate finds nothing to refuse. That reads as *the gate stopped working*, not as *the test is misconfigured*: it broke 23 cases when jobs moved out of `systemd/` on 2026-08-15, and `liquidroom/systemd` had been silently uncovered since it shipped. Add the directory when you add a unit anywhere new.

**Four blind spots the gate had until 2026-08-19, all found by audit and all now refused.** They share one shape: a check that read the file differently from the thing that would eventually run it.
- **A directive in the wrong section satisfied a REQUIREMENT.** `has_key()` fell back to a whole-file grep, so `TimeoutStartSec=` moved into `[Unit]` passed while systemd ignored it and the oneshot default (**infinity**) applied — the exact regression the scheduled class exists to prevent — and `User=` in `[Unit]` meant a job the gate believed ran as `carrein` actually ran as **root**, with the unbounded-root check skipped because it reads `[Service]` only. Requirements are section-aware now; `has_key_anywhere()` keeps the blunt search for **prohibitions**, where matching a misplaced `RuntimeMaxSec=` anywhere is the conservative direction.
- **A wrapped `notify` hid a `high` priority.** `contract.sh`'s content checks are line-shaped and bash is not: the one loud call left in the repo put `high` on a continuation line and passed `--check` clean. Comments are stripped, then continuations **joined**, before anything is matched — in that order, because a backslash ending a comment continues nothing.
- **A committed-but-unregistered unit validated nothing.** The validate loop walked the hand-maintained `SYMLINKS` map, never the tree, so a unit file with six violations reported "35 units satisfy the contract" — and having no symlink, it never reached the watchdog either. Units are discovered (via `git ls-files`, falling back to the same directory list the suite uses) and an unregistered one is now a refusal.
- **`.path` units were dispatched nowhere.** They received nothing beyond source-exists; a `.path` full of garbage, or carrying the banned `Condition*=`, passed clean.

The suite had a matching flaw: it reset only the unit each case mutated, so mutations accumulated and two adversarial cases were passing on a **neighbour's** error message rather than their own. The tree is restored pristine before every case — the fix that makes a test failure mean what it says.

**Where a job's files live (settled 2026-08-15).** A job's unit and its body sit **together, in the directory of whatever the job is about** — `afterimage/`, `pigeonhole/`, `liquidroom/`, `restic/`, `immich/`, `changedetection/`. Ten of fifteen jobs already worked this way; the rest were in `systemd/` only because nobody enforced it. Three directories are therefore not features:
- **`systemd/`** — the contract itself: `policy/`, `install.sh`, `tests/`, and the one job whose subject *is* the contract (`catallenya.heartbeat` + `heartbeat.sh`). Nothing else.
- **`host/`** — jobs whose subject is the machine and which have no owning feature: boot (`catallenya.sh`), `disk`, `zpool.scrub`. This is where the deferred SMART job goes, and UPS/NUT and an off-box dead-man's switch if they are ever built.
- **`ntfy/`** — the **message layer**: the transport (`ntfy.lib.sh`), the title constructors (`kinds.sh`), the contract (`MESSAGES.md`) and the courier (`system-ntfy.sh`). Restated from "transport only" on 2026-08-20, when the contract landed — the old wording was accurate while this held one curl wrapper and stopped being so the moment it held the grammar too. Still not "scripts that notify": nearly every job notifies and none of them live here.

The retired rule was "scripts that publish to ntfy live in `ntfy/`", which sorted by output medium and so decided nothing — `heartbeat-ntfy.sh` was in it while `restic.staleness.sh` was not, on nothing but authorship date.

**A stamp path is `%N` and does not follow a rename.** `10-base.conf` writes `state/%N`, so a renamed unit writes a new stamp while its own `Freshness=stamp:…` still names the old one — the watchdog then reports that job stale **forever**, having been told to look at a file nothing will ever write again. Caught on `afterimage.sweep` after the 2026-08-15 rename. **`Producer=` has the same property and bites a second way**: it names a CONTAINER, so renaming the container behind a job leaves the watchdog hunting a name nothing answers to — `afterimage.triage` reported `NO PRODUCER … container 'capture' does not exist` for a day while the feeder was running happily as `afterimage`. Neither is caught by the gate: `install.sh` validates `Producer=`'s FORM (`container:<name>`) and deliberately never asks docker whether that container exists, because `--check` must run without docker, so a stale name passes clean and surfaces a day later at the watchdog. After renaming a unit **or a container**, grep both `Freshness=stamp:` and `Producer=container:`, delete the orphaned file in `systemd/state/`, and run `bash systemd/heartbeat.sh` — the watchdog is the only thing that reads either one.

**Three traps this encodes, all verified on this box:**
- **Drop-ins outrank the unit file** for scalars (a unit's `RuntimeMaxSec=999` lost to a drop-in's `111`). So only genuinely invariant settings may be *set*, and the gate refuses a unit that re-declares one — a line that does nothing reads as configuration and is a lie.
- **`RuntimeMaxSec=` is IGNORED on `Type=oneshot`** while `systemctl show` still reports it. Every job here is oneshot, so `TimeoutStartSec=` is the only working hang bound. The gate refuses `RuntimeMaxSec=`.
- **`Condition*=` is banned in favour of `Requires=`.** A failed Condition is a *skip*, not a failure: no exit code, no `OnFailure=`, no journal error. That is how sanoid stopped snapshotting silently, and why `catallenya.service`'s old `ConditionPathIsMountPoint=/zpool` made a failed pool mount invisible.

**`restic.check@subset` is `Class=scheduled`, NOT `monitor`** — despite the name. It holds an exclusive repository lock for ~1h25m; under the monitor class's 10-minute timeout systemd would kill the monthly integrity pass ten minutes in, every month. Its per-instance `MaxAge`/`Freshness` live in `restic/check/instance-subset.conf`, because systemd ignores the `[X-Catallenya]` section entirely and therefore never expands `%i` inside it — a template cannot carry per-instance metadata. One instance does not make that drop-in redundant. `restic.check@data` shares the template and inherits the same class on a manual run, but carries **no sticker on purpose**: it is manual-only since 2026-08-22 and an on-demand job has no cadence to be stale against.

### The Watchdog

`catallenya.heartbeat.timer` (daily 08:15 SGT) answers the question nothing else could: **did each job actually run, and did it do anything.** Silent when healthy; findings go to the `host` topic — the same channel boot events use. It reads each job's `[X-Catallenya]` sticker from the merged view, so a job registered with `install.sh` is covered automatically — and a job that escaped the contract is itself a finding.

| Class | What "fresh" means |
|---|---|
| `scheduled` | declared `Freshness=` — `stamp:<path>`, `zfs-scrub:<pool>` or `zfs-snapshot:<dataset>` |
| `monitor` | implied stamp at `systemd/state/<unit>` |
| `adhoc` | `unit:<name>` — the `.path` unit must be active. No `MaxAge`: no cadence exists |

**Jobs record their own completion because systemd cannot.** Its runtime timestamps are per-boot — `zpool.scrub.service` reports `Result=success` with *every timestamp empty* because it last ran before the current boot. The stamp is written by `ExecStartPost=-/usr/bin/touch …/state/%N` in `10-base.conf`, which systemd runs **only when `ExecStart` succeeded**, so no script had to change and none can record a false success. The `-` prefix means a failed stamp cannot fail the unit; it goes stale instead, which fails toward noticing.

`zpool.scrub` uses `zfs-scrub:` rather than a stamp deliberately: `zpool scrub` returns in about a second, so a stamp would record that the scrub was *requested*. Sanoid is covered too — it is a vendor unit given a sticker by `install.sh`, which is why the watchdog identifies jobs by "declares a Class" rather than "is one of our symlinks".

**Known regress, ACCEPTED 2026-08-13 — do not re-raise without new information.** The heartbeat is the one unit nothing watches. A crash is covered by the inherited `OnFailure=`; a heartbeat that never *runs* is silent.

This is irreducible on-box: any watcher-of-the-watcher needs a watcher itself, forever. The only shape that escapes it is an **off-box dead-man's switch** — the box pings an external service on a schedule and that service alerts when the ping *stops*, so silence becomes the alarm rather than the failure mode. **Your own ntfy cannot serve this**: it runs as a container on this host, so it dies with the box, and ntfy has no concept of a message that failed to arrive — it relays what you send, nothing more. It would need something like healthchecks.io (free tier); `NTFY_FAILURE_URL` in CI is the existing precedent for reaching a service outside the tailnet.

Declined deliberately. The exposure is one blind spot replacing six, and it only bites if the heartbeat *and* whatever it would have caught both fail. Against that, an external dependency and an account are a real cost for a personal box whose owner would notice it being dead by other means. Revisit if the machine ever becomes something others depend on.

### The Message Contract

**Titles are built by constructors, not written by hand.** The full contract — the
class model, all 22 verbs, the 15 deliberate exceptions, every title in the system —
is **`ntfy/MESSAGES.md`**, which is written to one test: *everything is lost, someone
has that file, can they rebuild this?* Read it before adding a notification anywhere.

Why it exists: 32 emission points across 12 files grew **six incompatible grammars**
in about a year. The transport was unified on 2026-08-10, but that standardised the
wire, never the message.

| Class | Source | Vocabulary |
|---|---|---|
| **Model** | `ai/scripts/ai.lib.sh` | **identical across pipelines** — `Model Failed`, `Model Paused` |
| **Policy** | the same rule implemented twice | shared by choice — `Abandoned` |
| **Situation** | different code, same predicament | shared by choice — `Flagged`, `Stuck`, `Refused`, `Skipped`, `Stranded` |
| **Service** | one pipeline's own machinery | independent |

Constructors in `ntfy/kinds.sh`: `title_count` (a report), `title_state` (a fault or
receipt), `title_quote` (a quotation), plus `title_mark`/`title_pos`/`title_age` for
the bracketed qualifiers. Vocabulary is declared **per feature** (`NTFY_VERBS`,
`NTFY_NOUNS`, `NTFY_SUBJECTS`) — the same shape as `[X-Catallenya] Class=`, because a
central verb table would be the `SUBSCRIBED` list again.

**The bodies, phase 3 (2026-08-21).** Every notification in the repo is now built by
four renderers in `ntfy/kinds.sh` — `body_list`, `body_fact`, `body_aside`, `body_join`
— and **`NTFY_MARKDOWN` is gone**. It had been a per-consumer opt-out with five users,
all for the same reason: bodies machine-built from text this box does not author, where
a camera filename comes out with its middle italicised and a name arriving over
Syncthing could hide a live link. The renderers escape every line, so rendering is safe
everywhere rather than switched off in the five places it was dangerous — and with
nothing setting it, the flag was a slot waiting for someone to put `no` in it, exactly
what priority was. **`body_join` escapes nothing and must not** (its arguments are
already rendered), which makes the PROSE argument the caller's to escape.

Four shapes and nothing else — **item**, **detail** (indented under its item), **fact**
(`•`), **prose** — in the order items → facts → prose. **A fact carries no stub label
and must read as a complete statement**: `• 400G free`, never `• Free: 400G`, and
`• Estimated time left: 70m`, never the `• about 70m` that a no-labels rule read
literally produces. A detail may be labelled, because it hangs off the item above it;
a fact stands alone and has to describe itself. **No full stop on any line but prose.**
**Italics mean a truncation count and nothing else** — three forms, all from
`body_aside`. **The marker is `•` U+2022** (changed 2026-08-22 from `▪` U+25AA, which has an emoji
presentation and rendered as a coloured square on some Android builds). It needs no
escape, unlike `-`/`*`/`+`, which markdown turns into real list markers. It collided with
afterimage's `" • "` alternatives separator, which moved to `" / "` the same day — **do
not restore `" • "` there without moving the marker**. Full contract in
`ntfy/MESSAGES.md` § 3.

**afterimage's `reason` stays model-written prose — the planned phase 4 was measured
and declined, do not re-raise.** The plan was to have the model return a CODE, as
pigeonhole does (`reason_text`, `flag_clause`), which would make "no em-dashes" a grep
over `case` arms. Checked against the archive rather than assumed: across 115 records
the one stored `needs_human` reason is a specific paragraph naming what the screenshot
showed, what was missing and what it said instead, and `NO_RESOLVABLE_DATE` → "No date
could be resolved." throws all of that away. **The two pipelines differ in what the
reason is ABOUT** — pigeonhole's describes a failure to read a FILE, and those failure
modes are finite; afterimage's describes what a SCREENSHOT SHOWED, which is not. The
style rules live in the prompt instead, which is weaker than a gate and is the honest
place for them: nothing static can check a sentence the model has not written yet.

**The envelope, phase 2.** There are **no tags and no priority** anywhere — both left
`notify()`'s signature on 2026-08-20. Priority had exactly one legal value, so it was a
slot waiting for someone to put `high` in it; tags were twelve glyphs of which four meant
"something is wrong" and the rest named the pipeline, which the topic already says.
`notify()` is now `notify <title> <body> [actions] [seq-id]` and is not called outside
`ntfy/` — every job goes through a **kind**: `notify_proposal`, `notify_nudge`,
`notify_resolved`, `notify_fault`, `notify_receipt`. The kind decides which arguments
exist, so a receipt has nowhere to put a button and a proposal cannot omit the sequence
id that makes it withdrawable. With tags gone the kinds render identically; their value
is entirely structural.

**The withdrawal rule (owner, 2026-08-20): a notification WITH buttons may be withdrawn;
one WITHOUT buttons never is.** An actionable message goes when its tap resolves it, or
when afterimage's archive backstop finds its buttons answering 404. Everything else stays
until swiped, because an absent notification is ambiguous — fixed, mis-swiped, or never
sent — while a stale one is not. **This deliberately reverses the 2026-08-19
`paused_sync()` change** (see § Withdrawing an ntfy notification) and is not a
regression. Repeating faults instead carry a **stable sequence id** so they replace
rather than stack — `host/disk.sh` runs hourly, and a pool over threshold across a
weekend used to produce forty-five notifications.

`systemd/contract.sh` enforces eight rules at `--check`. Three are about the title: it
comes from a constructor (following a variable to its assignment); its verb is declared;
and every declared verb ends in `ed` or is in `NTFY_IRREGULAR_VERBS` (today: `Stuck`) —
which is what stops a new service breaking the past-participle rule silently, refusing
`Processing` **and** `Stray`/`Unclear`, both proposed during design. Three are about the
envelope: no bare `notify` outside `ntfy/`, no `clear=true` in an Actions string, and a
`notify_nudge` title must read as a nudge (`Still ` or an age bracket). **Two are about
the body**, added 2026-08-21 with the renderers: no hand-built numbered list, and no
hand-built italic line. The second looks for an underscore run closing before a quote
rather than a leading `"_`, because that is the shape `paused_body` shipped in for a
year — italics inside a `printf` *format* string. **A ninth refuses markdown link syntax
in a body** (`](http`): the renderers escape links out of everything untrusted, but PROSE
reaches `body_join` unescaped, so a hand-authored one is the only way a live link gets
into a notification. **A bare URL is deliberately allowed** — link syntax HIDES its
destination behind friendly text, which is what makes it dangerous inside a message the
reader already trusts, while a bare URL shows where it goes; escaping one would mean
mangling `:` and `/`, and changedetection's body ends with a real one on purpose.

**The loan from `systemd/policy/` is weaker than it looks, and this is the thing to
know before trusting it.** systemd has a real merge engine, so its layering holds even
when `install.sh` is wrong. There is none here: nothing at runtime stops a caller
passing `notify()` a hand-built string. **The gate IS the layering**, not a check on
it. `ntfy/system-ntfy.sh` is the single exemption — it sources nothing on purpose, so
it matches the grammar by hand and the gate checks it by pattern.

### Boot Orchestration

`catallenya.service` is a oneshot systemd unit that runs at boot after ZFS and Docker are ready. It is the **one unit file that lives on root filesystem** (`/etc/systemd/system/catallenya.service`) — all other project units are symlinks into `/zpool/catallenya/` which don't resolve until ZFS mounts. It is written by `install.sh`, so edit it there and never in `/etc`.

**What it does** (via `host/catallenya.sh`):
1. `systemctl daemon-reload` — re-reads unit files now that ZFS symlinks resolve
2. Starts all project timers
3. `docker compose up -d` — brings up containers (as `carrein`)
4. Verifies all containers reach `running` state
5. Posts success/failure notification to the ntfy `host` topic (renamed from `boot` on 2026-08-13; it now carries watchdog findings too)

**Key commands:**
- `systemctl status catallenya` — check boot state (green = all OK)
- `sudo bash systemd/install.sh` — set up systemd on a fresh server (writes service, creates symlinks, enables everything). Idempotent.
- `journalctl -u catallenya` — boot orchestrator logs

**Editing `OnCalendar=` fires a catch-up run — every project timer sets `Persistent=true`** (now inherited from `systemd/policy/10-base-timer.conf` rather than declared in each). That flag exists so a run missed while the box was off happens on next boot, and it works by comparing the schedule against `/var/lib/systemd/timers/stamp-<unit>.timer`. Change the calendar so that **any occurrence under the NEW rule falls after the stamp**, and the next `daemon-reload` starts the unit immediately — systemd believes it overslept. Moving `restic.check-data` (since retired) from `*-05-01 00:00` to `Tue *-05-08..14 05:00` on 2026-08-09 did exactly this: the new rule's 2026-05-12 sat after a 2026-05-01 stamp, so the reload launched the 8h30m full `--read-data` on the spot (stopped by hand; `check` is read-only so an aborted run is harmless). Expect it, or check the stamp's mtime first. Once the catch-up runs the stamp updates and the schedule behaves normally.

### Remote LUKS Unlock

The host's encrypted root supports SSH-driven remote unlock. `dropbear-initramfs` + `tailscale-initramfs` are baked into every kernel's initramfs; on boot the box comes up on the tailnet as `catallenya-initrd` (tagged `tag:initrd`) and accepts SSH on port 22 with the forced command `cryptroot-unlock`.

The tailnet has tailnet lock (TKA) enabled. Rather than re-registering a fresh ephemeral node each boot (which caused `catallenya-initrd-N` duplicates), the initramfs now carries a **persistent node identity**: `tailscaled.state` lives at `/etc/tailscale/initramfs/tailscaled.state` and is baked into every image by the hook `/etc/initramfs-tools/hooks/initrd-tailscale-state` (repo copy in `tailscale/initramfs-hooks/`), so the node resumes the same identity each boot. It is **state-only** — no auth key in `/boot`; a patched premount override (`/etc/initramfs-tools/scripts/init-premount/tailscale`) omits `--authkey` when empty. The node is signed by a SigDirect under the host's durable `self` TKA key. The old monthly auth-key rotation is retired; `tailscale/initrd-identity/generate-initrd-state.sh` regenerates the identity on demand (recovery: mint a one-off `tag:initrd` key in the admin console, then run it with `--authkey=… --rebuild`). **Never delete the `catallenya-initrd` node** in the Tailscale console — it shows offline while the box runs, and deleting it orphans the baked identity.

Fallback unlock paths: LAN dropbear (`ssh -p 22 root@<lan-ip>` — most reliable at home, no relay) and physical console (LUKS slot 0 = daily passphrase, slot 7 = paper recovery in password manager). In initramfs the node connects via DERP relay only, so when away connect once and allow ~30–90s. Full runbook + addendum in `docs/remote-luks-unlock.md` (host-local, gitignored).

### Monitoring

- **Disk monitoring**: `host/disk.timer` runs hourly (`host/disk.sh`), alerts via Ntfy at 75% usage. Root is measured with `df`; the zpool is measured with pool `capacity` (`zpool list`), which counts snapshot-held space — `df` under-reports it. It is `Class=monitor`, so it now has an `OnFailure=` it never had: `disk.sh` runs `set -euo pipefail` and reads the pool with `read … < <(zpool list …)`, which returns non-zero if the pool is unavailable — **the alarm used to die silently at exactly the moment the pool was in trouble**. The watchdog also checks it ran at all (`MaxAge=3h`), because a threshold-only alert makes healthy and dead identical. **A dropped alert now fails the unit** (2026-08-19): it publishes through the shared transport, and because that transport is best-effort by contract, the script treats any output from it as an undelivered alert and exits non-zero. Before this an ntfy 5xx returned 0 through a bare `curl` with no `-f`, so the pool could cross 75% while the alert was swallowed, `ExecStartPost=` stamped the run, and every layer built to notice reported healthy
- **SMART: `smartmontools` is NOT installed, and `smartd` must be disabled at the moment it ever is** (corrected 2026-08-19). This entry claimed since 2026-08-11 that the package was installed for `smartctl` on demand; it is not — `dpkg -l smartmontools` finds no package and there is no `/usr/sbin/smartctl`, so the hand-run below is a two-step, and the first step is the dangerous one: **`apt install smartmontools` enables `smartd` for you**, and that is the moment to `disable --now` it. smartd's default alert is `mail root` and **this box has no MTA**, so running it would produce a daemon that detects a dying disk and mails it into a void — monitoring that looks present and reports nothing, the same failure mode as a changedetection watch that cannot self-report. What SMART is here for is the one thing ZFS cannot see: the two drives are **identical** (`MTFDDAK3T8QDE-2A` ×2) in a mirror, so they take identical writes and wear out on the same schedule. SSD wear-out is deterministic, not random, which means the mirror's redundancy does not protect against it — and `Percentage_Used` is the only place that trend is visible. ZED covers a disk that HAS failed; scrub covers corruption in blocks it happens to read; neither knows the flash is at 90% of rated writes. **Automating it is deferred, not forgotten.** The natural home is `host/disk.sh` — it already runs hourly, already publishes to the `disk` topic, and is already silent unless a threshold is crossed; note that it publishes through `ntfy/ntfy.lib.sh` and does **not** go through `system-ntfy.sh`, so that courier's topic allowlist is irrelevant here. The blocker is privilege: `disk.service` is `User=carrein` with `NoNewPrivileges=true`, and `smartctl` needs root for the raw-device ioctl. Granting that capability to the hourly script is the wrong trade — raw device access reads any block on the pool, bypassing file permissions, for a unit that currently only runs `df` and `zpool list`. The right shape is a separate root-run oneshot on a daily timer publishing to the same `disk` topic. Left manual until then because the risk is slow: wear moves over months, so `sudo apt install -y smartmontools && sudo systemctl disable --now smartd` followed by a hand-run `sudo smartctl -a /dev/sda` covers it, and sudden failure is already ZED's job. **Do the TRIM work (issue #7) first** — both pool members still read `(untrimmed)` with `autotrim=off`, and untrimmed flash raises write amplification, so building the gauge before fixing that measures a problem while making it worse
- **Service monitoring**: `ntfy/system-ntfy.sh` is the courier every `OnFailure=` points at. **Its body is the job's own journal output** (2026-08-20), scoped to `_SYSTEMD_INVOCATION_ID` and `_TRANSPORT=stdout` — not `systemctl status`, which spent ~18 lines on boilerplate before reaching anything useful. The scoping is load-bearing twice over: without the invocation filter a failure arrives under previous runs' output (`restic.staleness` prints one line a day), and without the transport filter systemd's own Starting/Finished lines fill the whole budget for a job that prints nothing when healthy. **A job that fails sends TWO messages — its own and the courier's — and that is deliberate** (settled 2026-08-21 after being changed and reverted). The six self-notifying jobs split into REPORTERS (`disk`, `changedetection`, `heartbeat`: the bad news is about the world, they exit 0, the courier is a fallback) and WORKERS (`catallenya`, `immich`, `afterimage`, `pigeonhole`: the job itself failed, they MUST exit non-zero or `ExecStartPost=` stamps a failed run healthy, so the courier always fires too). The duplicate is kept because the courier's copy is the only evidence the `OnFailure=` path still works for that unit, and because a script that dies BEFORE reaching its own notify is then covered in seconds rather than by the watchdog up to 36h later. `install.sh` refuses an empty `OnFailure=` on any unit not declaring `SelfAlerting=acknowledged` — **nothing declares it**, and the gate keeps it that way, as it does for `RuntimeMaxSec=`. See `ntfy/MESSAGES.md` § 8. Its topic allowlist is **derived, not maintained** — a unit is ours if its `FragmentPath` resolves under the repo OR its merged view declares an `[X-Catallenya]` Class (which is how the adopted units — catallenya and the sanoid pair, whose fragments live in /etc and /usr — reach the phone), so a new job needs no edit here and a typo'd or foreign unit is still refused. A hand-maintained `case` list had already eaten alerts once (four units died with "Unknown service type", silently, because systemd reports a failed `OnFailure=` handler nowhere). **An unknown topic is routed to the host-health topic rather than refused**, with the intended topic in the title: refusing guarantees the alert is lost, routing guarantees it is delivered. `catallenya` and `catallenya.heartbeat` both take that path by design. **Its success branch is NOT dead code and must not be deleted** (established 2026-08-20): `restic.backup`, `restic.forget` and `restic.check@` all wire `OnSuccess=` here, and those pings are the only positive evidence the `OnFailure=` path still reaches the phone — nothing watches the courier, which inherits no `OnFailure=` (it would call the courier to complain about the courier) and carries no `[X-Catallenya]` Class, so the watchdog skips it too. Only the **daily** backup ping is frequent enough to serve as that canary; weekly, monthly and yearly are not. `install.sh` already refuses `OnSuccess=` on `Class=monitor` — silence is the healthy state — so the restic jobs are the sanctioned exception, not a leak
- **Changedetection watch health**: `changedetection.health.timer` (daily 08:00 SGT, `changedetection/changedetection.health.sh`) is the **only** thing that notices a broken watch — changedetection itself never will. Verified empirically 2026-08-09 with unmuted throwaway watches rechecked past the 6-failure threshold: a DNS failure, an HTTP 404, a re-gated endpoint and a filter that stops matching all leave `notification_alert_count` at **0**. Every error branch in `worker.py` writes `last_error` and returns; only `FilterNotFoundInResponse` notifies, and that is raised solely by `if not filtered_content.strip()` — which a `jq:` filter building an array can never satisfy, because it returns the two-character string `[]`. One job covers every watch: it enumerates them from the API, so a new watch needs no config. Reports `BROKEN` (errored, or never checked since creation), `STALLED` (no check in `max(3× interval, 6h)`), `QUIET` (no change in 30d — may be benign, may be a filter returning frozen data), `MUTED`, and container-not-running. Silent when healthy, like `restic.staleness`. It publishes to the **same** `changedetection` topic the watches use — a separate topic is one more thing to subscribe to, and an unsubscribed monitoring topic swallows alerts with a 200 OK. `docker exec -i` is load-bearing: without `-i` stdin is not forwarded, python reads an empty program and exits 0, and the check reports "all clear" forever while looking at nothing (shipped bug, caught by live-fire test). **The empty-watch-list guard was a second instance of the same class and had never once worked** (found and fixed 2026-08-19): the remembered count was opened at a HOST path from inside the container, where only `/datastore` is mounted, so both the read and the write failed into a bare `except: pass` and `previous` was always `None` — the branch meant to catch the watch list dropping to zero could not fire, and the file it wrote had never existed on disk. The count now lives on the host at `systemd/state/.changedetection-watch-count`; it rides IN as `docker exec -e PREVIOUS_COUNT` (an environment variable, never interpolated into the program text) and the count rides OUT on a `WATCH_COUNT=<n>` marker line the host parses. It is emitted only after the API answers, so an outage cannot overwrite the remembered count with zero. The first run after deploy is silent by design — no memory means no comparison — and the guard arms from the second
- **ZFS pool monitoring**: ZFS Event Daemon (`zed`) publishes pool events (scrub, errors, resilver) to the `zpool` ntfy topic. Topic and URL are on the host at `/etc/zfs/zed.d/zed.rc` (`ZED_NTFY_TOPIC`, `ZED_NTFY_URL`); the SENDER is `zed_notify_ntfy()` in `/etc/zfs/zed.d/zed-functions.sh`, which is **vendored at `host/zed-functions.sh` and installed by `sudo bash host/zed.install.sh`** (2026-08-22). Sanoid handles snapshots only and is not wired to ntfy. **Its ntfy sender had four defects, all of them ones fixed elsewhere on 2026-08-19** — no `-f`, so an HTTP error returned 0 and the alert vanished *while zed recorded success*, on the one channel that reports a dying disk; no `--max-time`, so a wedged ntfy hung the daemon watching the disks; `-d` rather than `--data-raw`, the `@filename` trap; and no CR/LF strip on the `Title:` header. A hardcoded `Priority: high` is gone. Titles come from `zed_ntfy_title()`, built from `ZEVENT_*` rather than by parsing the subject — there are **five** subject shapes across the zedlets, so a regex over the prose would match wording upstream is free to change — and the mapping is exhaustive for the four enabled zedlets, with anything unmapped passing through unchanged. Bodies are verbatim on purpose: a `zpool status` dump is what you want when a disk is failing, the same reasoning as `system-ntfy.sh`'s journal excerpt. **Editing this does NOT fight apt, and the belief that it does was wrong**: `/etc/zfs/zed.d/zed-functions.sh` is a dpkg **conffile**, so dpkg prompts rather than overwriting, `unattended-upgrades` runs `--force-confold`, and zfs-zed was upgraded on this box on 2025-09-20 (9.3 → 9.4) with the pre-existing local modifications intact. That is the **opposite** of the sanoid trap, whose units were under `/usr` and therefore not conffiles — which is exactly why apt replaced those silently. The cost dpkg's caution buys instead is **staleness**: a new upstream file is written beside ours as `.dpkg-dist` and never applied, so after a zfs-zed upgrade run `diff /etc/zfs/zed.d/zed-functions.sh{,.dpkg-dist}`. The whole file is vendored rather than a patch because restoring is `cp`, which is the operation that has to work while rebuilding a box; the cost is one gitleaks suppression for upstream's unused pushbullet notifier.
- **Immich rotation bake**: `immich.fix-rotations.timer` runs daily at 04:00 SGT (`OnCalendar` pins `Asia/Singapore`, DST-safe) via `immich/scripts/immich.fix-rotations.daily.sh`, baking pending UI rotate edits into originals losslessly. Notifies the `immich` ntfy topic only when something was baked, failed, or skipped for a reason needing a human; silent when there is nothing to do (crop/mirror edits are intentionally left alone)
- **Documents intake**: **nothing files itself.** Pipeline home is `pigeonhole/` (code + `intake-state/`; the corpus stays in Syncthing, and the converged shape both pipelines share is `docs/intake-playbook.md`). `pigeonhole.triage.path` fires when a file lands at the root of `syncthing/data/master/documents`, classifies it through the shared AI layer in ONE call — the human tap is the verifier; the adversarial verify and the OCR pass retired 2026-08-01 — moves it to `staging/` **already renamed to the proposed filename**, and notifies the `pigeonhole` topic with Accept/Discard. Clean proposals batch into one message; anything doubtful (new folder, no owner, no printed date, a `_lookalike_families` member) gets its own; a blocked one gets no Accept button. **State is the filesystem** — `root → staging → (numbered folder | bin)` — so `ls` answers what the system is doing, and each button means "put this document in the state I name, from wherever it is". Ignoring a notification leaves the document staged and it reappears in the next batch. **Two buttons, one outcome each — the undo AND `skip` are gone (2026-08-09, owner's call).** `filed → discard` was an undo that fell out of the state rule for free, but it only worked because the notification stayed live after a tap, which cost a permanent notification on every document ever filed. `skip` went because ignoring the notification already meant "leave it in staging", so its one distinct effect was dismissing a notification without deciding — and because each skip rewrote the record and so **restarted the 7-day bin clock**, which made the deadline something a daily tap could postpone forever. A stray `skip` marker is now refused as an unknown action, not silently honoured. Recovery for a misfile is **moving the file** — it is in Syncthing on every device, `bin/` is never auto-emptied, and ZFS/sanoid plus restic sit behind both. Do not re-add `clear=true` to any button: it dismisses on the TAP, before apply has done anything, and would make a refused move look like a completed one. **The vocabulary no longer gates anything** — with a human tap in front of the move, `folder`/`doc_type`/`qualifier` are free text guarded by `valid_segment()` + `under_docs()` in `pigeonhole.lib.sh`, and the model may propose a new folder. Those two functions are what the closed enum used to guarantee; do not weaken them. The move is done by `pigeonhole.apply.service`, a hardened oneshot — the `pigeonhole-approve` container mounts **only** `intake-state/approvals/` and can do nothing but write a marker. Both `.path` units MUST drain (root, markers) or they hot-loop. `pigeonhole.retry.timer` (07:50 SGT) re-classifies documents parked by an API failure, in place — never moved back to the Syncthing root, which would replicate the move to every device twice a day for the length of the outage. It is a separate job because `pigeonhole.sweep.service` deliberately holds no API key. `pigeonhole.sweep.timer` (07:45 SGT) nudges a staged proposal at 24h and moves it to `bin/` at 7d — Accept still files it from there; the **sweep** never empties `bin/`. **One rule: a notification lives exactly as long as its decision is outstanding** (2026-08-09). Solo proposals carry the record id as an ntfy sequence id, the batch carries the stable literal `BATCH_NTFY_ID`, the nudge and the binned note retract what they replace, and `pigeonhole.apply.sh` retracts on a tap — **but only when nothing was refused** (`(( REFUSED == before ))`), because a refused tap moved nothing and its buttons are still the way to act. That conditional is what makes a notification's disappearance mean "done" rather than "tapped", and it is why apply is silent on success. The **binned note** uses `bin_buttons()` — Accept and **Delete**, no Skip — and gets a clock of its own, `BIN_NOTE_DAYS` (7): a week in staging to decide, a week in `bin/` to rescue, then the sweep withdraws the MESSAGE and stamps `note_withdrawn`. The **document is untouched** by that — it stays in `bin/`, and the only thing that ever removes a document is a Delete tap. After this, no notification in either pipeline outlives its decision. Delete is the only destructive arm in the pipeline; "the sweep never empties bin/" really means "nothing is destroyed without a tap", and this is the tap. **The bin/-only restriction is enforced in `pigeonhole.apply.sh`, never in the container** — a marker is just a filename the container wrote, so "the UI only offers Delete on a binned note" is not a guarantee the mover may rely on. Tested both ways: deletes from `bin/`, refuses from `staged` and `filed`. `bash pigeonhole/tests/run.sh` is the offline suite. **`pigeonhole.backstop.timer` (03:00 SGT) is NOT a schedule for the pipeline** — that is event-driven — it is a backstop for what the `.path` globs cannot see, e.g. a file whose extension no glob matches. It fires the same `pigeonhole.triage.service`, so systemd serialises the two and the extra run exits in milliseconds with `nothing at root`. Do not confuse it with the retired nightly below. Retired 2026-07-31: the auto-file 03:00 nightly, `documents.intake.{scan,apply,daily}.sh`, and the 8-point auto-file gate. `pigeonhole/README.md` is the architecture front page and is the front page of the public mirror **pigeonhole** (see § CI/CD); there is deliberately no `pigeonhole/OPERATIONS.md` yet — the operational detail is this bullet and the code
- **Capture triage**: `afterimage.triage.path` fires `afterimage.triage.service` the instant a screenshot lands in `afterimage/data/incoming/`, which calls `claude-opus-5` with vision and posts proposed events to the `afterimage` ntfy topic with Add/Discard buttons. Nothing reaches Radicale without a tap. PNG and JPEG are both accepted (Android screenshots are JPEG); the spool name is always `<id>.png` because that is the glob the root-owned `.path` unit keys on, so the triage sniffs magic bytes rather than trusting it. One screenshot can describe several events — the triage fans them into one record per event, capped at `MAX_EVENTS_PER_CAPTURE`, sharing a hardlinked image, so nothing downstream needs to know. Past events are detected by `event_is_past()` in code, never by the model, and collapsed into one "already passed" note. Transient API failures retry in-process and then via the sweep; a run that triages nothing exits non-zero so `OnFailure=` fires. The triage **must** move every file out of `incoming/` on every branch: `PathExistsGlob` re-fires while a file remains, so a leftover PNG hot-loops systemd and bills an API call per spin. `afterimage.sweep.timer` (nightly 07:30 SGT, no API calls) re-notifies a proposal untouched for 24h, retries a parked one **once a day until 7 days from its FIRST failure** (`PAUSED_GIVE_UP_DAYS`; this replaced a two-attempt rule written for an hourly sweep that silently became "give up after two days" when the sweep moved morning-side), nudges and expires a needs-a-human record on the same clock as a proposal, archives at 7d as `ignored`, prunes screenshots older than `PRUNE_IMAGE_AFTER_DAYS` (7d, all outcomes), and reports stray files in `incoming/` the `*.png` glob cannot see. **Notifications are withdrawn, not left to rot** (2026-08-09): every proposal is published with an ntfy sequence id, the 24h nudge retracts the original before publishing itself, and **the container itself retracts the instant you tap** — `archive()` in `afterimage/src/server.ts` calls ntfy over the docker network (`NTFY_URL: http://ntfy`, plain HTTP container-to-container exactly like radicale; unset it to disable). A marker-guarded pass over `archive/` is the **backstop**, not the primary: it catches the ignored/failed records the sweep archives and any tap whose retract failed. Before this, an ignored capture left a notification whose Add button answered 404 forever. `RETRACT_WITHIN_DAYS` (14) bounds the pass; the markers for the 101 records archived pre-feature were seeded by hand at deploy so the first run sent nothing. **`undoAdd()` is now unreachable from a notification** — Add withdraws the message, so there is no Discard left to tap; the code stays as a manual safety valve, and the real undo for a wrong Add is deleting the event in the calendar app. No ledger and no recording mode (retired 2026-08-01): state is locations only — `incoming → pending → archive` — and each archived record carries its own `decision.json`. `ANTHROPIC_API_KEY` lives in `/etc/ai.env` (root-owned 0600, injected into the `User=carrein` process) — deliberately **not** in `.env`, and shared with `pigeonhole.triage.service`. The Radicale credential is a docker secret (`afterimage/dav-secret`), not an env var. `bash afterimage/tests/run.sh` is the offline regression suite; every case in it is a bug that shipped. The transport half of it now lives in `bash ai/tests/run.sh` — run both. Docs are split: `afterimage/README.md` is architecture (and is the front page of the public mirror **afterimage**, see § CI/CD), `afterimage/OPERATIONS.md` is the laptop hotkey client and the server rebuild. Design, bake-off results, and post-deploy fixes in `.claude/plans/capture-pipeline-plan.md`
- **Liquidroom (music stems)**: drop an empty `Artist - Track.txt` at the root of `master/liquidroom` from any synced device → `liquidroom.triage.path` fires the triage, which batches everything queued (`MAX_PER_RUN=3`), runs ONE download container (Sockseek, dedicated Soulseek account in `/etc/liquidroom.env`, FLAC preferred) then ONE network-none processing container (audio-separator BS-Roformer-SW → 6 stems; MSST + listra92 community model splits the guitar stem into lead/rhythm, NON-FATAL; ffmpeg builds `(-1 Guitar)`, `(-1 Lead Guitar)`, `(-1 Rhythm Guitar)` mixes), and publishes `<Artist>/<Track>/` with **one atomic rename** so Syncthing never sees halves. The marker is DELETED once its outcome is decided (the disappearance is the receipt); anything not understood as a request is PARKED in `rejected/`, never deleted. **One notification per VERB present in the run** on the `liquidroom` topic (changed 2026-08-20 from one summary per run): a run where two tracks published and one download failed cannot honestly be titled `Finished`, and the old solo title was `${LINES[0]%%:*}` — the raw outcome phrase, so "Liquidroom: stems ready" rather than the track. Bounded by `MAX_PER_RUN=3`, so at most three distinct failure verbs; typical run 2 notifications, worst realistic 6. They are receipts — no sequence id, no actions, nothing to retract — which is the only reason multiplying them is safe. **The model loads once per batch** — that amortisation is why the stages batch instead of running per track. **Separation costs ~31 min for a 3:20 track (~9.4x realtime), measured on this box 2026-08-14 — the published "5–15 min" figures are GPU numbers.** Diagnosed, not assumed: FP32 GEMM measures 520 GFLOPS (~60% of peak), AVX-512 + MKL active on all 6 physical cores, no CPU quota; the cost is the model (12 transformer layers, attention over 1,335 frames per chunk across ~60 bands, 6 stems) and attention on CPU is memory-bound. `--mdxc_overlap` is already at its floor of 2, so the only lever is a lighter model (`htdemucs_6s`, far faster, much worse on guitar — it does not place in the MVSep guitar top 20 where SW leads at 9.01). Slow-and-good is deliberate. `MAX_PER_RUN=3` and the 90-min-per-track stage budget both derive from that measurement. The job container runs in dockerd's cgroup, not the unit's: stage `timeout`s + the fixed `liquidroom-job` name + entry/EXIT `docker rm -f` are what bound it, not `TimeoutStartSec`. Both compose services — `liquidroom-soulseek` (download; carries the `build:` key) and `liquidroom-roformer` (network-none processing), named for what each runs — are `profiles: ["liquidroom"]` (invisible to boot's `up -d`; auto-activated by `compose run`) and the downloader rides its OWN bridge network — never the shared flat bridge — with 50300 published only via `--service-ports` during downloads. **`process.py` and `entrypoint.sh` are COPYied into the image, so editing them changes nothing until `docker compose --profile liquidroom build liquidroom-soulseek` runs** — tests pass, the diff looks applied, and the pipeline keeps running the old code with no warning (caught exactly once, 2026-08-15, after the filename fix). **Published names are made PORTABLE, not faithful — this reverses the 2026-08-15 "the requested title is authoritative" call, do not restore it.** `portable_segment()` in `liquidroom.lib.sh` applies beets' default `replace` table inside `parse_request()`: `[<>:"?*|]` → `_` and a trailing dot → `_`, on every platform. Windows rejects those characters outright and **Syncthing does not translate** — a receiving Windows peer parks the item as a failed item and retries it forever, so one such title strands that device with *nothing visible on this side*: the error lives on the Windows box while the host reports healthy. `The Strokes - What Ever Happened?` did exactly that — `legion` sat at 99.33% on `master` needing precisely that folder and its 12 files, 2026-08-20 to 08-21, and it surfaced only because the owner noticed the track missing. beets, Picard and yt-dlp all converged on substituting at WRITE time for the same reason: a name is portable or it is not, and the receiving end never gets a say. The other four beets rules (`[\\/]`, `^\.`, `^-`, control bytes) are already REFUSALS in `valid_segment_lr()`, which is stronger; reserved DEVICE names (`CON`, `NUL`, `COM1`…) are a known gap, uncovered by beets either. Sanitising in `parse_request()` is what makes the folder and its twelve filenames agree — both derive from those globals — and `process.py`'s rename-back of the separator's own spelling is KEPT as a general repair (a no-op when the two agree), because what audio-separator mangles is not something this repo controls. All four model files are sha256-pinned as `MODEL_PINS` in `liquidroom/scripts/liquidroom.lib.sh` (~1 GB in `state/models/`) — `models.sh` fetches and verifies, and the triage **re-verifies before every separation run**, because "fetched once, therefore correct forever" is an assumption about a directory several things can write to; the two BS-Roformer-SW files are required, the listra92 pair is optional (a missing split already degrades to `ok_no_split`) but must match if present. `bash liquidroom/tests/run.sh` is the offline suite (fake-`docker` PATH stub, `NTFY_DISABLE=1`). Teardown: `sudo bash liquidroom/uninstall.sh` + revert the commit. Docs are split: `liquidroom/README.md` is architecture (and is the front page of the public mirror, see § CI/CD), `liquidroom/OPERATIONS.md` is running it — every trap, credential and recovery step. **A new file in `liquidroom/` needs an explicit `.gitignore` allowlist line** or it is untracked, invisible to `git status`, and silently absent from the mirror.
- **Withdrawing an ntfy notification** (shared by both intake pipelines, 2026-08-09): ntfy has **no per-message TTL and no scheduled delete** — a notification only disappears if something sends `DELETE /<topic>/<sequence-id>`, which the server broadcasts to subscribers as a `message_delete` event. So anything retractable must be published with a sequence id. **The header is `X-Sequence-ID` (aliases `Sequence-ID`, `Sid`). `X-ID` is accepted with a 200 and SILENTLY IGNORED** — the message comes back with no `sequence_id` and every later retract addresses nothing; caught pre-deploy only by diffing our header against the CLI's own `--sequence-id` against 2.27.0, so verify empirically rather than from the docs. `ntfy/ntfy.lib.sh` carries `notify … [id]` + `retract <id>` + `ntfy_id_safe` (the id rides in a header **and** a URL path, and a bare `..` would address the topic root) — one copy since 2026-08-10, see the transport bullet below. Deletes are **idempotent and unvalidated** — an unknown id returns 200 — which is what makes "retract, then publish the replacement" safe to call unconditionally. **`paused_sync()` REVERSED on 2026-08-20 and the reversal is deliberate — do not restore the old shape.** From 2026-08-19 it retracted unconditionally, so the run that RESOLVED an outage cleared the summary; before that, both triages kept the retract inside their non-empty branch and left "Paused: N …" on the phone claiming a pipeline that was already working. The **withdrawal rule** now says the opposite: a notification WITHOUT BUTTONS is never withdrawn by the system, because an absent one is ambiguous — fixed, mis-swiped, or never sent — while a stale one is not. So the summary still replaces itself WHILE an outage runs (retract, then publish, so the count updates rather than stacks) and simply stops updating once nothing is paused. The retract sits after the empty check; that one line is the whole difference, and an audit that "fixes" it back is undoing a decision. See `ntfy/MESSAGES.md` § 4. The sweeps call it too, because a triage only runs when something arrives, and the run that gives up on the last parked record may be the last run for a long time. `NTFY_CACHE_DURATION=72h` (up from the 12h default) exists for this: the delete event is cached like any message, so a phone offline longer than the window keeps the stale notification. **`NTFY_CACHE_FILE=/var/cache/ntfy/cache.db` is the other half** (added 2026-08-10): without it the cache is in-memory only and the duration survived nothing — watchtower polls hourly and recreates ntfy on any image update, dropping every cached message including the `message_delete` events, so a phone reconnecting after a restart never saw the deletion and kept a notification for a record already archived or binned. The `ntfy-cache` volume mounted at `/var/cache/ntfy` persists it; verified the db survives a restart. Duration and file are two halves of one setting — setting either alone does nothing useful. Requires the Android app ≥ 1.22.2 / server ≥ 2.16.0. **`NTFY_DISABLE=1` mutes the wire call in the shared transport and every suite exports it** — the documents suite runs the REAL triage and apply (not dry-runs), so `DOCS`/`STATE_DIR` sent its files to a scratch tree while every notification it raised went to the live `documents` topic; a full run put dozens of pings on the phone and nothing flagged it. The guard sits immediately before the `curl`, so header construction and sanitisation are still exercised. Capture's suite is dry-run only and never had the symptom; it exports the same var so it cannot acquire one.
- **One ntfy transport, and nothing shouts** (2026-08-10; **the last four hand-rolled curls joined it 2026-08-19**): `notify`, `retract`, `ntfy_id_safe`, the `NTFY_DISABLE` mute seam, `hdr_safe` and `md_escape` all live in **`ntfy/ntfy.lib.sh`**, sourced by afterimage, pigeonhole, liquidroom, immich, and — since the audit — `host/disk.sh`, `host/catallenya.sh`, `changedetection/changedetection.health.sh` and `systemd/heartbeat.sh`. Those four had been left behind by the 2026-08-10 sweep and carried exactly the drift it existed to end: **none** passed `--max-time`, two had no `-f` (so an ntfy 5xx returned 0 and the alert vanished **with the unit recording success and the watchdog stamped fresh**), and all four `source`d the whole root `.env` to read three keys. **`ntfy/system-ntfy.sh` is the one deliberate holdout** — the courier every `OnFailure=` points at is the alarm of last resort and depends on nothing; it keeps its own curl, now with `--max-time` and `--data-raw`, and its unit declares `TimeoutStartSec=2min` directly because plumbing inherits no policy and a wedged ntfy could otherwise hang every failure alert in the fleet forever. **`notify()` is best-effort by contract** (every path ends `|| true`), so a job that must fail when its alert is lost — `disk.sh`, `heartbeat.sh` — tests the transport's **silence** instead: `curl -fsS` prints nothing on success and the error otherwise. They were four private copies and had already drifted — two lacked `--max-time` (a hung ntfy stalls the job until systemd kills it, reporting failure for work that succeeded) and immich's had no `hdr_safe` at all. `bash ntfy/tests/run.sh` is its suite, and it is the first place the sanitisers have ever had a behavioural test: the pipeline suites only grepped the source to check `hdr_safe` was still being *called*, never that it stops a CRLF header injection. **There is no priority argument and no tag argument any more** (2026-08-20) — `notify` is `<title> <body> [actions] [seq-id]`, and every job reaches it through a kind wrapper rather than calling it directly. `high` is now unrepresentable rather than refused, which matters because the "nothing shouts" rule had already been **false for nine days**: pigeonhole's refusal wrapped its call across two lines, so the sweep missed it by eye and `contract.sh` missed it by regex. Tags went the same way — twelve glyphs of which four meant "something is wrong", the rest naming a pipeline the topic already names. `ntfy/system-ntfy.sh` builds its one header by hand and is checked by pattern. See § The Message Contract. The one message that could not survive being quiet was afterimage's needs-a-human, which fired exactly once with nothing waiting anywhere; it now parks and is nudged like everything else, which removed the exception instead of amplifying it. **`paused_title()`/`paused_body()`** build the desk-failure message so it reads identically on every topic — the one deliberate exception to the playbook's "shared discipline, not shared vocabulary".
- **Capture accepted risks** (reviewed 2026-07-27, do not re-raise without new information):
  - *The capture container holds a full-scope Radicale credential.* `afterimage-dav-secret` is `base64(carrein:<app pw>)` — the same value Caddy injects for mitsume — and Radicale's `[rights]` is empty, so it defaults to `owner_only`: that credential can read, write and **delete** everything under `/carrein/`, not just the two collections capture writes. Scoping it means a separate user plus a `from_file` rights config, and that config then governs **your own** access too; getting it wrong locks you out of your own calendar and breaks mitsume and phone sync. Weighed against a code-execution bug in a few hundred lines of Bun (`afterimage/src/server.ts`) that runs read-only, non-root, `cap_drop: ALL`, `no-new-privileges`, tailnet-only and header-gated. Accepted. A second password for the same user is not a workaround — htpasswd does not do that reliably.
  - *Multi-event screenshots fan out into one record per event* (built 2026-07-27). The model returns `events[]`, capped at `MAX_EVENTS_PER_CAPTURE`, and the triage creates a separate record — own id, own notification, own buttons — for each, hardlinking the one screenshot into all of them. The container, sweep and archive were deliberately left untouched: each record is exactly the single-event shape they already handle, so no indexed callback was needed. Position rides in the notification TITLE as `(2/4)`. `events_seen` is what catches the OTHER loss path: the prompt tells the model to self-truncate at `MAX_EVENTS_PER_CAPTURE` and report the page's true total there, so a reply of 8 with `events_seen: 12` means the MODEL dropped four and our cap never fires — the body's `N more events not sent` counts both. A single event that RUNS ACROSS DAYS is one event with `end_date`, not a choice between its days; `alternatives` stays for occasions you attend exactly one of.
  - *ntfy carries no authentication.* Pre-existing, accepted before this pipeline existed. The callback ids are unguessable UUIDs and the `X-Afterimage` header blocks the browser vector; anyone who can read the topic can still act on a proposal.
- **ZFS scrub**: `zpool.scrub.timer` (1st of the month) is the **sole owner**, resolved 2026-08-10. `/etc/cron.d/zfsutils-linux` also scrubs on the second Sunday and — unlike the sanoid and e2scrub entries beside it — its lines carry no `[ ! -d /run/systemd/system ]` guard, so both fired: 2026-08-01 (timer) and 2026-08-09 (cron), 2.5h a pass. It is silenced with `zfs set org.debian:periodic-scrub=disable zpool`, **not** by editing the cron file: `/usr/lib/zfs-linux/scrub` reads that property (`zfs get`, on the dataset — pools cannot hold user properties) and skips on `disable`, and a property survives package upgrades where a conffile edit would be restored. The timer was kept over the distro cron deliberately — it is version-controlled, reproducible via `systemd/install.sh`, and visible in `list-timers`, whereas the cron entry is owned by apt. **Both halves now live outside `/etc`**: the schedule in this repo, the kill-switch on the pool. Note `systemctl disable zpool.scrub.timer` DELETES the symlink into this repo, so re-enabling means re-running `install.sh` or recreating it by hand. `zpool scrub` returns in about a second, so the unit exiting 0 says nothing about the scrub's outcome — ZED covers that on the `zpool` topic, and the watchdog checks the scan completion date in `zpool status` (`Freshness=zfs-scrub:zpool`) rather than a completion stamp, which would only record that a scrub was *requested*. The service now has an inherited `OnFailure=`, and `CapabilityBoundingSet=CAP_SYS_ADMIN` — root is genuinely required (`zpool scrub -p` as carrein returns permission denied; `/dev/zfs` is 0666 but the kernel enforces the capability and there is no `zpool allow`), but unbounded root is not
- **NFS/rpcbind removed 2026-08-10.** `nfs-server`, `nfs-mountd`, `rpcbind` and `rpcbind.socket` were enabled and listening on 111/2049 across LAN and tailnet with a completely empty `/etc/exports` — six network-facing RPC daemons serving nothing. Disabled, not firewalled: deleting the service beats filtering it, and it is most of what ufw would have been protecting
- **Desktop daemons removed 2026-08-11 — CUPS, cups-browsed, Avahi, Bluetooth.** Ubuntu desktop preinstalls these; none has a consumer here. **All seven units had to go together**, the same trap as `rpcbind.socket`: `cups.socket`, `cups.path` and `avahi-daemon.socket` were enabled and would have socket-activated the services straight back from a `disable` of the `.service` alone. **Avahi is additionally `mask`ed** (symlink to `/dev/null`) so an apt upgrade cannot re-enable it via preset — the Sanoid lesson applied preemptively. Avahi was the one that mattered: it listened on `0.0.0.0:5353` and `[::]:5353`, announcing this host's name and services to the whole LAN, which quietly undid the boundary every other service respects by binding to `127.0.0.1`. **Verified nothing depended on any of it** before disabling — console keyboard and mouse are USB (`usb-YICHIP_Wireless_Device`), so Bluetooth cannot affect the physical-console unlock path; zero Bluetooth pairings and the radio was already `rfkill` soft-blocked; no printers configured and CUPS was loopback-only; and no `.local` name appears in `~/.ssh/config` or anywhere in this repo. **Syncthing is unaffected** and this is worth knowing before anyone "restores" avahi for it: its local discovery is its own UDP 21027 protocol, never mDNS, and the container sits on the `catallenya_default` bridge with no published ports, so it has no LAN discovery path either way. **`nss-mdns` does NOT break DNS** — `/etc/nsswitch.conf` reads `hosts: files mdns4_minimal [NOTFOUND=return] dns`, which looks like stopping avahi would strand every lookup, but with the socket gone `nss-mdns` returns `UNAVAIL` and `[NOTFOUND=return]` only traps `NOTFOUND`, so resolution falls through to `dns` normally. Only `.local` names stop working. **Result: the only non-loopback, non-Tailscale listener left on this host is SSH on 22** — everything else is `tailscaled` (host `:41641`, sidecar ephemerals) or bound to a tailnet IP. Reversal is `systemctl unmask` + `enable --now`; nothing was uninstalled
- **Sanoid runs from systemd DROP-INS, not patched vendor units** (2026-08-10). `/etc/systemd/system/sanoid{,-prune}.service.d/override.conf` set `ConditionFileNotEmpty=` and `ExecStart=` (empty first, to reset the list — systemd APPENDS otherwise and you get two ExecStart entries and two runs per trigger). Previously the vendor units under `/usr` were edited in place; files there are not dpkg conffiles, so an `apt upgrade` replaces them **without prompting**, after which the vendor `ConditionFileNotEmpty=/etc/sanoid/sanoid.conf` points at a file that does not exist here — and a failed `Condition` is a **skip, not a failure**: no exit code, no `OnFailure=`, no journal error, snapshots simply stop while everything looks healthy. Verified by reinstalling the package: vendor units came back pristine and the override still won. `systemd/install.sh` now writes these drop-ins on every run (override + `[X-Catallenya]` sticker for both units), so a fresh install reproduces them
- **Watchtower**: Auto-updates containers with `com.centurylinklabs.watchtower.enable=true` label, polls hourly. `WATCHTOWER_REMOVE_VOLUMES` was removed 2026-08-10 — it deletes a container's *anonymous* volumes on update, and was safe only because every labelled service happens to have its image's `VOLUME` paths bind-covered; label one that is not and the next auto-update discards its state. `WATCHTOWER_CLEANUP=true` already reclaims old images, which is what it was reached for

### CI/CD

GitHub Actions (`.github/workflows/ci.yml`) runs on push to main, PRs, and manual dispatch:
- **GitLeaks** (v3): scans for leaked secrets. **Scan SCOPE depends on the event: a
  `push` scans only that push's diff, while `workflow_dispatch` scans the FULL
  history** — so a manual run is the only thing here that re-reads the whole repo.
  That matters because `.gitleaksignore` suppresses by fingerprint, and a fingerprint
  is `<commit>:<path-AS-IT-WAS-in-that-commit>:<rule>:<line>`. The 2026-08-15 rename's
  repo-wide find-and-replace rewrote one of those paths to match the current tree,
  which no later rename can do — the suppression stopped matching, and it sailed
  through four green pushes before the next dispatch failed on a finding that had been
  suppressed for three weeks. Never let a bulk edit touch that file. Known-fake
  findings suppressed there: the deliberate 2025-11-05 test key; a 2026-07-27 false
  positive on a prose comment. CI pins the SCANNER explicitly via
  `GITLEAKS_VERSION: "8.24.3"` (2026-08-10) — the action SHA only fixes the wrapper,
  and the binary it downloads is whatever that release bundles, so a weekly dependabot
  SHA bump would have moved it with nothing in the diff to say so. 8.30.1 does not
  flag the same things, so verify with the pinned version, not `:latest`:
  `docker run --rm -v "$PWD:/repo" -w /repo zricethezav/gitleaks:v8.24.3 detect --redact`
- **compose-validate**: `docker compose --env-file .env.ci config --quiet` plus a drift
  guard that fails if a `${VAR}` in docker-compose.yml has no line in `.env.ci`. When
  adding a new compose variable, add a dummy (shape-valid) line to `.env.ci`
- **shellcheck**: all tracked `*.sh` at `-S warning`, **pinned to
  `koalaman/shellcheck:v0.11.0`** (2026-08-22). The check is **defined once**, in
  **`ci/shellcheck.sh`**, and both callers run that file — the CI job and the
  `ci/pre-push` hook — so version, severity and file list have nowhere to drift
  apart. Run it by hand with `bash ci/shellcheck.sh`; that IS the CI check, not an
  approximation of it. **Do not inline the command back into either caller.** It
  fails loudly when docker is missing rather than passing quietly, because a check
  that reports success without running is the same fault as a dropped alert with the
  run stamped healthy. Until 2026-08-22 CI used the runner's **preinstalled** binary
  — a version nothing here
  chose and GitHub can move with no commit in the diff. **The drift ran OLDER, and
  the entry here said the opposite for four days**: measured 2026-08-22, the
  ubuntu-24.04 runner ships **0.9.0** while `:stable` and `:latest` are both
  **0.11.0**, so the local image was two releases AHEAD, not behind. 0.11.0 fixed an
  SC2218 false positive that 0.9.0 still raises — a call flagged as preceding its
  definition even when an earlier definition of that name already covers it — which
  is the whole reason a local run came back clean while CI raised thirteen. SC2218
  is alive in 0.11.0; only the false positive is gone. **The four SC2068 failures
  were never version skew at all**: every version from 0.8.0 up flags an unquoted
  `$@`, and this box has no shellcheck binary — nothing ran it locally, which is a
  different problem from running the wrong one. Both live on in what SC2218 surfaced
  by accident: `systemd/tests/run.sh` had **two** functions named `fixture` 184 lines
  apart, one building a unit and one writing a script. Runtime was correct, so 0.11.0
  is right to be quiet — but a unit-style call added below the second definition
  would silently write a one-line script and pass having tested nothing, in the suite
  whose whole job is catching that. The rename to `contract_fixture` stands on its own.
  Changing the pin is a deliberate edit: bump it, run the command above, fix what the
  new version raises. **A local run that disagrees with CI means the versions differ
  — check that before believing either.**
- **mirror**: publishes a feature directory to its own standalone repo via
  `git subtree split`, so a feature can be linked, described and pinned on its own —
  GitHub pins are repo-level, you cannot pin a directory. **Five matrix entries, and
  the prefix is the DIRECTORY while the repo is its published name:**

  | prefix (directory) | mirror repo | |
  |---|---|---|
  | `liquidroom` | `MiraiConcepts/liquidroom` | same |
  | `afterimage` | `MiraiConcepts/afterimage` | same |
  | `pigeonhole` | `MiraiConcepts/pigeonhole` | same |
  | **`systemd`** | **`MiraiConcepts/controlplane`** | **mismatch** |
  | **`ai`** | **`MiraiConcepts/inference`** | **mismatch** |
  | **`ntfy`** | **`MiraiConcepts/dispatch`** | **mismatch** |

  Three of six match, so **do not assume a mirror's name is its directory** — read
  the matrix. `systemd/` is deliberately not renamed: unlike `capture`/`documents`,
  which were generic words standing in for one specific thing, `systemd/` accurately
  names what it holds, and renaming it would also collapse that mirror's 67 commits
  of history to one (subtree split matches on path and does not follow renames — it
  is what took afterimage to 2 commits and pigeonhole to 1). The repo name places the
  work for a reader; the directory stays accurate for whoever types the path. `ai/`
  keeps its directory for the same reason (three consumers source it by that path,
  and it is exactly what the directory holds) while `ai` alone was too generic to
  publish — `inference` (2026-08-16) is its shop-window name.
  Adding the next is one line,
  but a feature needs a newcomer-facing README first or its mirror's front page is a
  file listing, and **any new tracked file under a mirrored prefix needs its own
  `.gitignore` allowlist line** or it is untracked, invisible to `git status`, and
  silently absent from the mirror. **The sync is one-way and the push is `--force`: anything committed
  directly in a mirror is destroyed on the next run, silently.** Mirrors are an
  output, never an input — redirect PRs to this repo. Three things this encodes:
  `fetch-depth: 0` is mandatory (subtree split on a shallow clone yields ONE commit
  and does not error); the per-prefix change gate lives in the job because
  `on.push.paths` is workflow-level and cannot discriminate between matrix entries;
  and auth is a **deploy key**, not a PAT, because fine-grained PATs only reach an
  org that has explicitly enabled them and deploy keys never expire. The mirror's
  `main` is deliberately **unprotected** — a branch ruleset there would block CI's
  own force-push. Do not add `mirror (<prefix>)` to required status checks: matrix
  check names change whenever the matrix does
- **notify-failure**: curls the `NTFY_FAILURE_URL` Actions secret (ntfy.sh topic —
  tailnet ntfy is unreachable from runners) when any job fails; skips gracefully if unset.
  `mirror` is in its `needs:` deliberately — a mirror that silently stops syncing looks
  identical to one that is current

**Git hooks — two, both tracked, installed by `bash audit/install-hooks.sh`.**
`.git/hooks/` is never tracked, so each hook exists twice: a tracked master that
survives a rebuild and an installed copy that actually runs. `audit.sh` §17 reports
either one missing, non-executable or drifted from its master, and **fails the
audit** — a hook believed present and absent is worse than none. The installer is
idempotent and resolves `core.hooksPath` rather than assuming `.git/hooks`, because
installing into the wrong directory leaves a hook that looks installed and never runs.

| hook | master | guards |
|---|---|---|
| `pre-commit` | `audit/pre-commit` | secret-shaped paths — the **second lock** on `.gitignore` |
| `pre-push` | `ci/pre-push` | runs `ci/shellcheck.sh`, the same check CI runs |

**The split between them is the point, not an accident.** Secrets are stopped at
COMMIT time because this repo is public and force-pushes to every mirror — CI runs
after the push, which is after the leak, so CI cannot help at all. A shell fault is
reversible and costs only a red build, so it is checked once per PUSH; a check that
fires on every docs typo teaches `--no-verify`, and that is the same flag that would
disarm the secret guard. **Neither hook replaces CI**, which stays the authority: a
hook can be bypassed, is absent on a fresh clone until installed, never sees a
dependabot PR, and cannot gate the mirror publish the way `needs:` does.

Conventions: third-party actions are pinned to full commit SHAs with a `# vX.Y.Z`
comment (a trivy-action tag deletion once broke CI for 5 weeks); `.github/dependabot.yml`
bumps the pins weekly via PRs, which the `pull_request` trigger vets pre-merge.
Trivy was removed deliberately — no lockfiles to scan, and its misconfig mode can't
read docker-compose (see `.claude/plans/ci-actions-canon-research.md`).

## Standing Decisions (audit 2026-08-07 → 08-10 — do not re-raise without new information)

- **Ubuntu Pro / ESM: deliberately not attached.** 15 universe packages have unreachable security updates (`imagemagick`, `libav*`, `libsvn*`, `libzvbi*`, and **`restic`**). Free for personal use, and the apt pins are already in place — declined because attaching registers the machine with Canonical, and the packages are desktop media libraries not exposed to untrusted input on this box. `restic` is the one genuine exception; accepted.
- **Secure Boot: deliberately left off, firmware in Setup Mode.** Verified 2026-08-10 that standard Secure Boot **would not** mitigate the evil-maid case here: the boot chain is split kernel+initrd (no UKI), the kernel is signed but **the initramfs is not signed or verified by anything**, and the initramfs is exactly what an attacker would swap to capture the passphrase. Fixing it properly needs a Unified Kernel Image re-signed on every initramfs rebuild — and this box rebuilds on every kernel update because `tailscaled.state` is baked in. TPM-sealed unlock is worse: it contradicts the deliberate passphrase-at-dropbear design. A BIOS password is the proportionate mitigation. Threat requires physical access.
- **ufw: deliberately disabled.** Key-only SSH closes the LAN gap. **Never run a bare `ufw enable`** — `/etc/ufw/user.rules` allows only TCP 80/443 with `DEFAULT_INPUT_POLICY="DROP"`, so enabling as-is cuts port 22 (including the fallback unlock path) and UDP 41641, while nothing on the host even listens on 80 or 443.
- **`caddy/flags/maintenance.on` is intentional.** catallenya.com serves 503 to the public on purpose; `/api/votes/*` is excluded and stays live. Nothing monitors this, so it will not remind you.
- **Immich PostgreSQL 14: track upstream, do not migrate ahead of it.** EOL 2026-11-12, but Immich's own docs still recommend the exact image running here (`postgres:14-vectorchord0.4.3-pgvectors0.2.0`) and publish **no** major-version upgrade procedure. Move when Immich moves.
- **Tailnet ACL is `{"src":["*"],"dst":["*:*"]}` — fully permissive, left as-is.** Was urgent only because Flame was two hops from host root; Flame is now deprecated. Tightening carries lockout risk for no remaining concrete path.
- **Syncthing: all 7 folders `sendreceive`, 6 devices, intentional.** Note that Syncthing pairing is INDEPENDENT of Tailscale — removing a device from the tailnet does **not** revoke its Syncthing write access. `master/` feeds the documents pipeline.
- **Immich share keys committed to the public `carrein-blog` repo are public by design** — the blog embeds them in client-side JS. Not a leak; do not "fix" by deleting the shares.
- **Caddy access logging: deliberately OFF** (decided 2026-08-11). There is no `log` directive anywhere in the Caddyfile and that is a choice, not an omission. Every service is tailnet-only and there is exactly one public site, so the logs would be a record of the owner's own browsing; against that, an access log is unbounded by default and needs a rotation policy to stop it eating the pool. Turning it on later is a Caddyfile edit plus a **restart** — a `reload` is a no-op here because the Caddyfile is a FILE bind-mount, not a directory.
- **upvotes API is gated only by an `Origin` header, accepted.** `Origin` is trivially spoofable by any non-browser client, so the vote endpoint is effectively open to anyone who finds it. Worst case is inflated counts on a personal blog; there is no auth to bypass and no data to leak. Fixing it is an application change in the separate `carrein/upvotes` repo, not infrastructure.
- **All 26 containers share one flat Docker bridge, accepted.** Any container can reach any other, so a compromise in one is a compromise of the network path to all. Segmenting into per-stack networks is a project-sized change touching every service definition and Caddy's upstreams, and the concrete paths that motivated it are already closed: Flame is deprecated and nothing is published beyond the tailnet. Revisit only if a service is ever exposed directly to the internet.
- **One B2 key that can delete, deliberately — the append-only split was considered and declined 2026-08-07.** The single application key in `.rclone.conf` can permanently delete, so anything that gets root on this box can erase the backups as well as the disks. The split is real and works: B2 needs `deleteFiles` for `b2_delete_file_version` but only `writeFiles` for `b2_hide_file` (both verified against the API docs), so a daily key **without** `deleteFiles` still runs backups — lock files get hidden rather than deleted, and hiding is reversible — while a second, privileged key does `forget --prune`. Declined because the protection is only real if the privileged key is somewhere the daily job cannot read, and both keys living in the same 0600 file on the same box buys nothing. Doing it properly means either a root-only key file with `restic.forget.service` running as root (stops a `carrein`-level compromise, **not** root — and watchtower pulls new images hourly with full Docker socket access, which is a plausible root path), or keeping the delete key off the box entirely and pruning by hand. The second is the only version that survives root, and a manual chore fifty times a year does not survive contact with reality. Note issue #6 (drop rclone, restic straight to B2) would change the shape of this entirely — settle that first if it is ever revisited.
- **No automated restore drill, accepted 2026-08-07.** Nothing has ever proven end-to-end that this repository restores. What exists instead: `restic/misc/restic.restore.sh`, a restore target deliberately off-pool at `/mnt/restore`, a measured ~12h RTO at real B2 throughput, and the monthly `check --read-data-subset` that verifies pack contents actually decrypt. That is verification of the data, not rehearsal of the procedure — the untested part is the human runbook, not the bytes. Left manual because a scheduled drill needs 1.5 TiB of scratch space this box does not have spare, and the honest substitute is doing one by hand after any change to the restore path.
- **The shared AI layer has FOUR verdicts, and an exhausted balance is `paused`, not fatal** (closed 2026-08-10; the gap was found 2026-08-11 and is described in `.claude/memory/ai-paused-state-design.md`). `api_class()` in `ai/scripts/ai.lib.sh` returns `ok|retry|paused|fatal` and takes the response BODY as an optional second argument, because the status code cannot separate an unusable ACCOUNT from an unusable REQUEST — an empty balance and a revoked key both arrive as 403. Out of credits is a 402, a 403 carrying `billing_error`, or a 400 whose *message* names the credit balance; `api_post` returns rc 3 and spends no retries on it. Consumers need only three branches — proceed, resolve now, park — because `retry` and `paused` are disposed of identically and differ only in the sentence `ai_reason()` supplies. Before this, a billing pause was `fatal`: afterimage archived a perfectly good screenshot as failed and pruned the image a week later, and pigeonhole marked the document blocked and never retried it.

## Key Conventions

- **`.gitignore` uses per-file allowlists, never `!dir/**`** (completed 2026-08-10). The file starts with `*` deny; a `**` allowlist silently auto-tracks whatever lands in that directory later, and **this repo is public**. Proven with `git check-ignore --no-index` that `ntfy/api-token.txt`, `systemd/id_rsa`, `restic/backup/creds.env`, `restic/staleness/token`, `.github/workflows/secrets.env` and — sharpest — `tailscale/initrd-identity/tailscaled.state`, the persistent tailnet **node key**, would each have been committed on sight. Adding a new tracked file in those dirs now needs an explicit line; that friction is the point. `audit.sh` §16 fails if anything code-shaped ends up ignored.
- **`no-new-privileges` is NOT set on `archivebox`/`archivebox_scheduler`** — tried 2026-08-10 and reverted. `crontab` is setgid and `archivebox_schedule.py` calls `CronTab(user=True)` at startup; under NNP that read fails with `OSError: Read crontab archivebox: crontabs/archivebox/: fopen: Permission denied` and the scheduler crash-loops. Also not set on `tailscale`: it is `network_mode: host`, so recreating it drops tailnet SSH — do that one from the console if ever. Everything else has it.

- All persistent data lives under `/zpool/catallenya/<service>/data`
- Services run as `user: "1000:1000"` where possible for filesystem permission consistency
- Security-sensitive containers (radicale) use `read_only: true`, `cap_drop: ALL`, memory limits, and `no-new-privileges`
- Watchtower is intentionally exempt from `cap_drop`/`no-new-privileges` hardening — it needs full Docker socket access for self-update and container lifecycle management. Hardening breaks its self-update pull and prevents it from scanning other containers. Uses `nickfedor/watchtower` fork (not `containrrr/watchtower`) for Docker 29+ API compatibility.
- Watchtower handles image updates for registry-pulled images; archivebox requires manual rebuild since it uses a local Dockerfile
- The Caddyfile uses env var substitution (`{$VAR}`) for all domains and ports -- never hardcode these values
