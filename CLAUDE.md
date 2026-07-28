# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
# Reconstructs fileCreatedAt from EXIF / filename / ffprobe / mtime.
# Requires exiftool on host: sudo apt install -y libimage-exiftool-perl
bash immich/scripts/immich.fix-dates.scan.sh   --date-cluster=2023-02-19 --limit=100
bash immich/scripts/immich.fix-dates.verify.sh
bash immich/scripts/immich.fix-dates.apply.sh  --dry-run

# Immich rotation bake (lossless EXIF orientation for UI rotate edits)
# Runs daily at 04:00 SGT via immich.fix-rotations.timer; manual run:
bash immich/scripts/immich.fix-rotations.sh --dry-run   # preview
bash immich/scripts/immich.fix-rotations.sh --yes       # apply now

# Documents intake (scan → classify → apply pipeline)
# Files new documents dropped at the root of syncthing master/documents per
# .../documents/.claude/FILING-SCHEME.md. Daily 03:00 SGT via documents.intake.timer.
# Requires on host: sudo apt install -y tesseract-ocr  (poppler-utils/imagemagick already present)
bash syncthing/scripts/documents.intake.scan.sh > /tmp/s.json          # deterministic, no LLM
bash syncthing/scripts/documents.intake.classify.sh < /tmp/s.json > /tmp/a.json
bash syncthing/scripts/documents.intake.apply.sh --dry-run < /tmp/a.json   # preview
bash syncthing/scripts/documents.intake.daily.sh --dry-run             # whole pipeline, no writes

# Capture pipeline (screenshot → opus-5 vision → ntfy Add/Discard → Radicale)
# Event-driven, not scheduled: capture.triage.path fires the moment a PNG lands in
# capture/data/incoming/. Laptop hotkey client + notification format in capture/README.md.
sudo systemctl start capture.triage.service   # drain incoming/ now (systemd injects the API key)
bash capture/scripts/capture.sweep.sh         # re-notify stale proposals, archive ignored ones
# Accept rate. capture/data/recording-mode holds one word — off | test | prod.
# Currently `test`: captures are kept, but verdicts go to decisions.test.jsonl so
# they cannot contaminate the production rate. `off` deletes resolved captures.
jq -s 'group_by(.outcome)|map({outcome:.[0].outcome,n:length})' capture/data/decisions.jsonl 2>/dev/null || echo 'no decisions recorded yet'
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
| `CAPTURE_REVERSE_PROXY_PORT`     | Capture (10000) |

### Service Dependencies

- **Immich** depends on `redis` (Valkey) and `postgres` (custom pgvector image)
- **Memoka** depends on its own `memoka_postgresql` (pgvector/pg17) and `memoka_redis`
- **Zipline** depends on `zipline_postgresql`
- **Archivebox** uses `archivebox_sonic` for search; scheduler depends on both
- **Caddy** depends on `tailscale` for TLS certificate socket
- **carrein-blog** (`ghcr.io/carrein/carrein-blog`) and **upvotes** (`ghcr.io/carrein/upvotes`, Bun + SQLite) sit behind Caddy's `http://catallenya.com` block — no host port mapping; reached only via the cloudflared tunnel
- **Capture** is a locally-built Bun container (like archivebox, no GHCR image) on `CAPTURE_REVERSE_PROXY_PORT` (10000) with no host `ports:`. It is deliberately dumb — it accepts the uploaded screenshot and, on an ntfy button tap, does one CalDAV `PUT` to `radicale:5232` reusing the same `MITSUME_DAV_B64` Caddy injects for mitsume. All the intelligence (the opus-5 vision call, the `.ics` renderer) lives in the host triage, which shares only the `capture/data/` spool with the container; that split is kept so the triage can serve future non-capture consumers
- **Changedetection** depends on `changedetection-browser` (sockpuppetbrowser, Chromium via Playwright over WebSocket) for JS-rendered fetches. The companion needs `cap_add: SYS_ADMIN` for the Chromium user-namespace sandbox; the main container needs `CHOWN/FOWNER/DAC_OVERRIDE` because the image runs as root and writes to a non-root-owned bind mount. Notifications fan out via ntfy using Apprise URL `ntfy://ntfy/${CHANGEDETECTION_NTFY_TOPIC}` — configured in the UI, not in env.

