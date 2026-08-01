# The intake playbook

Two pipelines turn things I drop into things I approve: **capture** (screenshot →
calendar event) and **documents** (file → filed document). They converged on one
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
```

| Aspect | Capture | Documents |
|---|---|---|
| Home | `capture/` | `documents/` |
| Drop zone | `capture/data/incoming/` | `syncthing/data/master/documents` root |
| Trigger | `.path` on `*.png` (bytes sniffed, JPEG welcome) | `.path` on 28 typed globs |
| AI | one opus-5 vision call, shared config | same |
| Buttons | Add / Discard | Accept / Discard / Skip |
| State | `incoming → pending → archive` | `root → staging → (folder \| bin)` |
| Backstop | folded into the sweep | `documents.backstop.timer` 03:00 SGT |
| Sweep | 07:30 SGT | 07:45 SGT |
| Writer | the container (CalDAV PUT) | `documents.apply.service` (host oneshot) |
| Tests | `capture/tests` + `ai/tests` | `documents/tests` + `ai/tests` |

## The rules, and why they are rules

**State is the filesystem.** A thing is wherever it currently sits, `ls` answers
"what is the system doing", and nothing can desync from anything else. No ledgers,
no state files beside the state — per-record JSON (decision.json, the proposal
records) exists because undo needs it, not as a second copy of history.

**Nothing writes without a human tap**, and each button means "put this in the
state I name, from wherever it is". That phrasing is what makes undo fall out
instead of being built: Discard after Add undoes the add; Discard after filing
pulls the document back to bin/.

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

## The two containers stay separate — do not "clean this up"

Capture's Bun container holds a full-scope Radicale credential and performs the
CalDAV write itself. Documents' container holds **nothing** and can only write a
zero-byte marker into `approvals/`; the moves are done by hardened host oneshots
(`documents.apply.service`, `documents.sweep.service`) that no network packet can
reach. They look like one container's worth of code, but merging them would give
the calendar credential to the surface that today holds no secret at all. The
asymmetry is the security design, not an accident of history.

## Adding a pipeline

Copy the shape: own top-level directory (code only; per-file `.gitignore`
allowlist, never `**`), a drop zone, a `.path` unit that drains, one call through
`ai.lib.sh`, buttons whose meaning is a target state, a hardened writer, a
morning-side sweep, `<topic>.<job>` unit names with `OnFailure=system-ntfy@`, and
an offline test suite under `<pipeline>/tests/run.sh`. `audit/audit.sh` will hold
you to the mechanical parts.
