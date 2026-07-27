# capture

Screenshot → AI triage → proposed calendar event, confirmed with one tap.

Press a hotkey, drag a box around a message thread or an invite. ~15 seconds later
an ntfy notification proposes the event; tap **Add** and it's in Radicale. Nothing
is ever written to your calendar without that tap.

## How it works

```
laptop hotkey ──curl──▶ Caddy ──▶ capture container ──┐
                                                       │  writes incoming/<id>.png
                                    capture/data/  ◀───┘
                                         │
              capture.triage.path fires ─┤
                                         ▼
                            capture.triage.service (host)
                              opus-5 vision → JSON → .ics
                                         │
                                         ├──▶ ntfy: [Add] [Discard]
                                         │
                        you tap ─────────┘
                                         ▼
                        capture container ──PUT──▶ Radicale
```

Two halves, sharing only the `capture/data/` spool:

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
record is exactly the one-event shape the container, the sweep, the archive and the
ledger already handle, which is why there is no indexed callback. `MAX_EVENTS_PER_CAPTURE`
bounds the ping storm; `events_seen` records the true page total, and a truncated
list says so in the body.

**What the model decides, and what code decides.** The model reads the image and
lists what it sees, past events included. Whether an event is *over* is computed by
`event_is_past()` from its date, start time and the capture moment in `EVENT_TZ` —
never asked of the model. Upcoming events each get a notification; everything already
finished is collapsed into a single "Already passed" note listing the titles. A page
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
| `scripts/capture.triage.sh` | opus-5 vision call, `.ics` render, ntfy proposal |
| `scripts/capture.sweep.sh` | hourly: re-notify stale proposals, re-queue after a transient API failure, archive ignored ones, prune old screenshots |
| `scripts/capture.lib.sh` | shared config + the deterministic guards: `validate_proposal`, `event_is_past`, `api_post` retry, `button_label`, `fork_record` |
| `tests/run.sh` | offline regression suite — every case is a bug that shipped |
| `scripts/render_ics.py` | deterministic RFC 5545 writer (fold/escape, timed events converted to UTC — no VTIMEZONE by design) |
| `systemd/` | `.path` trigger + `.service` + hourly sweep `.timer` |
| `client/capture.sh` | **laptop-side** hotkey script (see below) |

## The notification

The proposal is laid out as a calendar entry, not a sentence — the tap is the only
gate before anything is written, so it has to be checkable at a glance:

```
📅  Property viewing
    Sunday, 26 July 2026
    13:00 - 14:00
    5 Everton Park
    General

    [ Add ]   [ Discard ]
```

Title is the event name; the body is one fact per line in 24-hour time, and empty
fields are simply absent — an all-day event shows no time line, one with no venue
shows no location line. When the model saw a second plausible reading the buttons
become `[13:00] [15:00] [Discard]` and each writes that variant directly; both `.ics`
files are pre-rendered, so either tap is a file read plus one PUT.

**ntfy caps action buttons at 3**, which is why at most one alternative is ever
offered — a rarer 3-way ambiguity shows the best two readings and drops the rest.

The 📅 is an emoji from the `Tags:` header. Custom icons are possible — an `Icon:`
header pointing at a PNG/JPEG URL, fetched by the *phone* rather than the server and
cached about a day — but are deliberately not used here: a tag emoji needs nothing
hosted and nothing fetched.

## Laptop setup

The client is the one piece that lives outside the server.

**1. Install a region-select screenshot tool**

| Platform | Install |
|---|---|
| Wayland (sway, Hyprland, GNOME) | `sudo apt install grim slurp` |
| X11 | `sudo apt install maim` (or `scrot`) |
| macOS | built in (`screencapture`) |
| KDE | `spectacle` |

**2. Copy the client over**

```bash
scp catallenya:/zpool/catallenya/capture/client/capture.sh ~/.local/bin/capture
chmod +x ~/.local/bin/capture
```