### Secrets Management

Docker secrets are used for sensitive values (stored as gitignored files under their respective service directories). Additional credentials (DB passwords, service secrets) are in `.env`, which is also gitignored.

### Backup System

Restic backs up to cloud storage via Rclone (configured in `restic/restic.conf`). Managed by systemd timers:
- `restic.backup.timer` - scheduled backups
- `restic.check-meta.timer` / `restic.check-data.timer` - integrity checks
- `restic.forget.timer` - prune old snapshots (retention: 5 daily, 2 weekly, 3 monthly, 1 yearly)

**Database backup strategy:**
- **Memoka**: `pg_dump` runs before restic on each backup, writing to `memoka/backup/memoka.dump.sql.gz`. Raw `memoka/postgres` and `memoka/redis` dirs are excluded from restic (unsafe to copy live). On restore, start `memoka_postgresql` first, load the dump via `psql`, then start remaining services (see `restic/misc/restic.restore.sh` for exact commands).
- **Immich**: Handles its own DB backup internally — dumps are written to `immich/data/backups/` which restic picks up automatically.
- **Upvotes**: SQLite `VACUUM INTO` runs inside the upvotes container before restic, writing to `upvotes/dump/votes.db`. Live `upvotes/data` is not in restic targets — only the consistent dump is. Restore: stop upvotes, copy dump back to `upvotes/data/votes.db`, remove stale `-wal`/`-shm`, restart.
- **Zipline**: Not backed up (intentional).
- **Capture**: Not backed up (intentional). `capture/` is deliberately absent from restic's path allowlist — a screenshot can hold anything that was on screen, so none of it leaves the box. ZFS + Sanoid still cover disk failure. Do not add `capture/` to restic without revisiting that decision.

ZFS snapshots are managed by Sanoid separately.

### Boot Orchestration

`catallenya.service` is a oneshot systemd unit that runs at boot after ZFS and Docker are ready. It is the **one unit file that lives on root filesystem** (`/etc/systemd/system/catallenya.service`) — all other project units are symlinks into `/zpool/catallenya/` which don't resolve until ZFS mounts.

**What it does** (via `systemd/catallenya.sh`):
1. `systemctl daemon-reload` — re-reads unit files now that ZFS symlinks resolve
2. Starts all project timers
3. `docker compose up -d` — brings up containers (as `carrein`)
4. Verifies all containers reach `running` state
5. Posts success/failure notification to ntfy `/boot` topic

**Key commands:**
- `systemctl status catallenya` — check boot state (green = all OK)
- `sudo bash systemd/install.sh` — set up systemd on a fresh server (writes service, creates symlinks, enables everything). Idempotent.
- `journalctl -u catallenya` — boot orchestrator logs

### Remote LUKS Unlock

The host's encrypted root supports SSH-driven remote unlock. `dropbear-initramfs` + `tailscale-initramfs` are baked into every kernel's initramfs; on boot the box comes up on the tailnet as `catallenya-initrd` (tagged `tag:initrd`) and accepts SSH on port 22 with the forced command `cryptroot-unlock`.

The tailnet has tailnet lock (TKA) enabled. Rather than re-registering a fresh ephemeral node each boot (which caused `catallenya-initrd-N` duplicates), the initramfs now carries a **persistent node identity**: `tailscaled.state` lives at `/etc/tailscale/initramfs/tailscaled.state` and is baked into every image by the hook `/etc/initramfs-tools/hooks/initrd-tailscale-state` (repo copy in `tailscale/initramfs-hooks/`), so the node resumes the same identity each boot. It is **state-only** — no auth key in `/boot`; a patched premount override (`/etc/initramfs-tools/scripts/init-premount/tailscale`) omits `--authkey` when empty. The node is signed by a SigDirect under the host's durable `self` TKA key. The old monthly auth-key rotation is retired; `tailscale/initrd-identity/generate-initrd-state.sh` regenerates the identity on demand (recovery: mint a one-off `tag:initrd` key in the admin console, then run it with `--authkey=… --rebuild`). **Never delete the `catallenya-initrd` node** in the Tailscale console — it shows offline while the box runs, and deleting it orphans the baked identity.

