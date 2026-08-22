# The message contract

Every notification this box sends is built here. **This document is the source.** It is
written to one test: *everything is lost, someone has this file — can they rebuild the
notification system correctly?* Code comments elaborate; they never contradict.

The mechanism is `ntfy/kinds.sh` (constructors), `ntfy/ntfy.lib.sh` (transport) and
`systemd/contract.sh` (the gate that refuses anything else).

**Why it exists.** 32 emission points across 12 files grew **six incompatible title
grammars** in about a year — `Staged: 3 Documents`, `Liquidroom: stems ready`,
`Afterimage Gave Up`, `Immich rotation bake failed`, `Disk Space Alert`,
`Backup Failure`. Each was written by someone following whatever file they had open.
The transport was unified on 2026-08-10, but that standardised the **wire**, never the
**message**.

---

## 1. The class model

Four classes. Which one a message belongs to decides whether its wording may differ
between pipelines.

| Class | Source | Vocabulary | Verbs |
|---|---|---|---|
| **Model** | `ai/scripts/ai.lib.sh` | **must be identical** | `Model Failed` `Model Paused` |
| **Policy** | the same rule implemented twice | shared by choice | `Abandoned` |
| **Situation** | different code, same predicament | shared by choice | `Flagged` `Stuck` `Refused` `Skipped` `Stranded` |
| **Service** | one pipeline's own machinery | independent | everything else |

**Why the model class is mandatory and not a preference.** Both intake pipelines call
`ask()` in `ai/scripts/ai.lib.sh`, and both triages have byte-identical branch structure
around it:

```bash
ask_rc=0
prop="$(ask …)" || ask_rc=$?
if   (( ask_rc == 2 || ask_rc == 3 )); then   # parked  — retry/paused
elif (( ask_rc != 0 )); then                  # terminal — fatal
```

An error out of that layer is **one fact arriving on several topics**. It used to read as
`Capture Failed — check the API key` on one and `Blocked: 1 Document — The model call
failed` on the other, only one of which pointed anywhere near the problem. `paused_title()`
already encoded this argument for one of the three outcomes; the other two were never
brought along.

`api_class()` emits four verdicts:

| rc | verdict | Triggers | Title |
|---|---|---|---|
| 0 | `ok` | 200 | — |
| 1 | `fatal` | 400 · 401 · 403 `permission_error` · 404 · model refusal · truncated reply · unparseable JSON | `Model Failed: 1 X` |
| 2 | `retry` exhausted | 429 · 5xx · `000` after `API_MAX_ATTEMPTS` | `Model Paused: N X [Unreachable]` |
| 3 | `paused` | 402 · 403 `billing_error` · 400 whose message names the credit balance | `Model Paused: N X [Unpaid]` |

`Model ` is a **namespace prefix**, the same move as `Still ` for nudges. It keeps the
shared meaning unambiguous and leaves `Failed` free for the state slot elsewhere
(`Backup: Failed`, `Rotation Bake: Failed`).

**`Abandoned` is unprefixed on purpose.** The 7-day give-up is *this repo's* timer
deciding to stop retrying — the cause is model-class, the decision is the pipeline's. The
missing prefix is what makes that difference readable on a lock screen.

---

## 2. The vocabulary — 22 verbs

| Verb | Class | Means |
|---|---|---|
| `Model Failed` | model | the API rejected the request; retrying cannot help |
| `Model Paused` | model | parked — unreachable, or out of credits |
| `Abandoned` | policy | the 7-day clock ran out on a parked item |
| `Flagged` | situation | the model answered, but a human should look |
| `Stuck` | situation | a file cannot be moved out of a drop zone; the trigger will re-fire |
| `Refused` | situation | a safety check refused something |
| `Skipped` | situation | nothing to do; working as intended |
| `Stranded` | situation | a file the pipeline cannot act on at all |
| `Passed` | afterimage | the event is already in the past |
| `Unlinked` | afterimage | staged, but no callback URL could be built |
| `Staged` | pigeonhole | proposed, awaiting a tap |
| `Blocked` | pigeonhole | the document itself cannot be filed |
| `Binned` | pigeonhole | moved to `bin/` after 7 days |
| `Finished` | liquidroom | stems published |
| `Downloaded` | liquidroom | interim ping; downloads complete |
| `Dropped` | liquidroom | download failed |
| `Halted` | liquidroom | separation failed |
| `Emptied` | liquidroom | the separator produced nothing |
| `Raced` | liquidroom | the destination appeared mid-run |
| `Unpublished` | liquidroom | the atomic rename failed |
| `Baked` | immich | rotations written into originals |
| `Still ` | prefix | a nudge |