**3. Bind a hotkey**

- **GNOME** — Settings → Keyboard → Custom Shortcuts → `~/.local/bin/capture`
- **sway/Hyprland** — `bindsym $mod+Shift+c exec ~/.local/bin/capture`
- **i3** — same as sway
- **macOS** — Automator "Quick Action" running the script, then assign a shortcut
  in System Settings → Keyboard Shortcuts → Services

**4. Subscribe to the notifications**

Open the ntfy app and subscribe to the **`capture`** topic on the tailnet server.
Without this the pipeline works but you never see the proposals.

The client needs no credentials — it only reaches a tailnet-only URL, and the
Add/Discard callbacks are gated by an unguessable per-capture id.

## Server setup

Done on this box on 2026-07-25 — the container is running behind Caddy, the units are
installed, and captures are flowing. Kept here for a rebuild.

The API key is the one prerequisite. It is read by systemd as root and injected
into the triage process, so it never sits in a file the `carrein` user can read:

```bash
sudoedit /etc/capture.env      # ANTHROPIC_API_KEY=sk-ant-...
sudo chmod 600 /etc/capture.env
```

Then:

The container also needs the Radicale credential as a docker secret — the same
`base64(carrein:<app pw>)` Caddy injects for mitsume. It is a file, not an env var,
because `docker inspect` and `/proc/1/environ` both expose environment, and that
credential is good for read, write and delete across the whole `/carrein/` tree:

```bash
grep -m1 '^MITSUME_DAV_B64=' .env | cut -d= -f2- > capture/dav-secret
chmod 600 capture/dav-secret
```

Then:

```bash
docker compose up -d --build capture
docker compose up -d --force-recreate caddy   # new port needs a recreate, not restart
sudo bash systemd/install.sh                  # symlinks + enables the .path and .timer
```

`NTFY_ORIGIN` is set in compose from the tailnet vars. It is the ONE browser origin
allowed to satisfy the `X-Capture` preflight: the ntfy web UI taps buttons with
browser `fetch()`, so CORS applies to it, and refusing every preflight — which
shipped briefly on 2026-07-27 — breaks the web client with an opaque
`TypeError: NetworkError`. The phone app does native HTTP and never sees this. Any
other page is still refused, because browsers set `Origin` and a page cannot forge it.

Last step is subscribing a device to the `capture` topic (below). Everything else can
be green and you will still never see a proposal without it.

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
  mode              off | test | prod, as of when the capture was taken
  capture.json      the WHOLE model reply, so a capped or partial capture stays
                    diagnosable after the fan-out has split it up
  mode              off | test | prod, as of when the capture was taken
  proposal.json     the one event this record is about
  event.ics         what would have been written
  decision.json     add | add_alt | add_duplicate | undone | discard | ignored |
                    needs_human | not_event | failed