Fallback unlock paths: LAN dropbear (`ssh -p 22 root@<lan-ip>` — most reliable at home, no relay) and physical console (LUKS slot 0 = daily passphrase, slot 7 = paper recovery in password manager). In initramfs the node connects via DERP relay only, so when away connect once and allow ~30–90s. Full runbook + addendum in `docs/remote-luks-unlock.md` (host-local, gitignored).

### Monitoring

- **Disk monitoring**: `systemd/disk.timer` runs hourly (`ntfy/disk-ntfy.sh`), alerts via Ntfy at 75% usage. Root is measured with `df`; the zpool is measured with pool `capacity` (`zpool list`), which counts snapshot-held space — `df` under-reports it
- **Service monitoring**: `ntfy/system-ntfy.sh` reports restic job status to Ntfy
- **ZFS pool monitoring**: ZFS Event Daemon (`zed`) publishes pool events (scrub, errors, resilver) to the `zpool` ntfy topic. Configured on the host at `/etc/zfs/zed.d/zed.rc` (`ZED_NTFY_TOPIC`, `ZED_NTFY_URL`) — not in this repo. Sanoid handles snapshots only and is not wired to ntfy.
- **Immich rotation bake**: `immich.fix-rotations.timer` runs daily at 04:00 SGT (`OnCalendar` pins `Asia/Singapore`, DST-safe) via `immich/scripts/immich.fix-rotations.daily.sh`, baking pending UI rotate edits into originals losslessly. Notifies the `immich` ntfy topic only when something was baked, failed, or skipped for a reason needing a human; silent when there is nothing to do (crop/mirror edits are intentionally left alone)
- **Documents intake**: `documents.intake.timer` runs daily at 03:00 SGT (clear of the immich bake at 04:00), classifying and filing anything dropped at the root of `syncthing/data/master/documents` per its `FILING-SCHEME.md`. Notifies the `documents` ntfy topic only when something was filed, removed, flagged, or failed — silent when nothing arrived. Scope is **root files only**; the ~131 already-filed documents are never read or moved, only hashed for duplicate detection. Design + verified CLI traps in `.claude/plans/documents-nightly-intake{,-canon}.md`
- **Capture triage**: `capture.triage.path` — the repo's only `.path` unit, everything else polls — fires `capture.triage.service` the instant a screenshot lands in `capture/data/incoming/`, which calls `claude-opus-5` with vision and posts proposed events to the `capture` ntfy topic with Add/Discard buttons. Nothing reaches Radicale without a tap. PNG and JPEG are both accepted (Android screenshots are JPEG); the spool name is always `<id>.png` because that is the glob the root-owned `.path` unit keys on, so the triage sniffs magic bytes rather than trusting it. One screenshot can describe several events — the triage fans them into one record per event, capped at `MAX_EVENTS_PER_CAPTURE`, sharing a hardlinked image, so nothing downstream needs to know. Past events are detected by `event_is_past()` in code, never by the model, and collapsed into one "already passed" note. Transient API failures retry in-process and then via the sweep; a run that triages nothing exits non-zero so `OnFailure=` fires. The triage **must** move every file out of `incoming/` on every branch: `PathExistsGlob` re-fires while a file remains, so a leftover PNG hot-loops systemd and bills an API call per spin. `capture.sweep.timer` runs hourly (no API calls) to re-notify a proposal untouched for 24h, re-queue one the API failed on, archive at 7d as `ignored`, and prune screenshots older than `PRUNE_IMAGE_AFTER_DAYS`. Retention is one word in `capture/data/recording-mode` — `off | test | prod` — stamped into each record at capture time, so a test capture tapped later is still counted as a test; test verdicts go to `decisions.test.jsonl`. `ANTHROPIC_API_KEY` lives in `/etc/capture.env` (root-owned 0600, injected into the `User=carrein` process) — deliberately **not** in `.env`. The Radicale credential is a docker secret (`capture/dav-secret`), not an env var. `bash capture/tests/run.sh` is the offline regression suite; every case in it is a bug that shipped. Design, bake-off results, and post-deploy fixes in `.claude/plans/capture-pipeline-plan.md`
- **Capture accepted risks** (reviewed 2026-07-27, do not re-raise without new information):
  - *The capture container holds a full-scope Radicale credential.* `capture-dav-secret` is `base64(carrein:<app pw>)` — the same value Caddy injects for mitsume — and Radicale's `[rights]` is empty, so it defaults to `owner_only`: that credential can read, write and **delete** everything under `/carrein/`, not just the two collections capture writes. Scoping it means a separate user plus a `from_file` rights config, and that config then governs **your own** access too; getting it wrong locks you out of your own calendar and breaks mitsume and phone sync. Weighed against a code-execution bug in ~190 lines of Bun that runs read-only, non-root, `cap_drop: ALL`, `no-new-privileges`, tailnet-only and header-gated. Accepted. A second password for the same user is not a workaround — htpasswd does not do that reliably.
  - *Multi-event screenshots fan out into one record per event* (built 2026-07-27). The model returns `events[]`, capped at `MAX_EVENTS_PER_CAPTURE`, and the triage creates a separate record — own id, own notification, own buttons — for each, hardlinking the one screenshot into all of them. The container, sweep, archive and ledger were deliberately left untouched: each record is exactly the single-event shape they already handle, so no indexed callback was needed. `events_seen` still carries the true page total and the body says "Event 2 of 4 from one screenshot (6 on the page)" when the list was capped.
  - *ntfy carries no authentication.* Pre-existing, accepted before this pipeline existed. The callback ids are unguessable UUIDs and the `X-Capture` header blocks the browser vector; anyone who can read the topic can still act on a proposal.