**Every one is a past participle.** 21 end in `-ed`; `Stuck` is the single irregular and
is listed in `NTFY_IRREGULAR_VERBS`. The gate checks this (§9).

---

## 3. The constructors

All five live in `ntfy/kinds.sh`. Nothing else may build a title.

```bash
title_count <Verb> <n> <Noun> [name] [mark]   a REPORT — what happened, to how many
title_state <Subject> <State> [mark]          a FAULT or RECEIPT — what is, with what
title_quote <name> [mark]                     a QUOTATION — the world's own words

title_mark <text>        -> [text]      title_pos <n> <of>  -> [2/4]  (silent at of<=1)
title_age  <hours>       -> [6h][1d][3w]
```

Worked calls:

```bash
title_count Staged 3 Document                       # Staged: 3 Documents
title_count Blocked 1 Document                      # Blocked: 1 Document
title_count "Still Staged" 3 Document "" "[1d]"     # Still Staged: 3 Documents [1d]
title_count Flagged 1 Event "Kene"                  # Flagged: Kene
title_state zpool "78% Full"                        # zpool: 78% Full
title_state Backup Succeeded                        # Backup: Succeeded
title_quote "Kene" "$(title_pos 2 4)"               # Kene [2/4]
title_quote "Kene" "$(title_age 31)"                # Kene [1d]
```

**Sanitation is not here.** `notify()` already runs `hdr_safe` on its first argument, so a
name — a hand-typed track filename, a model-written event title — is handled at the same
boundary as every other title. Two copies of a CR/LF strip is how the two drift.

### Bodies — the language

Titles could have a closed vocabulary. Prose cannot, so what a body gets instead is a
**style system**: decisions that constrain how any future sentence is written. Settled
2026-08-21, and the point of settling it in one pass is that this text is generated
once and then frozen — a body written next year should be indistinguishable from one
written today.

#### Four shapes, and nothing else

```
1. IMG_1234.jpg                    ITEM      a thing — file, document, track, job
    Rotated: 90°                   DETAIL    what happened to it, indented

▪ 400G free                        FACT      a metric or a state about the run

Only *.png is triaged.             PROSE     one explanation, in sentences

_… and 3 more._                    ASIDE     a truncation count, and nothing else
```

**Order: items, blank, facts, blank, prose.** The aside sits with whatever it truncates.

#### When to use which

**Terse lines for a list of things** — files, actions, metrics. **A sentence when there
is one thing to explain.** Never drop context to shorten a line, and never chop a single
explanation into bullets: `Could not move it out of incoming/. The disk may be full.`
reads better than three fragments, and three fragments is what the rule exists to
prevent.

#### The renderers

**No body is built by hand.** Four functions in `ntfy/kinds.sh` produce the four shapes,
and every one of them escapes its input — which is what let `NTFY_MARKDOWN` go. Five
publishers had turned rendering off because their bodies carry raw filenames, and a
camera name like `photo_2026_08_01.jpg` comes out with its middle italicised, or worse, a
filename arriving over Syncthing could hide a live `[tap here](https://evil)` inside a
notification you already trust. Escaping in one place is what makes rendering safe
everywhere.

**Markdown is now unconditional.** With all five opt-outs converted, `NTFY_MARKDOWN` was
a variable nothing set — a slot waiting for someone to put `no` in it, exactly what
priority was. It was removed on 2026-08-21 and the header is always sent. This matters
beyond tidiness: `md_escape` exists to guard a *rendered* body, so a consumer that could
switch rendering off could also switch off the reason the escaping is there.

```bash
body_list [--all] <item>...   items, numbered, capped at five; "name<TAB>detail"
body_fact <line>...           the ▪ lines
body_aside <text>             the italic truncation count, and nothing else
body_join <section>...        the blank lines between sections, empties dropped
```

`body_join` exists because the order rule is a rule and not a habit: `$( )` strips
trailing newlines, so a section boundary needs two literal newlines and looks like a typo
with one. That is the kind of thing that is right the first time and wrong the third.

```bash
BODY="$(body_join \
    "$(body_list "${ERRORS[@]}")" \
    "$(body_fact "24/26 containers running" "15/15 timers active")")"
```

#### The rules

