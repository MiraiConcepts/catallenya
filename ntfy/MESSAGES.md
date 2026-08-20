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
is listed in `NTFY_IRREGULAR_VERBS`. The gate checks this (§8).

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
| 5 | The gate **is** the layering | `systemd/contract.sh` | unlike systemd there is no merge engine. Nothing at runtime stops a hand-built string. See §8 |
| 6 | A proposal's nudge takes **no verb** | afterimage `sweep:184` | its original title is a quotation with no verb to reuse. afterimage therefore has two nudge shapes on purpose |
| 7 | Noun follows the pipeline **stage** | afterimage | `Screenshot` until the model produces events, `Event` after. `Passed: 3 Screenshots` would be wrong — three events came from one screenshot |
| 8 | Filenames stay in the **body**, not the title | pigeonhole | `title_count` accepts a name; pigeonhole deliberately passes none, because a batch of three wants three names listed, not one promoted |
| 9 | One notification **per verb**, not per run | liquidroom | a run where two tracks succeeded and one failed cannot honestly be titled `Finished` |
| 10 | Name the watch only at exactly one | changedetection | two or more and the title becomes a list; `Watches: 3 Findings` is the honest summary |
| 11 | Three faults are **digests**, so their state is caller-built text | disk, changedetection, watchdog | disk covers root *and* zpool; changedetection covers N problems of mixed types; the watchdog covers N mixed findings. The gate checks the shape, not the content |
| 12 | `system-ntfy.sh` is **exempt** from the constructors | courier | it is the alarm of last resort and must depend on as little as possible, including on another file in this repo being intact. It matches the grammar by hand; the gate checks it by pattern |
| 13 | The courier's **success branch is the canary** | restic | `restic.backup`, `restic.forget` and `restic.check@` wire `OnSuccess=`. Those pings are the only positive proof the `OnFailure=` path still reaches the phone — nothing watches the courier. **Only the daily backup ping is frequent enough to serve.** Do not delete it |
| 14 | `restic.staleness` is failure-only **by design** | restic | silence is the healthy state, and `install.sh` mechanically refuses `OnSuccess=` on `Class=monitor` |
| 15 | Boot reports failure only | host | dropped from success on 2026-08-20. Accepted consequence: after a power cut, silence no longer distinguishes *recovered* from *still dark*, and this box does not auto-restore on AC return |

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
| date or time ambiguous | `Flagged: Kene` |
| events found, all in the past | `Passed: 3 Events` |
| parked 7d from first failure | `Abandoned: 1 Screenshot` |
| needs-human untouched 24h | `Still Flagged: Kene [1d]` |
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
| something baked, or a concern | `Baked: 3 Rotations` |
| the run failed | `Rotation Bake: Failed` |

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

## 8. Enforcement

`systemd/contract.sh`, three rules, run by `bash systemd/install.sh --check` (no root
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

## 9. Traps

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
