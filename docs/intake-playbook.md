# The intake playbook

Two pipelines turn things I drop into things I approve: **afterimage** (screenshot →
calendar event) and **pigeonhole** (file → filed document). They converged on one
shape on 2026-08-01, and this page records that shape so the next pipeline — or the
next refactor — starts from it instead of rediscovering it. The audit checks in
`audit/audit.sh` make the conventions mechanical; this page is the why.

## The shape

```
drop zone ── .path unit ── triage (ONE vision call via ai/scripts/ai.lib.sh)
                                │
                        ntfy topic, buttons
                                │ tap
                        apply (does the write)
                                │
        nightly sweep: nudge at 24h · resolve at 7d · morning-side SGT

   and when the desk cannot answer:
        park where it lies ── retry daily ── resolve at 7d from the FIRST failure
```

| Aspect | Afterimage | Pigeonhole |
|---|---|---|
| Home | `afterimage/` | `pigeonhole/` |
| Drop zone | `afterimage/data/incoming/` | `syncthing/data/master/documents` root |
| Trigger | `.path` on `*.png` (bytes sniffed, JPEG welcome) | `.path` on 28 typed globs |
| AI | one opus-5 vision call, shared config | same |
| Buttons | Add / Discard | Accept / Discard (binned: Accept / Delete) |
| State | `incoming → pending → archive` | `root → staging → (folder \| bin)` |
| Backstop | folded into the sweep | `pigeonhole.backstop.timer` 03:00 SGT |
| Sweep | 07:30 SGT | 07:45 SGT (+ `pigeonhole.retry.timer` 07:50) |
| Writer | the container (CalDAV PUT) | `pigeonhole.apply.service` (host oneshot) |
| Tests | `afterimage/tests` + `ai/tests` | `pigeonhole/tests` + `ai/tests` |

## The rules, and why they are rules

**State is the filesystem.** A thing is wherever it currently sits, `ls` answers
"what is the system doing", and nothing can desync from anything else. No ledgers,
no state files beside the state — per-record JSON (decision.json, the proposal
records) records the verdict, not a second copy of history.

**Nothing writes without a human tap**, and each button means "put this in the
state I name, from wherever it is".

**A notification lives exactly as long as its decision is outstanding** (2026-08-09).
Every tap withdraws its own notification — pigeonhole after the move SUCCEEDS, afterimage
the instant the container archives the record — so a message disappearing means the
thing happened, and one still sitting there means it did not. No button sets
`clear=true`: that dismisses on the tap, before anything has been done, and would
make a refused move or a failed CalDAV PUT look like a completed one.

This replaced the undo, which used to fall out of the state rule for free — Discard
after Add, Discard after filing — and cost a permanent notification on everything
you ever resolved. `skip` went with it: ignoring a notification already meant "leave
it in staging", and each skip restarted the 7-day bin clock, so a document could be
snoozed forever. Recovery is now the filesystem: `bin/` is never auto-emptied, the
corpus is in Syncthing on every device, and a wrongly added event is deleted in the
calendar app.

**One API call per item, through one seam.** `ai/scripts/ai.lib.sh` is the only
code that talks to api.anthropic.com — `AI_MODEL`/`AI_EFFORT` live there, requests
carry no `tools` key, and the key stays in `/etc/ai.env` (root 0600, injected by
systemd per run). The human tap is the verifier; a second "adversarial verify"
call was tried and retired — it refuted correct proposals to follow instructions.

**Every drop zone MUST drain.** `.path` units re-fire while their glob matches, so
a branch that exits without moving its file hot-loops systemd at an API call per
spin. Every triage asserts this invariant, every failure branch is tested, and a
start limit backstops the assertion itself.

**Sweeps are nightly and morning-side** (07:30 / 07:45 SGT): nearly everything a
sweep does ends in a phone notification, and 3am pings train the owner to mute the
topic. One nudge at 24h, a resolution at 7d (archive / bin — never deletion of a
document), and the sweep also names anything its pipeline cannot see (stray files,
unsupported types), because silence about a thing you dropped is the worst outcome.

**Alerts derive from unit names.** `OnFailure=system-ntfy@<topic>.<job>.service`
— the template splits the unit name to pick the ntfy topic, against an allowlist
in `ntfy/system-ntfy.sh`. New unit, new pipeline: follow `<topic>.<job>` naming,
add the topic to the allowlist, and the audit check keeps the two in step.

**A notification says what happened in its first word — and since 2026-08-20 it cannot
say it any other way.** Titles are built by constructors in `ntfy/kinds.sh` and refused
by `systemd/contract.sh` if they are not; the vocabulary, the class model and the
fifteen deliberate exceptions live in **`ntfy/MESSAGES.md`**, which is the source. Read
that before wording anything.