| | Rule | Example |
|---|---|---|
| 1 | Items are numbered `1\.`, capped at five | `1. scan_20260820.pdf` |
| 2 | A detail is `Label: value`, **labelled only when the value alone is ambiguous** | `Rotated: 90°` but a bare `09_receipts-…/Acme.pdf` |
| 3 | **No full stop on any line but prose** — a stop after a path reads as part of the filename, and one rule beats remembering which line you are on | `Reason: PDF is locked or unreadable` |
| 4 | A fact is **self-describing and carries no stub label** | `▪ 400G free`, never `▪ Free: 400G` |
| 5 | A fact is a **complete statement**; where prose reads badly use a full descriptive phrase, never a stub | `▪ Estimated time left: 70m`, never `▪ about 70m` |
| 6 | Facts are **capitalised** | `▪ Out of credits` · `▪ Retrying daily` |
| 7 | Metrics get their own line, never a comma-joined run | `▪ 15/15 timers active` |
| 8 | Prose is capitalised sentences **with** full stops, as many as it needs | `Could not reach the API for 7d. Take it again once things are healthy.` |
| 9 | A body **may instruct** where there is a next step | `Take it again once things are healthy.` |
| 10 | **No rhetorical questions** — state it as a possibility | `The disk may be full.` not `Disk full?` |
| 11 | **No em-dashes**, anywhere in a body | the indent does that work |
| 12 | Units are **compact** | `402d` · `2d 4h` · `70m` · `1.3T of 1.7T` |
| 13 | Paths are **full** | `09_receipts-and-purchases/2026-08-20 Acme Receipt.pdf` |
| 14 | **Only a truncation count is italic** | `_… and 3 more._` |
| 15 | Prose uses natural language, **pronoun where the title already named it** | `Could not move it out of incoming/.` |
| 16 | No ceiling on length | the list cap bounds the common case |

#### Why facts carry no label and details do

It looks arbitrary and is not. **A detail hangs off the item above it**, so a label says
*which aspect of that item* you are being told — `Rotated: 90°` under a filename. **A fact
stands alone**, so it has no context to lean on and must describe itself.

The failure this invites is dropping context to keep the line short. `▪ about 70m` obeys
the letter of "no label" and means nothing. Where plain prose reads badly, the answer is a
**full descriptive phrase**, never a stub:

| stub label | terse prose | correct |
|---|---|---|
| `▪ Estimated: 70m` | `▪ about 70m` | `▪ Estimated time left: 70m` |
| `▪ Not found: 1` | `▪ 1 not found` | `▪ 1 track not found` |
| `▪ Free: 400G` | — | `▪ 400G free` |

#### Truncation keeps three meanings

They are different facts and read differently:

```
_… and 3 more._              the list was cut at five
_3 more still queued._       work is waiting for the next run
_3 more events not sent._    data was dropped and is gone
```

#### The `▪` marker

U+25AA BLACK SMALL SQUARE. Chosen over `-`, which markdown turns into a real list — the
same trap the escaped `1\.` exists for — and over `•`, which is already what the Android
app renders a real list marker AS, so a fact would be indistinguishable from a mangled
item. **It has an emoji presentation and some Android builds may render it as a coloured
square** — accepted deliberately, and the first thing to check on the device. The safe
fallbacks are `■` U+25A0 or `•` U+2022, neither of which is emoji-capable.

#### The one text no rule can reach

**afterimage's `reason` is model-written prose and stays that way.** The plan was to
replace it with a code, the way pigeonhole returns `PDF_UNREADABLE_OR_ENCRYPTED` and
`reason_text()` turns that into a sentence — after which "no em-dashes" is a grep over
`case` arms rather than something anyone must remember.

Measured against the archive instead of assumed, and the archive says no. In 115
records the one stored `needs_human` reason reads:

> The screenshot shows an Instagram post for a bar's Cupid event ("magic at 10pm",
> free entry, 9 Bras Basah Road) and a group chat planning to walk in around 10pm, but
> no specific calendar date for the outing is shown anywhere, only a note that
> reservation slots open 1 August onwards.

No enum produces that, and `NO_RESOLVABLE_DATE` → "No date could be resolved." throws
away everything that made it actionable. **The two pipelines differ in what the reason
is ABOUT**: pigeonhole's describes a failure to read a FILE, and the ways a file can
fail to be read are finite; afterimage's describes what a SCREENSHOT SHOWED, which is
not. The enum is right in one and wrong in the other for the same reason.

So the style rules are carried in the PROMPT — full stops, no em-dashes, no rhetorical
questions, no Markdown, and be specific rather than brief. That is weaker than a gate
and is the honest place for it: nothing static can check a sentence a model has not
written yet.

#### One thing kept that looks inconsistent

**afterimage keeps record ids** — `(id 3f2a9c1b)` — because a screenshot has no name
until the model reads one out of it, and every body carrying an id is a case where that
never happened. pigeonhole has filenames and so never needs one.