- **Watchtower**: Auto-updates containers with `com.centurylinklabs.watchtower.enable=true` label, polls hourly

### CI/CD

GitHub Actions (`.github/workflows/ci.yml`) runs on push to main, PRs, and manual dispatch:
- **GitLeaks** (v3): scans full git history for leaked secrets. Known-fake findings are
  suppressed by fingerprint in `.gitleaksignore` (the deliberate 2025-11-05 test key; a
  2026-07-27 false positive on a prose comment). CI pins **8.24.3** — 8.30.1 does not
  flag the same things, so verify with the pinned version, not `:latest`:
  `docker run --rm -v "$PWD:/repo" -w /repo zricethezav/gitleaks:v8.24.3 detect --redact`
- **compose-validate**: `docker compose --env-file .env.ci config --quiet` plus a drift
  guard that fails if a `${VAR}` in docker-compose.yml has no line in `.env.ci`. When
  adding a new compose variable, add a dummy (shape-valid) line to `.env.ci`
- **shellcheck**: all tracked `*.sh` at `-S warning` (preinstalled runner binary, no action)
- **notify-failure**: curls the `NTFY_FAILURE_URL` Actions secret (ntfy.sh topic —
  tailnet ntfy is unreachable from runners) when any job fails; skips gracefully if unset

Conventions: third-party actions are pinned to full commit SHAs with a `# vX.Y.Z`
comment (a trivy-action tag deletion once broke CI for 5 weeks); `.github/dependabot.yml`
bumps the pins weekly via PRs, which the `pull_request` trigger vets pre-merge.
Trivy was removed deliberately — no lockfiles to scan, and its misconfig mode can't
read docker-compose (see `.claude/plans/ci-actions-canon-research.md`).

## Key Conventions

- All persistent data lives under `/zpool/catallenya/<service>/data`
- Services run as `user: "1000:1000"` where possible for filesystem permission consistency
- Security-sensitive containers (radicale) use `read_only: true`, `cap_drop: ALL`, memory limits, and `no-new-privileges`
- Watchtower is intentionally exempt from `cap_drop`/`no-new-privileges` hardening — it needs full Docker socket access for self-update and container lifecycle management. Hardening breaks its self-update pull and prevents it from scanning other containers. Uses `nickfedor/watchtower` fork (not `containrrr/watchtower`) for Docker 29+ API compatibility.
- Watchtower handles image updates for registry-pulled images; archivebox requires manual rebuild since it uses a local Dockerfile
- The Caddyfile uses env var substitution (`{$VAR}`) for all domains and ports -- never hardcode these values
