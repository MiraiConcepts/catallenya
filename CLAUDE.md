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
bash restic/restic.snapshots.sh

# Restore from backup
bash restic/restic.restore.sh

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

### Service Dependencies

- **Immich** depends on `redis` (Valkey) and `postgres` (custom pgvector image)
- **Memoka** depends on its own `memoka_postgresql` (pgvector/pg17) and `memoka_redis`
- **Zipline** depends on `zipline_postgresql`
- **Archivebox** uses `archivebox_sonic` for search; scheduler depends on both
- **Caddy** depends on `tailscale` for TLS certificate socket
- **carrein-blog** (`ghcr.io/carrein/carrein-blog`) and **upvotes** (`ghcr.io/carrein/upvotes`, Bun + SQLite) sit behind Caddy's `http://catallenya.com` block — no host port mapping; reached only via the cloudflared tunnel
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

- **Disk monitoring**: `systemd/disk.timer` runs every 15 min, alerts via Ntfy at 75% usage
- **Service monitoring**: `ntfy/system-ntfy.sh` reports restic job status to Ntfy
- **ZFS pool monitoring**: ZFS Event Daemon (`zed`) publishes pool events (scrub, errors, resilver) to the `zpool` ntfy topic. Configured on the host at `/etc/zfs/zed.d/zed.rc` (`ZED_NTFY_TOPIC`, `ZED_NTFY_URL`) — not in this repo. Sanoid handles snapshots only and is not wired to ntfy.
- **Watchtower**: Auto-updates containers with `com.centurylinklabs.watchtower.enable=true` label, polls hourly

### CI/CD

GitHub Actions (`.github/workflows/security.yml`) runs on push to main:
- **Trivy**: Filesystem vulnerability scan (CRITICAL/HIGH/MEDIUM)
- **GitLeaks**: Scans git history for leaked secrets

## Key Conventions

- All persistent data lives under `/zpool/catallenya/<service>/data`
- Services run as `user: "1000:1000"` where possible for filesystem permission consistency
- Security-sensitive containers (radicale) use `read_only: true`, `cap_drop: ALL`, memory limits, and `no-new-privileges`
- Watchtower is intentionally exempt from `cap_drop`/`no-new-privileges` hardening — it needs full Docker socket access for self-update and container lifecycle management. Hardening breaks its self-update pull and prevents it from scanning other containers. Uses `nickfedor/watchtower` fork (not `containrrr/watchtower`) for Docker 29+ API compatibility.
- Watchtower handles image updates for registry-pulled images; archivebox requires manual rebuild since it uses a local Dockerfile
- The Caddyfile uses env var substitution (`{$VAR}`) for all domains and ports -- never hardcode these values