The proposal body is what the no-label rule was written for: a date, a time and a venue
each announce what they are, so a label would only repeat them.

```
Kene [2/4]
▪ Thursday, 27 August 2026
▪ 19:30 - 21:00
▪ Candlenut
```

---

## 4. The kinds

Every notification is one of five things, and the kind decides **which arguments exist**.
That is the whole mechanism.

```bash
notify_proposal <title> <body> <actions> <seq-id>   both REQUIRED
notify_nudge    <title> <body> <seq-id> [actions]   retracts first; id REQUIRED
notify_resolved <title> <body> <seq-id> [actions]   retracts first; id REQUIRED
notify_fault    <title> <body> [seq-id]             never actions
notify_receipt  <title> <body>                      never actions, never a seq-id
```

`notify()` is the transport primitive underneath and is not called from outside `ntfy/`.
Its signature is `notify <title> <body> [actions] [sequence-id]` — **there is no priority
and no tag.** Priority had one legal value, so it was a slot waiting for someone to put
`high` in it. Tags were twelve glyphs of which four meant "something is wrong"; the rest
named the pipeline, which the topic already says.

**The kinds produce no visible difference.** With tags gone, every message renders as
title plus body regardless. Their value is entirely structural — a receipt has no
argument to put a button in, a proposal cannot omit the sequence-id that makes it
withdrawable — and it is what lets the gate refuse a bare `notify()`.

### The withdrawal rule

> **A notification with buttons may be withdrawn. A notification without buttons is
> never withdrawn by the system.**

An actionable message is withdrawn by the tap that resolves it, or by afterimage's
archive backstop once its buttons have started answering 404 — a control that lies is
worse than no control. Everything else stays until you swipe it.

**The reasoning matters more than the rule.** An absent notification is ambiguous: you
cannot tell "the problem fixed itself" from "I mis-swiped it" from "it was never sent".
A stale one is unambiguous — it says something happened, so you go and look.

| Kind | Buttons | Withdrawn? |
|---|---|---|
| `proposal` `nudge` `resolved` | yes | by the tap, or when the buttons go dead |
| `fault` `receipt` `paused` | no | **never** |

**There are no exceptions to that second row.** The last one closed on 2026-08-20:
afterimage's `Flagged: Kene` had no buttons yet was withdrawn at seven days by the
archive backstop, silently, because its record was gone. It now carries a Discard
button — see nuance 6b — so its withdrawal is a tap's or a dead control's, which the
rule already allows.

**A fault's sequence-id means "this can recur".** A job that runs on a schedule and can
report the same finding twice passes a stable literal, so the second run replaces the
first instead of stacking: `host/disk.sh` runs hourly, and a pool over threshold across a
weekend used to produce forty-five notifications. It still does **not** self-clear — see
the rule. A one-shot fault about a single item passes no id, because nothing later will
replace it.

Stable fault ids today: `disk-full`, `watchdog-findings`, `changedetection-health`,
`immich-bake-failed`, `boot-failed`, `afterimage-stuck`, `afterimage-stranded`,
`pigeonhole-stuck`, `pigeonhole-paused`.

**This reverses a deliberate fix, and that is intentional.** On 2026-08-19
`paused_sync()` was made to retract unconditionally so the run that *ended* an outage
cleared the summary. Under the rule above that stale summary is correct — it has no
buttons — so `paused_sync()` now retracts only when it is about to publish a
replacement. Do not restore the old behaviour without revisiting the rule.

---

## 5. The rules

**Grammar**

| # | Rule |
|---|---|
| 1 | Never repeat what the topic already says |
| 2 | A model-written event title is a **quotation**, built by `title_quote` |
| 3 | **Past participle only, zero exceptions**, in the verb slot |
| 4 | `Still ` is the nudge prefix. A nudge of a *quotation* takes no verb — just the age |
| 5 | Faults use `Subject: State` |
| 6 | A name may replace the count in the object slot |
| 7 | `Model ` is the namespace prefix for the shared AI layer's two verbs |

**Style**

| # | Rule | Example |
|---|---|---|
| 8 | Keep the digit at 1 | `Blocked: 1 Document` |
| 9 | Title Case nouns | `3 Documents` |
| 10 | Identifiers keep their real case; words get Title Case | `zpool: 78% Full` |
| 11 | The state slot carries a number where one naturally fits, otherwise a bare participle or phrase. **Strong preference for the number** | `zpool: 78% Full` · `Backup: Succeeded` |
| 12 | The digest noun is `Findings` | `Watches: 3 Findings` |
| 13 | Every qualifier rides in square brackets | `[2/4]` `[1d]` `[Unpaid]` `[restic]` |
| 14 | Cap ~40 chars. **The verb is never what truncates** | `Finished: Godspeed You! Black Emperor -…` |
| 15 | The ellipsis is `…`, one codepoint | |

