# The job system

Sixteen background jobs keep this server honest — backups, disk checks, ZFS
scrubs, document filing, screenshot triage. They run under a shared contract
rather than each inventing its own.

*As of 2026-08-13.*

## The problem this solves

The jobs were written one at a time over two years. Each decided for itself
whether to shout when it broke, how long to wait before giving up, how
locked-down to run. They drifted, and an audit found the shape of it:

| Question | Answered before |
|---|---|
| Did the job **crash**? | 13 of 16 jobs |
| Did the job **ever run**? | 1 of 16 |
| Did the job **hang**? | Unbounded on all four restic jobs |
| Did the job **skip**? | Nothing — a failed `Condition=` has no exit code |

The second row is the dangerous one. A job that crashes is loud. A job that
quietly stops just… doesn't happen, and everything looks fine. Five jobs here
are silent when healthy, so silence and death were indistinguishable.

## The idea it is built on

> **A job reporting success is not the same as a job having done its work.**

Nearly every bug found while building this was that shape. A backup that skips
unreadable files and exits zero. A sweep that cannot reach the network and
reports success anyway. A health check with an empty watch list, cheerfully
reporting all clear because the loop it would have run never ran.

So jobs record **completion**, not merely that they were started, and the
watchdog checks what they *produced* — a snapshot, a scrub date, a file — rather
than taking their word for it.

## Three layers

Policy is inherited from layered systemd drop-ins. A job declares which layers
it belongs to; it never restates the rules.

```
<unit>.service.d/10-base.conf      every job          what it is
<unit>.service.d/20-<class>.conf   how it's triggered scheduled | monitor | adhoc
<unit>.service.d/30-<family>.conf  what it talks to   intake | restic
<unit>.service                     the job itself     (weakest layer)
```

Each layer can **set** or **require** — the difference between a concrete method
and an abstract one:

| Power | Meaning | Example |
|---|---|---|
| **set** | Inherited, identical for the layer, final. The unit cannot override it | [`20-adhoc.conf`](policy/20-adhoc.conf) sets the start limit, so no event-driven job can drift |
| **require** | Varies per job, but [`install.sh`](install.sh) refuses to install without it | `scheduled` requires a timeout — 5 min for a sweep, 12 h for a full integrity check, never absent |

**Class is how a job is triggered. Family is what it touches.** They cross-cut,
which is why they are separate axes rather than a hierarchy:

|  | family `intake` | family `restic` | — |
|---|---|---|---|
| **`scheduled`** | `afterimage.sweep`, `pigeonhole.sweep` | `restic.backup`, `forget`, `check@` | `immich.fix-rotations`, `zpool.scrub` |
| **`monitor`** | — | `restic.staleness` | `disk`, `changedetection.health`, `heartbeat` |
| **`adhoc`** | `afterimage.triage`, `pigeonhole.triage`, `pigeonhole.apply` | — | `catallenya` (boot is an event) |

Measured effect: **286 directives across the units became 40 written once.**

## The gate

[`install.sh`](install.sh) validates every unit against its contract and
**aborts before creating any link** if one fails — never half-configured. It is
also the only sanctioned way to put a unit on this box, and the same map drives
both the symlink and the policy, so an unregistered job does not get installed
without policy: it does not get installed at all.

```bash
bash systemd/install.sh --check   # validate without installing, no root needed
bash systemd/tests/run.sh         # offline suite: every refusal, every finding
systemctl cat <unit>              # see a job's merged policy layers
```

## The watchdog

[`catallenya.heartbeat`](catallenya.heartbeat.timer) runs daily and answers what
nothing else could: **did each job actually run, and did it do anything.** Silent
when healthy.

| Class | What "fresh" means |
|---|---|
| `scheduled` | a declared artifact — a stamp, a ZFS scrub date, a snapshot age |
| `monitor` | its own completion stamp |
| `adhoc` | is the watcher armed, and is the thing that feeds it alive |

**Jobs record their own completion because systemd cannot.** Its runtime
timestamps are discarded the moment a successful oneshot exits —
`zpool.scrub.service` reports `Result=success` with *every timestamp empty*. The
stamp is written by `ExecStartPost=` in [`10-base.conf`](policy/10-base.conf),
which systemd runs **only when `ExecStart` succeeded**, so no script had to
change and none can record a false success.

## Traps, each measured on this box