The short version, because it is what this page's rule became: the title reports what
happened and the button carries the imperative, so every verb is a past participle
(`Review:` became `Flagged:` for exactly that reason). Tags stay semantic and **nothing
uses `high` priority** — everything-loud is how a topic gets muted, and a muted topic
loses the loud messages first. What is shared across pipelines is decided by CLASS: an
error out of `ai/scripts/ai.lib.sh` must read identically everywhere (`Model Failed`,
`Model Paused`), while a pipeline's own machinery words its own failures. The shared
part is the discipline; the vocabulary is shared only where the situation genuinely is.

**When the desk cannot answer, the item is PARKED, not resolved** (2026-08-10).
`ai/scripts/ai.lib.sh` returns one of four verdicts, and a consumer needs only three
branches: proceed, resolve now, or park. `retry` (unreachable) and `paused` (out of
credits) share a branch on purpose — the disposal is identical and only the sentence
`ai_reason()` supplies differs.

A parked item stays exactly where it is, carries no blocked code and no flags, and
offers no buttons, because no tap is owed. It is retried once a day and resolved at
seven days measured from the FIRST failure — never from the last attempt, which is
the same reason `skip` was deleted: anything that resets a deadline lets a thing be
postponed forever. pigeonhole needs a `first_failed_at` field for this because it ages
records from their file mtime, which every retry touches.

The retry never moves the item back to its drop zone. afterimage can get away with it
(its spool is local, and the `.path` unit picks the screenshot up again) but the
document root is a Syncthing folder, so the same trick would replicate a move out and
back to every device, twice a day, for the length of the outage. `pigeonhole.triage.sh
--retry` re-classifies in place instead, and it is a separate job — `pigeonhole.retry.timer`
— rather than a branch of the sweep, because the sweep deliberately holds no API key
and nothing it does should be able to spend money.

**A desk failure is the ONE thing that is shared vocabulary, not shared discipline.**
Everywhere else, the rule below holds: each pipeline words its own messages. But "out
of credits" is not an afterimage fact or a pigeonhole fact — it is one fact arriving
on several topics, and it used to read as "Capture Failed — check the API key" on one
and "Blocked: 1 Document — The model call failed" on the other, only one of which
pointed anywhere near the problem. `paused_title()` and `paused_body()` in
`ntfy/ntfy.lib.sh` build it, `ai_reason()` supplies the reason, and only two things
vary: the noun, and the day-7 clause — because a document survives in `bin/` and a
screenshot's image does not, and hiding that would make the message consistent by
dropping the part you most need to know.

**One transport, one set of sanitisers.** `notify`, `retract`, `ntfy_id_safe`, the
`NTFY_DISABLE` mute seam, `hdr_safe` and `md_escape` all live in `ntfy/ntfy.lib.sh`.
They were four private copies until 2026-08-10 and had already drifted: two lacked
`--max-time`, and one had no `hdr_safe` at all. The sanitisers moved out of
`ai.lib.sh` at the same time — they guard the boundary where untrusted text reaches a
NOTIFICATION, which is a property of the sink and not of the API that fetched the
text, and keeping them there meant liquidroom sourced the entire AI layer while
calling no API at all.

## The two containers stay separate — do not "clean this up"

Capture's Bun container holds a full-scope Radicale credential and performs the
CalDAV write itself. Documents' container holds **nothing** and can only write a
zero-byte marker into `approvals/`; the moves are done by hardened host oneshots
(`pigeonhole.apply.service`, `pigeonhole.sweep.service`) that no network packet can
reach. They look like one container's worth of code, but merging them would give
the calendar credential to the surface that today holds no secret at all. The
asymmetry is the security design, not an accident of history.

## Adding a pipeline

Copy the shape: own top-level directory (code only; per-file `.gitignore`
allowlist, never `**`), a drop zone, a `.path` unit that drains, one call through
`ai.lib.sh`, buttons whose meaning is a target state, a hardened writer, a
morning-side sweep, `<topic>.<job>` unit names with `OnFailure=system-ntfy@`, and
an offline test suite under `<pipeline>/tests/run.sh`.

Handle all four verdicts — three branches: proceed, resolve now, park. Take the
transport and the paused message from `ntfy/ntfy.lib.sh` rather than writing your
own; the only things you supply are your noun, where you park things, and your
day-7 clause. Nothing you send uses `high`. `audit/audit.sh` will hold
you to the mechanical parts.