**Behaviour**

| # | Rule |
|---|---|
| 16 | Silence is the healthy state — with the deliberate exceptions in §6 |
| 17 | The imperative lives on the **button**; the title only ever reports |
| 18 | A notification with buttons may be withdrawn; one without buttons never is — see §4 |

---

## 6. The nuances

Fifteen deliberate exceptions. Each is a decision, not an oversight; each names the
service that exemplifies it.

| # | Nuance | Where | Why |
|---|---|---|---|
| 1 | `Model ` prefix exists to free `Failed` | all | `Failed` is wanted in the state slot (`Backup: Failed`) and as a general idea. Prefixing the model class keeps its shared meaning exact without monopolising the word |
| 2 | `Abandoned` is **not** prefixed | afterimage, pigeonhole | the 7-day give-up is our timer, not the API's fault. The missing prefix carries that |
| 3 | Rule 11 is a preference, not a rule | immich, restic | forcing a number produced `Backup: 1 Success`, counting something always exactly one, and `Changedetection: 0 Containers Running` for a container that is simply down |
| 4 | `Flagged` `Stuck` `Refused` `Skipped` `Stranded` are shared **by choice** | several | they are situation-class, so sharing is permitted, not required. The situations genuinely match — `Flagged` means *model answered, human should look* in both pipelines |
| 5 | The gate **is** the layering | `systemd/contract.sh` | unlike systemd there is no merge engine. Nothing at runtime stops a hand-built string. See §10 |
| 6 | A proposal's nudge takes **no verb** | afterimage `sweep:184` | its original title is a quotation with no verb to reuse. afterimage therefore has two nudge shapes on purpose |
| 6b | `Flagged: Kene` carries a **Discard** button | afterimage `triage:431` | `Add` is impossible without a parsed date, so this was a button-less fault — and therefore the one message the withdrawal rule said to keep while the archive backstop removed it at seven days anyway, silently. Discard is only an archive, which is what the day-7 expiry does regardless, so giving it that one button settles the contradiction in the rule's favour rather than against it |
| 7 | Noun follows the pipeline **stage** | afterimage | `Screenshot` until the model produces events, `Event` after. `Passed: 3 Screenshots` would be wrong — three events came from one screenshot |
| 8 | Filenames stay in the **body**, not the title | pigeonhole | `title_count` accepts a name; pigeonhole deliberately passes none, because a batch of three wants three names listed, not one promoted |
| 9 | One notification **per verb**, not per run | liquidroom | a run where two tracks succeeded and one failed cannot honestly be titled `Finished` |
| 10 | Name the watch only at exactly one | changedetection | two or more and the title becomes a list; `Watches: 3 Findings` is the honest summary |
| 11 | Three faults are **digests**, so their state is caller-built text | disk, changedetection, watchdog | disk covers root *and* zpool; changedetection covers N problems of mixed types; the watchdog covers N mixed findings. The gate checks the shape, not the content |
| 12 | `system-ntfy.sh` is **exempt** from the constructors | courier | it is the alarm of last resort and must depend on as little as possible, including on another file in this repo being intact. It matches the grammar by hand; the gate checks it by pattern |
| 13 | The courier's **success branch is the canary** | restic | `restic.backup`, `restic.forget` and `restic.check@` wire `OnSuccess=`. Those pings are the only positive proof the `OnFailure=` path still reaches the phone — nothing watches the courier. **Only the daily backup ping is frequent enough to serve.** Do not delete it |
| 14 | `restic.staleness` is failure-only **by design** | restic | silence is the healthy state, and `install.sh` mechanically refuses `OnSuccess=` on `Class=monitor` |
| 15 | Boot reports failure only | host | dropped from success on 2026-08-20. Accepted consequence: after a power cut, silence no longer distinguishes *recovered* from *still dark*, and this box does not auto-restore on AC return |
| 16 | **The courier's body is the job's own words** | `system-ntfy.sh` | one body serves every job failure and all four restic successes, and `systemctl status` spent ~18 lines on boilerplate before reaching anything a person wants. Scoped to `_SYSTEMD_INVOCATION_ID` so it cannot bleed across runs — `restic.staleness` prints one line a day, so a failure used to arrive under five previous days of "within the 48h limit" — and to `_TRANSPORT=stdout` so systemd's own Starting/Finished lines cannot fill the budget, which is what happened to `disk`, a job that prints nothing when healthy |
| 17 | **`catallenya.service` cancels its inherited `OnFailure=`** | host | see the self-alerting rule below |

