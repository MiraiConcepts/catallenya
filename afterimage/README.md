# afterimage

> A pipeline of [catallenya](https://github.com/carrein/catallenya), mirrored from
> `afterimage/`. Force-synced by CI — open issues and pull requests on the parent
> repo, not here.

Screenshot → AI triage → proposed calendar event, confirmed with one tap.

An afterimage is what stays on your retina after you stop looking. A screenshot is
the same thing for a moment you did not have time to deal with — and this turns it
into a calendar entry, if you say so.

Press a hotkey, drag a box around a message thread or an invite. ~15 seconds later
an ntfy notification proposes the event; tap **Add** and it's in Radicale. Nothing
is ever written to your calendar without that tap.

## How it works

```
laptop hotkey ──curl──▶ Caddy ──▶ afterimage container ──┐
                                                         │  writes incoming/<id>.png
                                   afterimage/data/  ◀────┘
                                         │
              afterimage.triage.path fires ─┤
                                         ▼
                            afterimage.triage.service (host)
                              opus-5 vision → JSON → .ics
                                         │
                                         ├──▶ ntfy: [Add] [Discard]
                                         │
                        you tap ─────────┘
                                         ▼
                     afterimage container ──PUT──▶ Radicale
```

Two halves, sharing only the `afterimage/data/` spool:

- **The container** (`src/server.ts`) is deliberately dumb — receives uploads, and on
  a button tap does one authenticated CalDAV `PUT`. No AI, no `.ics` logic.
- **The host triage** (`scripts/`) holds the intelligence and the API key. It runs
  as a systemd oneshot, triggered by a `.path` unit the moment a screenshot lands.

The split exists so the triage stays a reusable API-caller for future non-capture
consumers, not because the container needs it.

The model answers with one schema-constrained object holding a LIST of events, each
with title, date, `start_time`, `end_time`, all-day, timezone, recurrence, location,
description, which calendar, and at most one alternative reading of that same event.
Most screenshots yield one; a festival day or a tour poster yields several.
`end_time` is filled only when the image actually shows a range or a duration
(`5:00 PM - 7:00 PM`, `2hrs`, `90 min`); when only a start is visible the renderer
applies a 60-minute default rather than letting the model guess. Everything
downstream of that object is deterministic — `render_ics.py` never talks to the API.

**One screenshot, several events.** The triage fans a multi-event reply into one
RECORD PER EVENT — each with its own id, `.ics`, notification and buttons, all
sharing a single hardlinked screenshot. Nothing downstream knows about this: each
record is exactly the one-event shape the container, the sweep and the archive
already handle, which is why there is no indexed callback. `MAX_EVENTS_PER_CAPTURE`
bounds the ping storm; `events_seen` records the true page total, and a truncated
list says so in the body.

**What the model decides, and what code decides.** The model reads the image and
lists what it sees, past events included. Whether an event is *over* is computed by
`event_is_past()` from its date, start time and the capture moment in `EVENT_TZ` —
never asked of the model. Upcoming events each get a notification; everything already
finished is collapsed into a single "Already Passed" note listing the titles. A page
where nothing is left produces just that one note.

**Year resolution** is a hierarchy, and only the last step is a guess: an explicit
year beside the date, then a year anywhere else in the image (event name, footer,
URL, hashtag), then *calculated* from a stated weekday — a date falls on a given
weekday about one year in six — then the next occurrence for a yearly recurring
event, and only then the current year, taking the nearest candidate still ahead.

## Components

| Path | What |
|---|---|
| `src/server.ts` | Bun HTTP surface: upload + Add/Discard callbacks + CalDAV PUT |
| `scripts/afterimage.triage.sh` | opus-5 vision call, `.ics` render, ntfy proposal |
| `scripts/afterimage.sweep.sh` | nightly 07:30 SGT: re-notify stale proposals, re-queue after a transient API failure, archive ignored ones, withdraw the notifications of resolved records, keep the paused summary in step, prune old screenshots, report stray files in `incoming/` |
| `scripts/afterimage.lib.sh` | shared config + the deterministic guards: `validate_proposal`, `triage_route`, `event_is_past`, `diff_axis`, `button_label`, `capture_actions`, `fork_record`, `fan_out_records`, `parked_ids` |
| `../ntfy/ntfy.lib.sh` | **shared with every pipeline** — `notify`, `retract`, `paused_sync` and the sanitisers `md_escape`/`hdr_safe`. See `ntfy/tests/run.sh` |
| `../ai/scripts/ai.lib.sh` | **shared with pigeonhole** — everything that talks to the API: `api_post` retry, `api_class`, `image_mime`, `ai_build_request`, `ai_extract`. See `ai/README.md` |
| `tests/run.sh` | offline regression suite — every case is a bug that shipped. Transport cases live in `ai/tests/run.sh` and `ntfy/tests/run.sh`; run all three |
| `scripts/render_ics.py` | deterministic RFC 5545 writer (fold/escape, timed events converted to UTC — no VTIMEZONE by design) |
| `systemd/` | `.path` trigger + `.service` + nightly sweep `.timer` |
| `client/afterimage.sh` | **laptop-side** hotkey script (install steps in [OPERATIONS.md](OPERATIONS.md)) |

## The notification

The proposal is laid out as a calendar entry, not a sentence — the tap is the only
gate before anything is written, so it has to be checkable at a glance:

```
📅  Property viewing
    Sunday, 26 July 2026
    13:00 - 14:00
    5 Everton Park

    [ 13:00 ]   [ Discard ]
```

Title is the event name; the body is one fact per line in 24-hour time, and empty
fields are simply absent — an all-day event shows no time line, one with no venue
shows no location line. The calendar it will land in is *not* shown: it read
"General" on almost everything, and the one case it was informative for — a
birthday — announces itself in the title. The primary button is the event's own
start time rather than the word "Add", so a glance at the buttons is enough to see
what you are choosing between.

When the model saw a second plausible reading of the SAME event the buttons become
`[13:00] [15:00] [Discard]`, and each writes that variant directly; both `.ics` files
are pre-rendered, so either tap is a file read plus one PUT. Both labels are derived
from the proposal, never named by the model — that is what stops `[19:00]` appearing
beside `[8.15pm]`. When the two readings differ by YEAR rather than by time, both
carry it: `[15 Nov 26] [15 Nov 27]`.

The body shows the alternative on whichever lines actually differ, separated by a
bullet — a tour differing by date AND venue carries it on both, because a button can
only name one axis and a body showing one city beside the other city's button would
be lying about what the tap writes:

```
📅  Kene (2/4)
    Saturday, 13 March 2027 • Friday, 19 March 2027
    All day
    Drip KL, Kuala Lumpur • Seoul

    1 more date not offered • 3 more events not sent

    [ 13 Mar ]   [ 19 Mar ]   [ Discard ]
```

A screenshot holding several events sends one notification per event, and the
position rides in the TITLE as `(2/4)` — it is the fact you want while scanning a
stack of them, and a body line is the wrong place for something you have to open the
notification to read. A lone event gets no suffix; `(1/1)` on the common case is
noise, and its absence is what makes the suffix mean something.

The last line is the italic aside, present only when there is something the
notification cannot act on. Both halves count what is MISSING, so they share a shape:
`not offered` is an alternative with no button (ntfy allows three actions and Discard
takes one, so only the first ever becomes one); `not sent` is an event
`MAX_EVENTS_PER_CAPTURE` discarded outright — no notification, no record, no button,
and the only line here reporting something irrecoverable.

Anything on the page that has already finished is not sent as its own notification —
they are collapsed into one note, so a listing where three acts are over does not
cost you three pings:

```
📅  Already Passed
    1 event already passed:
    • Safety Off!
```

**ntfy caps action buttons at 3**, which is why at most one alternative per event is
ever offered. Two different acts are two events, not two readings of one — that
distinction is why a festival page fans out instead of proposing one act as though it
were the only thing there. Button labels are cut at `BUTTON_LABEL_MAX` (20) and cut
back to a WORD boundary: a hard cut produced `Esplanade Co`, which reads as a
rendering fault rather than an abbreviation. ntfy itself imposes no limit — 43
characters were accepted — so the cap is only about phone width.

Two captures that need you rather than a decision carry ❗ and no buttons:
**Missing Event** (the screenshot described nothing schedulable) and a needs-a-human
capture, which leads with the event's own title where the reply carried one and falls
back to **Needs A Human**. Nothing here sends a `Priority` header at all — ranking a
proposal against the note beside it was noise, and everything-loud is how a topic
ends up muted. needs-a-human used to be the exception, sent `high` because it fired
exactly once with no buttons and nothing waiting anywhere, so missing it lost the
capture outright. That was compensation for a design fault rather than urgency: the
record is now PARKED like every other unresolved thing, nudged at 24h and archived at
7 days, which removed the exception instead of amplifying it.

Three glyphs cover the whole topic (owner call, 2026-08-01; the alarms used to wear
⚠️📷): 📆 (`Tags: calendar`) on everything genuinely calendar-shaped — proposals,
Already Passed, the sweep's Still Waiting; ❗ (`Tags: exclamation`) on everything
that means an error or missing information — the no-buttons degraded proposal,
Missing Event, needs-a-human (both titles), and the four infrastructure alarms
(`Afterimage Stuck`, `Afterimage Failed`, `Afterimage Gave Up`, `Stray Files In
Afterimage Spool`); and ⚠️ (`Tags: warning`) on the one message that is neither, the
**paused summary** raised when the API cannot be reached or the account cannot pay.
That message is shared word for word with the other intake pipeline, glyph included,
so one outage reads identically wherever it lands. Custom
icons are possible — an `Icon:` header pointing at a PNG/JPEG URL, fetched by the
*phone* rather than the server and cached about a day — but are deliberately not used
here: a tag emoji needs nothing hosted and nothing fetched.

**Bodies are rendered as Markdown** (`Markdown: yes`), which is what makes the aside
italic. That renders in the ntfy **web** client; the Android app shows the raw
markers, so if the phone ever becomes the primary surface, drop the header rather
than un-escaping the bodies. Turning a renderer on changed what model output *means*:
`md_escape()` neutralises links, emphasis, code spans, headings and blockquotes on
every model-derived string reaching a body, because `[tap here](https://evil.example)`
lifted off a screenshot into a venue or a reason would otherwise render as a real
link inside a notification you already trust.

## Data and privacy

Every capture is retained indefinitely under `data/archive/<id>/` as a labelled
example — screenshot, the model's proposal, and your verdict side by side.
`context.json` is what makes it comparable later: without the prompt that produced
a proposal, a difference between two records could be the prompt, the model or the
screenshot, with no way to tell which.

```
archive/<id>/
  screenshot.png    what you captured (.jpg for Android uploads)
  context.json      model, effort, the full prompt + its hash, capture time, tokens
  capture.json      the WHOLE model reply, so a capped or partial capture stays
                    diagnosable after the fan-out has split it up
  proposal.json     the one event this record is about
  event.ics         what would have been written
  decision.json     add | add_alt | add_duplicate | discard | ignored |
                    needs_human | not_event | failed
                    (`undone` appears on older records only — the undo path was
                     removed 2026-08-09)
```

There is **no ledger and no recording mode** (both retired 2026-08-01, with the
documents convergence). State is locations only — `incoming → pending → archive` —
and each record carries its own `decision.json`, so any ledger-style question is a
jq over the archive:

```bash
jq -s 'group_by(.outcome)|map({outcome:.[0].outcome,n:length})' data/archive/*/decision.json
```

Records that predate the retirement keep their `mode` files and fields; nothing
reads them. A button tapped to exercise the plumbing is **not** a label — correct
that record's `outcome` (or leave a `note` saying it was a test) so the archive
measures the model rather than your workarounds.

**Discard does not delete** — every screenshot you tap away is retained, including
ones captured by accident (the sweep prunes the image later; see below).

**A tap withdraws its own notification** (2026-08-09), so Add and Discard are each
terminal: the container sends ntfy a `DELETE` for the record's sequence id the
moment it archives. A failed CalDAV PUT does NOT archive, so that notification
stays — which is what makes its disappearance mean the event actually landed. No
button carries `clear=true` any more; it dismissed on the tap and would have hidden
exactly that failure. One consequence: **the undo is gone** — Add takes the Discard
button away with it, so nothing could reach `undoAdd()` from a phone, and the code
was removed rather than left as an unreachable branch. A drop on a record that is no
longer pending now answers **409**, not `{ok:true}`: reporting success while doing
nothing is the 2026-07-27 bug, and it must not come back by accident. The undo for a
wrong Add is deleting the event in your calendar app.

**Screenshots are pruned, the rest is not.** After `PRUNE_IMAGE_AFTER_DAYS` (7) the
sweep deletes the IMAGE from an archived record — whatever its outcome — and leaves
a `screenshot.pruned` marker; the proposal, the `.ics`, the context and the verdict
stay, because they are text-sized and carry the analysis value. A week is long
enough to look again at a case the model got wrong, and the screenshot is the
sensitive half of the record. Set the interval to 0 to disable pruning.

The archive's text half still answers analysis questions: `context.json` records
the prompt that produced each proposal — without it, a difference between two
records could be the prompt, the model or the screenshot, with no way to tell.
The prompt is hashed as a TEMPLATE, with the capture time substituted out, so
records group by prompt version rather than every capture hashing differently.

That replay is not hypothetical: on 2026-07-28 all 36 archived screenshots were run
through `claude-sonnet-5` and `claude-opus-5` under one prompt to decide whether to
switch. Both arms had to be re-run fresh — the archived replies spanned fourteen
prompt versions, so diffing a new model against them would have measured the prompt
rewrites instead. Result in the Notes below.

**Screenshots stay on this box.** `afterimage/` is deliberately absent from restic's
path allowlist, so nothing here is copied to cloud storage — a screenshot can
contain anything that was on screen. ZFS + sanoid still cover disk failure and
rollback. Do not add `afterimage/` to restic without revisiting that decision.

## Cost

**3.5¢ per capture**, measured over 36 real captures on 2026-07-28: 151,731 input
and 20,693 output tokens for the set, on `claude-opus-5` with adaptive thinking at
medium effort. This bills the Anthropic API account, not a Claude subscription.
There is no rate limit or spend cap. The upload endpoint is reachable from the
tailnet **and from any container on the compose network** — it is not public, but
"only you can call it" is not quite true. Uploads are the only thing that spends
money, so an unexpected bill is the signal to look here first.

## Notes

- **Model choice was measured, not assumed.** A 2026-07-24 bake-off over 8
  configurations found `opus-5` + vision scored 7/7 on a hard golden set, versus
  4/7 for the same model on OCR text and 0/7 for local 4B vision. Modality, not
  model size, was the lever — hence no tesseract anywhere in this pipeline.
- **`claude-sonnet-5` was evaluated and rejected (2026-07-28) — do not re-raise
  without new information.** All 36 archived screenshots were replayed through both
  models under one prompt. 34 of 36 produced an identical calendar entry, but on a
  real gig poster reading "Friday 4 December" sonnet answered **2031** — it matched
  Thursday years (2025, 2031) and narrated that reasoning confidently in the event
  description — where opus answered 2026, the actual Friday. That is the year
  hierarchy's determining step. Sonnet also returned `needs_human` with an empty
  `events` array, a shape that exposed a real routing bug here (now fixed). Savings
  would have been **~1.2¢ per capture**: input tokens were identical, but sonnet
  produced 29% more output, cancelling most of the cheaper rate. Roughly 78¢ across
  every capture taken to date.
- **The triage must always drain `incoming/`.** `PathExistsGlob` re-fires while a
  file remains, so a leftover PNG would hot-loop systemd and bill an API call per
  spin. Every branch in `afterimage.triage.sh` moves or archives its file.
- **The callbacks require `X-Afterimage: 1`.** `POST /afterimage/<id>/add` and `/drop`
  return 403 without it. ntfy sets it natively (`headers.X-Afterimage=1` in the action),
  so taps are unaffected — but a hand-rolled `curl` needs `-H 'X-Afterimage: 1'`. It is
  not authentication; the custom header forces a CORS preflight, and the server
  answers that preflight for exactly one origin (`NTFY_ORIGIN`, the ntfy web UI —
  see [OPERATIONS.md](OPERATIONS.md)). Every other page is refused, which stops a web page open on a
  tailnet device from firing a callback it scraped off the (unauthenticated) ntfy
  topic. Refusing *every* preflight, which shipped briefly on 2026-07-27, breaks the
  web client instead.
- **Uploads land via atomic rename** (`.part-<id>` → `<id>.png`) so the `.path`
  unit can never fire on a half-written screenshot.

## Scope

A component of [catallenya](https://github.com/carrein/catallenya), published for
reading rather than installation. It is not standalone: it expects a specific host
filesystem layout, a container definition that lives in the parent repository's
compose file, a reverse proxy in front of it, and a systemd policy contract it
inherits rather than declares.

It is also **one of two pipelines built to the same design** — the other is
[pigeonhole](https://github.com/MiraiConcepts/pigeonhole), which files documents
instead of events. Drop zone, one AI call, buttons whose meaning is a target state,
a hardened writer, a morning-side sweep: the shared shape and the reasoning behind
each rule are in the parent repo's `docs/intake-playbook.md`.

Installing the client and rebuilding the server side are in
[OPERATIONS.md](OPERATIONS.md).
