# dispatch

> The message layer of [catallenya](https://github.com/carrein/catallenya), mirrored
> from `ntfy/`. Force-synced by CI — open issues and pull requests on the parent repo,
> not here. The jobs that send through it live there; five of them are themselves
> mirrored, as [afterimage](https://github.com/MiraiConcepts/afterimage),
> [pigeonhole](https://github.com/MiraiConcepts/pigeonhole),
> [liquidroom](https://github.com/MiraiConcepts/liquidroom),
> [controlplane](https://github.com/MiraiConcepts/controlplane) and
> [inference](https://github.com/MiraiConcepts/inference).

One self-hosted [ntfy](https://ntfy.sh) server, ten topics, and about thirty places in
a personal-infrastructure repo that want to say something. This is what stops those
thirty places from each inventing their own way of saying it.

## The problem, stated honestly

In roughly a year, 32 emission points across 12 files grew **six incompatible
grammars**. Not through carelessness — each one was reasonable where it was written:

```
Disk Space Alert                      which disk? how full?
✅ Backup complete                    an emoji, and a tense nothing else used
capture: 3 events found               the topic, repeated in the title
Liquidroom: stems ready               the outcome phrase, where a name should be
Needs a human                         an instruction, not a report
Watchtower updates on 6729304e71db    a container id, identifying nothing
```

The transport was unified first. That standardised the *wire* and changed none of the
above, because the wire was never the problem.

## What a message looks like now

```
Boot: 2 Containers Down
1. immich-server
    Status: exited
2. archivebox_sonic
    Status: created

• 24/26 containers running
• 15/15 timers active

The stack did not finish coming up.
```

**A title is `Subject: State` or `Verb: N Noun`,** built by a constructor —
`title_count`, `title_state`, `title_quote` — never written by hand. Every verb is a
past participle (`Staged`, `Binned`, `Refused`), and the subject may never repeat the
topic it is published to.

**A body has four shapes and no others:** an **item**, a **detail** indented under its
item, a **fact** (`•`), and **prose** — in that order. Four renderers produce them, and
every one escapes its input.

## The three ideas worth stealing

**Vocabulary is declared per feature, never centrally.** Each feature's library sets its
own `NTFY_VERBS`/`NTFY_NOUNS`; the gate checks a title's verb against the file it was
written in. A central verb table would be one more hand-maintained list to fall out of
date — and the one such list this repo had (the courier's topic allowlist) silently ate
four units' alerts before anyone noticed.

**The kind decides which arguments exist.** There are five wrappers — `notify_proposal`,
`notify_nudge`, `notify_resolved`, `notify_fault`, `notify_receipt` — and they render
identically. Their value is structural: a receipt has nowhere to put a button, and a
proposal cannot omit the sequence id that makes it withdrawable. Lifecycle rules become
things you *cannot* express wrongly rather than things you must remember.

**A notification with buttons may be withdrawn; one without never is.** An absent
notification is ambiguous — fixed, mis-swiped, or never sent — while a stale one is not.

## The gate is the layering

This borrows its shape from the repo's systemd policy layers, and the borrowing is
**weaker than it looks**. systemd has a real merge engine, so its layering holds even
when the installer is wrong. There is none here: nothing at runtime stops a caller
passing the transport a hand-built string.

So the check *is* the mechanism. Nine rules refuse, at `--check` time, a title not from
a constructor, an undeclared verb, a verb that is not a past participle, a bare
transport call, a `clear=true` action, a nudge that reads like a first ask, a hand-built
numbered list, a hand-built italic line, and a markdown link in a body.

Each was written after finding the thing it forbids. Two are worth the detail:

- The italics rule matches an underscore run *closing before a quote*, not a leading
  `"_` — because the worst instance in the repo emitted its italics from inside a
  `printf` **format** string, which anything anchored on the opening quote walks past.
- The link rule matches `](http` — link *syntax*, which hides its destination behind
  friendly text. A bare URL is deliberately allowed: it shows where it goes.

## Device quirks, learned the hard way

Every one of these was discovered on an actual phone, and each had been copy-pasted
between features before it lived in one place:

| Quirk | Consequence |
|---|---|
| Android renders real ordered-list markers as unnumbered dots | the numbers silently vanish, so `1\.` is escaped |
| the web app collapses ordinary leading whitespace | indents use non-breaking spaces |
| a body over 4096 bytes becomes an **attachment** that expires in 3h | lists are capped |
| `X-ID` is accepted with a 200 and **silently ignored** | the header is `X-Sequence-ID`, or every retract addresses nothing |
| U+25AA has an emoji presentation | it drew as a coloured square; the marker is U+2022 |

## Read this

**[`MESSAGES.md`](MESSAGES.md)** is the contract — the class model, the verb list, every
title in the system, the fifteen deliberate exceptions and why each one is allowed. It
is written to a single test: *everything is lost, someone has this file, can they
rebuild it correctly?*

## Files

| | |
|---|---|
| `MESSAGES.md` | the contract |
| `kinds.sh` | title constructors, the five kinds, the four body renderers |
| `ntfy.lib.sh` | the transport, the sanitisers, the mute seam |
| `system-ntfy.sh` | the courier every `OnFailure=` points at — the one deliberate exemption, matching the grammar by hand because it depends on nothing |
| `tests/run.sh` | offline suite; no network, no phone |