---

## 7. The inventory

Every title the system can emit.

### afterimage — topic `afterimage`

| When | Title |
|---|---|
| screenshot lands → model finds an event | `Kene` · `Kene [2/4]` |
| same, callback URL unbuildable | `Unlinked: 1 Event` |
| can't move out of `incoming/` — disk full | `Stuck: 1 Screenshot` |
| API rejected — rc 1 | `Model Failed: 1 Screenshot` |
| model says it isn't an event | `Skipped: 1 Screenshot` |
| date or time ambiguous | `Flagged: Kene` · **Discard** |
| events found, all in the past | `Passed: 3 Events` |
| parked 7d from first failure | `Abandoned: 1 Screenshot` |
| needs-human untouched 24h | `Still Flagged: Kene [1d]` · **Discard** |
| proposal untouched 24h | `Kene [1d]` |
| strays the `*.png` glob can't see | `Stranded: 3 Files` |
| anything parked | `Model Paused: 2 Screenshots [Unpaid]` |

### pigeonhole — topic `pigeonhole`

| When | Title |
|---|---|
| clean proposals | `Staged: 3 Documents` |
| blocked — the 11 document codes | `Blocked: 1 Document` |
| blocked — `CLASSIFY_FAILED` | `Model Failed: 1 Document` |
| flagged for review | `Flagged: 1 Document` |
| `stage_file` failed, file left at root | `Stuck: 1 Document` |
| staged 7d, no decision → `bin/` | `Binned: 1 Document` |
| blocked doc staged 24h | `Still Blocked: 1 Document [1d]` |
| flagged doc staged 24h | `Still Flagged: 1 Document [1d]` |
| clean docs still staged 24h | `Still Staged: 3 Documents [1d]` |
| parked 7d, API never answered → `bin/` | `Abandoned: 1 Document` |
| a tap's move was refused | `Refused: 2 Documents` |
| anything parked | `Model Paused: 3 Documents [Unreachable]` |

### liquidroom — topic `liquidroom`

One notification **per verb present in the run**.

| When | Title |
|---|---|
| interim, downloads complete | `Downloaded: 2 Tracks` |
| stems ready | `Finished: 1 Track` |
| download failed | `Dropped: 1 Download` |
| separation failed | `Halted: 1 Separation` |
| unsafe or symlinked result | `Refused: 1 Result` |
| empty result | `Emptied: 1 Result` |
| destination appeared mid-run | `Raced: 1 Track` |
| publish failed | `Unpublished: 1 Track` |
| already exists · duplicate request | `Skipped: 1 Track` |
| not a request | `Stranded: 1 File` |
| could not move a stray | `Stuck: 1 File` |

Bounded by `MAX_PER_RUN=3`, so at most three distinct failure verbs. Typical run 2
notifications, bad run 4, worst realistic 6. These are receipts — no sequence id, no
actions, nothing to retract — so multiplying them adds no lifecycle logic.

### immich — topic `immich`

| When | Title |
|---|---|
| rotations landed | `Baked: 3 Rotations` |
| photos it could not settle | `Flagged: 2 Rotations` — stable id `immich-flagged` |
| the run failed | `Rotation Bake: Failed` — stable id `immich-bake-failed` |

**Split on 2026-08-21.** One message used to carry both the rotations that landed and
the photos wanting a human, under a title counting only the first — so
`Baked: 2 Rotations` could sit above three lines. They are different kinds, and both
pigeonhole and liquidroom already split this way.

The failure body no longer repeats `tail -n 8` of the run: immich is a **worker**, so
the courier's message arrives beside it carrying exactly the job's last eight lines of
stdout (§ 8). This one adds the parsed counts instead, which the courier cannot know.

### restic — topic `restic`, via the courier

| Job | Cadence | Success | Failure |
|---|---|---|---|
| `restic.backup` | daily, 00:00–01:00 | `Backup: Succeeded` | `Backup: Failed` |
| `restic.forget` | weekly, Mon 06:00–07:00 | `Forget: Succeeded` | `Forget: Failed` |
| `restic.check@subset` | monthly, 1st 03:00–04:00 | `Check Data Subset: Succeeded` | `Check Data Subset: Failed` |
| `restic.check@data` | yearly, 2nd Tue of May | `Check Data: Succeeded` | `Check Data: Failed` |
| `restic.staleness` | daily 09:00 | *(none — see nuance 14)* | `Staleness: Failed` |

All carry `RandomizedDelaySec=3600`, hence the one-hour windows.

### host / disk / changedetection / watchdog