These are the reasons the design looks the way it does. Every one was verified
rather than assumed, and several contradicted what the documentation implied.

**Drop-ins outrank the unit file.** A unit's `RuntimeMaxSec=999` lost to a
drop-in's `111`. So only genuinely invariant settings may be *set*, and the gate
refuses a unit that re-declares one — a line that does nothing reads as
configuration and is a lie.

**`RuntimeMaxSec=` is ignored on `Type=oneshot`** while `systemctl show` still
reports it as set. Every job here is oneshot, so `TimeoutStartSec=` is the only
working hang bound.

**A failed `Condition*=` is a skip, not a failure** — no exit code, no
`OnFailure=`, no journal error. That is how sanoid stopped taking snapshots
silently after a package upgrade. `Requires=` fails loudly instead, and the gate
bans `Condition*=`.

**`ProtectClock=true` closes `/dev/zfs`.** It implies a `DeviceAllow=`, which
collapses the default `DevicePolicy=auto` into a closed allowlist. Measured by
isolating the single directive:

```
ExecStart=/usr/sbin/zpool status         → Result=success
same unit + ProtectClock=true            → Result=exit-code
```

Two jobs would have failed loudly. The watchdog would have failed *silently*,
reporting "no snapshots exist" every day forever — becoming the thing it was
built to detect.

**An empty assignment does not reset `[Unit]` dependency lists.** It works for
`[Service]` exec lists (`Environment=`, `ReadWritePaths=`) and does nothing at
all for `OnSuccess=`/`OnFailure=`, with no warning. A policy layer cannot strip
one, so the gate refuses it instead.

**`NoNewPrivileges=true` breaks `runuser`.** The boot orchestrator drops to
another user through PAM to run `docker compose`; under `no_new_privs` that
fails with `cannot set user id`, and nothing starts. It is the single unit
exempted, in [`install.sh`](install.sh), with the measurement recorded.

## What testing missed

Worth stating plainly, because it is the most useful thing here.

An offline suite of 49 cases passed. Four adversarial reviews — each told to
break one thing — then found **nine defects**, including two that would have
made the watchdog completely silent and one that would have deleted a file
belonging to another package.

Deployment found **four more** that no offline test could reach:

| Found by | Bug |
|---|---|
| A real install | The prune deleted the instance stickers it had just created |
| A real restart | `NoNewPrivileges` breaks `runuser` — nothing would start at boot |
| A real watchdog run | It reported a unit that was masked deliberately |
| A real monitor run | `ProtectHome` breaks restic's cache, so the job watching backups would have failed nightly |

Every layer caught things the layer before it could not. The tests could not find
what the adversaries did, and the adversaries could not find what running it did.

The corollary, learned twice in one session: **a passing probe that is not the
real thing proves nothing.** A transient test unit succeeded where the actual
unit failed, and `systemctl start` on an already-active unit reported success
without running anything.

## Known open

- **The watchdog is the one thing nothing watches.** A crash is covered; never
  running is silent. This is irreducible on-box — any watcher needs a watcher —
  and escaping it requires an off-box dead-man's switch where silence is the
  alarm. Accepted deliberately; the reasoning is in [CLAUDE.md](../CLAUDE.md).
- A `.path` watcher can be armed while its producer runs but delivers nothing.
  Container-alive is a floor, not a proof.
- Nothing watches the 26 containers between boots.

## Layout

```
systemd/
├── policy/          the factory — base, three classes, two families
├── tests/run.sh     offline suite: gate refusals and watchdog findings
├── state/           completion stamps (gitignored — runtime state)
├── install.sh       installs, and refuses to install what breaks the contract
├── heartbeat.sh     the watchdog — reads every job's sticker, asks if it ran
└── catallenya.heartbeat.{service,timer}   its unit and schedule
```

This directory holds the contract and the one job whose subject *is* the
contract. Everything else it governs lives with what it serves: a job's unit and
its body sit together, in the directory of the thing the job is about —
`../host/` for the machine, `../restic/`, `../immich/`, `../afterimage/` and so
on. That is also why per-instance metadata for template units lives beside its
units, in [`../restic/check/`](../restic/check/), rather than here.

The courier every `OnFailure=` points at is the one deliberate exception, in
[`../ntfy/`](../ntfy/). It is not a job and inherits nothing from this contract —
a failed alert must not call the courier to complain about the courier.
