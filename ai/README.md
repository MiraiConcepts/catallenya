# Shared AI layer

`ai/scripts/ai.lib.sh` is the only place in this repo that talks to
`api.anthropic.com`. Two consumers source it:

| Consumer | Job |
|---|---|
| `capture/scripts/capture.triage.sh` | screenshot → proposed calendar event |
| `documents/scripts/documents.triage.sh` | document page → filing decision |

## Why a library and not a service

Both consumers are bash on this host, so the cheapest correct boundary is `source`,
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
| `api_class <status>` | `ok` / `retry` / `fatal`. `000` = curl never completed the exchange |
| `api_post <body-file>` | POST + retry. `0` ok, `1` fatal, `2` transient exhausted |
| `image_mime` / `image_ext` | format from magic bytes, **never** the filename |
| `ai_build_request <out> <model> <effort> <max_tokens> <schema> <prompt> [img...]` | writes the `/v1/messages` body |
| `ai_extract <response>` | `stop_reason` gate + structured-object extraction |

`AI_MODEL` / `AI_EFFORT` live here too — both pipelines run the same model at the
same effort, so a model bump is one edit. Consumers keep only what is theirs:
prompt, schema, max_tokens.

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
here now because the code does. `capture/tests/run.sh` keeps everything capture-specific
— run both.