| When | Topic | Title |
|---|---|---|
| one filesystem ≥ 75% | `disk` | `zpool: 78% Full` |
| both ≥ 75% | `disk` | `Filesystems: 2 Full` |
| a container didn't start at boot | `host` | `Boot: 2 Containers Down` |
| exactly one watch wrong | `changedetection` | `Yellowpaige Shop: Broken` |
| two or more wrong | `changedetection` | `Watches: 3 Findings` |
| container down | `changedetection` | `Changedetection: Not Running` |
| any watchdog finding | `host` | `Watchdog: 3 Findings` |
| any unit's `OnFailure=` | routed | `Backup: Failed` · `[restic]` appended when rerouted |

---

## 8. Reporters and workers

Six jobs send their own notification rather than leaving it to the courier. They split
into two kinds, and the split decides whether the courier ALSO fires.

| | **Reporter** | **Worker** |
|---|---|---|
| The bad news is about | the **world** — a full pool, a broken watch, a stale job | the **job itself** — the bake crashed, files would not move, the boot did not finish |
| Did the job do its work? | yes; it looked, and found something | no |
| Exit code | `0` | non-zero |
| Courier fires | only if the alert did not land | **always** |
| Jobs | `disk` · `changedetection` · `heartbeat` | `catallenya` · `immich` · `afterimage` · `pigeonhole` |

**A reporter exits non-zero only when its own message could not be delivered.** All three
test the transport's *silence* — `curl -fsS` prints nothing on success — and fail only if
it said something. So the two layers never overlap: alert delivered, courier quiet; alert
lost, courier fires and is the only way you learn.

**A worker must exit non-zero, and that is not negotiable.** `ExecStartPost=` writes the
completion stamp only when `ExecStart` succeeded, so a failed run that exited 0 would
stamp healthy and the watchdog would report it fresh. The exit code is what keeps a
failed bake, a stuck spool or a bad boot from looking fine.

### So a worker sends two messages, and that is accepted

A failed bake produces `Rotation Bake: Failed` from the script and again from the
courier. A bad boot produces `Boot: 2 Containers Down` and `Catallenya: Failed`. Both
land seconds apart on the same topic.

**Kept deliberately (2026-08-21), after being changed and changed back.** `catallenya`
briefly cancelled its inherited `OnFailure=` to send one message instead of two. The
reasons for reverting:

- **The courier's copy is the only evidence the `OnFailure=` path still works for that
  unit.** Same argument that keeps restic's success pings: mute a job, and if its own
  notify quietly breaks, nothing reports that the path is dead.
- **It closes the one real blind spot.** A script that dies BEFORE reaching its notify —
  a missing `.env`, an OOM, a timeout kill — has sent nothing. With the courier muted,
  that is silent until the watchdog notices, up to 36h later for a daily job. With it
  firing, it is covered in seconds.
- **The events are rare.** A handful a year, on things you unambiguously want to know
  about. Not the class of problem that `host/disk.sh` had, where an hourly job stacked
  45 notifications over one weekend.

The two messages are not identical in value: the job's says *what* went wrong
(`Stuck: 2 Documents`), the courier's says *the unit failed* and carries the job's own
journal output. The first is better wording; the second is the proof the path is alive.

### The escape hatch exists and is unused

`systemd/install.sh` refuses an empty `OnFailure=` on any unit that has not declared
`SelfAlerting=acknowledged` in its `[X-Catallenya]` sticker — the same shape as
`UnboundedRoot=acknowledged`. **No unit declares it**, and the gate keeps it that way,
exactly as it does for `RuntimeMaxSec=` and `ExecStart=-`. Switching off a job's failure
alerting is the silent-failure class this repo is built to prevent, so it may be done,
but never quietly.

---

## 8b. What this contract does NOT cover

**Three things publish to this ntfy that are not this repo's code**, so nothing here
constrains them and no gate can see them. Named because a contract that lists only what
it governs reads as though it governs everything.

| Publisher | How it is wired | What it sends today |
|---|---|---|
| **watchtower** | `WATCHTOWER_NOTIFICATION_URL` in `docker-compose.yml`, shoutrrr | `Watchtower updates on 6729304e71db` over four lines of image hashes |
| **changedetection** (the app) | Apprise URL set in its **UI**, not in the repo | `yellowpaige shop changed` over a diff |
| **zed** (ZFS Event Daemon) | `/etc/zfs/zed.d/zed.rc` on the host | pool events on the `zpool` topic |