```

`data/decisions.jsonl` is the same verdicts as an append-only ledger, so accept
rate over time is a one-liner:

```bash
jq -s 'group_by(.outcome)|map({outcome:.[0].outcome,n:length})' data/decisions.jsonl 2>/dev/null || echo 'no decisions recorded yet'
```

A button tapped to exercise the plumbing is **not** a label — correct that record's
`outcome` (or leave a `note` saying it was a test) before it gets counted, or the
ledger measures your workarounds instead of the model.

**Recording has three modes**, set by one word in `capture/data/recording-mode`
and read at use time, so changing it needs no restart:

| mode | resolved captures | verdict goes to |
|---|---|---|
| `off` | deleted | nowhere |
| `test` | kept in `archive/` | `decisions.test.jsonl` |
| `prod` | kept in `archive/` | `decisions.jsonl` |

```bash
printf 'test\n' > /zpool/catallenya/capture/data/recording-mode
cat /zpool/catallenya/capture/data/recording-mode   # what am I in right now
```

Test verdicts are kept rather than discarded because while a prompt is being
iterated on they are the signal — "did that change help" is answered from them.
A separate ledger means there is no filter to get wrong later and the production
accept rate cannot be contaminated.

The mode is stamped into each record when the capture is claimed, and that stamp
decides what happens when you tap — so a test capture tapped after a switch to
`prod` is still counted as a test. A missing file means `prod`; an unreadable or
misspelt one falls back to `test`, whose failure modes are the only reversible
ones (you keep more than you meant, and the metric does not move). The pre-2026-07-27
`.recording-disabled` flag still works as a synonym for `off`.

Note that outside `off`, **Discard no longer deletes** — every screenshot you tap
away is retained, including ones captured by accident. Discard on a capture that was
already ADDED is different again: it undoes it, deleting the event from Radicale and
recording the outcome as `undone`.

**Screenshots are pruned, the rest is not.** After `PRUNE_IMAGE_AFTER_DAYS` the sweep
deletes the IMAGE from an archived record and leaves a `screenshot.pruned` marker;
the proposal, the `.ics`, the context and the verdict stay, because they are
text-sized and carry the analysis value. Records the model got *wrong*
(`PRUNE_KEEP_IMAGE_OUTCOMES`) keep their image indefinitely — those are the ones
worth looking at again. Set the interval to 0 to disable pruning.

The archive is an **eval** set, not training data: these models cannot be fine-tuned
here. Its uses are replaying a new model against recorded verdicts, iterating the
prompt against real failures, and few-shot examples. `context.json` is what makes
that possible — without the prompt that produced a proposal, a difference between
two records could be the prompt, the model or the screenshot, with no way to tell.
The prompt is hashed as a TEMPLATE, with the capture time substituted out, so
records group by prompt version rather than every capture hashing differently.
```

**It is currently OFF** (nothing is being kept) while the pipeline is being exercised.
Recording is the intended steady state; remove the flag once you are done testing.
While it is set, the accept-rate `jq` in `CLAUDE.md` returns nothing — that is expected,
not a fault.

**Screenshots stay on this box.** `capture/` is deliberately absent from restic's
path allowlist, so nothing here is copied to cloud storage — a screenshot can
contain anything that was on screen. ZFS + sanoid still cover disk failure and
rollback. Do not add `capture/` to restic without revisiting that decision.

## Cost

Roughly **3–10¢ per capture** (`claude-opus-5`, ~4.8k image tokens in, adaptive
thinking at medium effort). This bills the Anthropic API account, not a Claude
subscription. There is no rate limit or spend cap. The upload endpoint is reachable
from the tailnet **and from any container on the compose network** — it is not
public, but "only you can call it" is not quite true. Uploads are the only thing
that spends money, so an unexpected bill is the signal to look here first.

## Notes

- **Model choice was measured, not assumed.** A 2026-07-24 bake-off over 8
  configurations found `opus-5` + vision scored 7/7 on a hard golden set, versus
  4/7 for the same model on OCR text and 0/7 for local 4B vision. Modality, not
  model size, was the lever — hence no tesseract anywhere in this pipeline.
- **The triage must always drain `incoming/`.** `PathExistsGlob` re-fires while a
  file remains, so a leftover PNG would hot-loop systemd and bill an API call per
  spin. Every branch in `capture.triage.sh` moves or archives its file.
- **The callbacks require `X-Capture: 1`.** `POST /capture/<id>/add` and `/drop`
  return 403 without it. ntfy sets it natively (`headers.X-Capture=1` in the action),
  so taps are unaffected — but a hand-rolled `curl` needs `-H 'X-Capture: 1'`. It is
  not authentication; it forces a CORS preflight this server never answers, which
  stops a web page open on a tailnet device from firing a callback it scraped off the
  (unauthenticated) ntfy topic.
- **Uploads land via atomic rename** (`.part-<id>` → `<id>.png`) so the `.path`
  unit can never fire on a half-written screenshot.
