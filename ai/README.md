# inference

> The shared AI layer of [catallenya](https://github.com/MiraiConcepts/catallenya), mirrored
> from `ai/`. Force-synced by CI — open issues and pull requests on the parent repo,
> not here. The consumers below live in the parent repo; two of them are themselves
> mirrored, as [afterimage](https://github.com/MiraiConcepts/afterimage) and
> [pigeonhole](https://github.com/MiraiConcepts/pigeonhole).

`ai/scripts/ai.lib.sh` is the only place in all of catallenya that talks to
`api.anthropic.com`, and every script that sources it calls the API:

| Consumer | Job |
|---|---|
| `afterimage/scripts/afterimage.triage.sh` | screenshot → proposed calendar event |
| `pigeonhole/scripts/pigeonhole.triage.sh` | document page → filing decision |

**Every consumer is an API caller, which is what makes the blast radius here
predictable.** That was not always true: `liquidroom` used to source this whole
library while calling no API at all, purely to reach `md_escape` and `hdr_safe`.
Those two moved to `ntfy/ntfy.lib.sh` on 2026-08-10 — they guard the boundary where
untrusted text reaches a *notification*, which belongs to that sink and not to the
API that happened to fetch the text — and liquidroom stopped depending on this file.

## Why a library and not a service

Both API consumers are bash on this host, so the cheapest correct boundary is `source`,
not a port. An HTTP service was considered and deliberately not built:

- it would hold `ANTHROPIC_API_KEY` in a container environment 24/7 — readable via
  `docker inspect`, and to anything with code execution in that container — instead of
  injected per-run by systemd into a `ProtectSystem=strict` oneshot that then exits;
- it would need its own auth gate on an internal port ~26 containers can reach;
- it would add a hop for ~1MB of base64 per call.

`api_post` is deliberately the single seam. If a non-bash consumer ever appears — the
capture container itself, a future job — wrapping that one function in a container is a
contained change, not a rewrite. That is the trigger condition; absent it, don't.

## Surface

| Function | Does |
|---|---|
| `api_class <status> [body]` | `ok` / `retry` / `paused` / `fatal`. `000` = curl never completed the exchange. The body is optional and decides one case only — see below |
| `api_post <body-file>` | POST + retry. `0` ok, `1` fatal, `2` transient exhausted, `3` paused |
| `ai_reason <rc>` | the one sentence a consumer puts in front of a human |
| `image_mime` / `image_ext` | format from magic bytes, **never** the filename |
| `ai_build_request <out> <model> <effort> <max_tokens> <schema> <prompt> [img...]` | writes the `/v1/messages` body |
| `ai_extract <response>` | `stop_reason` gate + structured-object extraction |

`AI_MODEL` / `AI_EFFORT` live here too — both pipelines run the same model at the
same effort, so a model bump is one edit. Consumers keep only what is theirs:
prompt, schema, max_tokens.

## Four verdicts, three branches

An API failure is not one thing. `api_class` separates them, and a consumer needs
only three branches — proceed, resolve now, or park — because `retry` and `paused`
are disposed of identically and differ only in the sentence `ai_reason` supplies.

| Verdict | rc | Comes from | Means |
|---|---|---|---|
| `ok` | 0 | 200 | an answer |
| `retry` | 2 | 429, any 5xx, `000` — after three in-run attempts | unreachable; it will fix itself |
| `paused` | 3 | 402, a 403 carrying `billing_error`, or a 400 whose *message* names the credit balance | the account cannot pay; the request was fine |
| `fatal` | 1 | anything else — and a 200 whose `stop_reason` is a refusal or a truncation | this item will never work |

**`paused` exists because the status code cannot separate an unusable ACCOUNT from
an unusable REQUEST.** An empty balance and a revoked key both arrive as `403`, so
`api_class` takes the response body as an optional second argument and reads
`error.type`. Every call without a body behaves exactly as it did before that
argument existed.

Getting this wrong is expensive in a specific way: treated as `fatal`, an unpaid
account made afterimage archive a perfectly good screenshot as failed and prune the
image a week later, while telling its owner to go and check an API key that was
never the problem. Treated as `retry`, it would burn attempts on something no amount
of waiting fixes. It is neither, so it is its own answer.

## Things that are load-bearing

**No `tools` key, ever.** A plain Messages request has no tool surface and no path to
the filesystem. Containment is a property of the endpoint rather than something the
scripts arrange — which is why `documents.intake.classify.sh` could delete a 30-line
containment header and four documented CLI traps when it moved here on 2026-07-30.

**Base64 goes via a file, never argv.** Linux caps a single argv entry at
`MAX_ARG_STRLEN` (128KB), far below the 2MB `ARG_MAX` total. Three rasterised PDF pages
are ~800KB of base64 and a screenshot ~1MB. Passing them with `--arg` blew up three
times during `documents.intake`'s original build; `--rawfile` / `--slurpfile` is why it
doesn't now. Both the per-image blob and the accumulating content array must be
file-passed.

**The key goes via curl's stdin config, never argv.** `/proc` is mounted without
`hidepid` here, so `/proc/<pid>/cmdline` is world-readable for the whole call.

**`curl -f` is deliberately unused.** It collapses every failure into exit 22 and
discards the response body, making a rate limit indistinguishable from a bad key — and
a caller treating both as terminal destroys its input on a single blip. The status code
decides whether to retry.

## Credential

`ANTHROPIC_API_KEY` lives in `/etc/ai.env`, root-owned 0600, read by systemd (PID 1)
and injected into both `User=carrein` oneshots. It is never in a carrein-readable file,
never in the repo, never in `.env`, never on a command line. The filename is
deliberately not capture-specific — it was `/etc/capture.env` until 2026-07-30, when
documents-intake became the second consumer.

```bash
sudoedit /etc/ai.env      # ANTHROPIC_API_KEY=sk-ant-...
sudo chmod 600 /etc/ai.env
```

## Tests

```bash
bash ai/tests/run.sh
```

Offline and free. `tests/sink.py` is a fake Messages endpoint that serves a scripted
list of status codes (`429,429,200` → 429, then 429, then 200), which is the only way
to prove the retry loop both retries and stops — a real API failure cannot be summoned
on demand, and paying for one would defeat the point. Point `API_URL` at it from any
consumer to exercise that consumer's failure handling end to end.

These cases were capture's until documents-intake became the second consumer; they live
here now because the code does. `afterimage/tests/run.sh` keeps everything capture-specific
— run both.