`changedetection` is the confusing one: the topic has **two** publishers by design — the
watches themselves (above) and `changedetection/changedetection.health.sh`, which IS in
the contract. Sharing one topic is deliberate; an unsubscribed monitoring topic swallows
alerts with a 200 OK.

**All three are reformattable, and none has been reformatted.** watchtower takes a Go
template (`WATCHTOWER_NOTIFICATION_TEMPLATE`); changedetection takes a title and body per
notification in its settings; zed's is shell. Two arguments cut against doing it: their
messages are *reports of their own work*, not this system's, so a foreign grammar is
arguably honest — and changedetection's lives in a UI rather than in the repo, so any
rule written here could be silently changed by a click and nothing would notice.

Left as an open decision rather than an omission. The one observation worth acting on
either way is not about format: watchtower fires **daily** for
`tomsquest/docker-radicale:latest`, which is rebuilt upstream every day, so that is one
notification a day saying nothing actionable.

---

## 9. Enforcement

`systemd/contract.sh`, eight rules, run by `bash systemd/install.sh --check` (no root
needed) and by `systemd/tests/run.sh`:

1. Every title argument is a `title_count`, `title_state` or `title_quote` substitution —
   nothing hand-built. A variable is followed to its assignment.
2. Its verb is in `NTFY_MODEL_VERBS` **or** in that file's own `NTFY_VERBS`.
3. Every `NTFY_VERBS` entry ends in `ed` **or** appears in `NTFY_IRREGULAR_VERBS`.
4. **No bare `notify ` outside `ntfy/`** — every job goes through a kind. This is what
   makes the wrappers authoritative; there is no merge engine underneath them.
5. **No `clear=true`** in an Actions string. It dismisses on the *tap*, before the work
   behind the button has happened, so a refused move would look like a completed one.
6. **A `notify_nudge` title reads as a nudge** — a `Still ` verb or a `title_age`
   bracket. A nudge indistinguishable from the first asking tells you nothing.
7. **No hand-built numbered list.** A literal `1\.` is what four files each discovered
   separately on the phone, after which each grew its own cap, its own truncation tail
   and its own indent — two of which were already different widths by the time they
   were collected.
8. **No hand-built italic line.** Italics mark a truncation count and nothing else, and
   `body_aside` is the only thing that emits them. The check looks for an underscore run
   closing before a quote, so it catches the shape `paused_body` shipped in for a year:
   italics inside a `printf` *format* string, which anything anchored on a leading `"_`
   walks straight past.

Rules 1–3 are about the title, 4–6 about the envelope, 7–8 about the body.

Gate rule 3 is what stops a new service breaking rule 3-of-§5 silently. It refuses
`Processing`, `Uploading`, `Waiting` — **and** `Stray`, `Unclear`, `Timeout`, which a
looser `-ing`-only check would have waved through. Both of those adjectives were proposed
during design.

**Vocabulary is declared per feature, never centrally.** Each feature's lib sets its own
`NTFY_VERBS` / `NTFY_NOUNS` / `NTFY_SUBJECTS`. This is the same shape as
`[X-Catallenya] Class=`: the thing declares, and nothing repeats it in a map. A central
verb table would be the `SUBSCRIBED` list again — hand-maintained, and it silently ate
four units' alerts once already.

**One exemption in the whole repo:** `ntfy/system-ntfy.sh`. See nuance 12.

---

## 10. Traps

**There is no merge engine.** `systemd/policy/` works because systemd genuinely merges
drop-ins — verified on this box, a unit's `RuntimeMaxSec=999` lost to a drop-in's `111` —
so that layering holds even when `install.sh` is wrong. Nothing equivalent happens here.
**Gate rule 1 is the only thing making the constructors authoritative.** Treat it as
load-bearing, not tidiness.

**A new tracked file needs a `.gitignore` allowlist line.** The file starts with `*` deny.
Without a line, a new file is untracked, invisible to `git status`, and silently absent
from anything reading the tree.

**`systemd/tests/run.sh` builds its check tree from a hardcoded directory list.** A
directory missing from it means a mutation case edits a file that is not in the tree, the
gate finds nothing to refuse, and the failure reads as *the gate stopped working* rather
than *the test is misconfigured*. That broke 23 cases on 2026-08-15.

**Nothing verifies a retract actually happened.** The wire is where visibility ends — the
same blind spot as ntfy accepting a publish to an unsubscribed topic with a 200 OK.

**Adding a new service?** Declare `NTFY_VERBS` in its lib, source `ntfy/kinds.sh` after
`ntfy/ntfy.lib.sh`, build every title with a constructor, and run
`bash systemd/install.sh --check`. Read §1 first to work out which class each of your
messages belongs to — that decides whether you may choose your own words.
