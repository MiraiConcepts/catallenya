// capture — the "dumb" HTTP surface of the screenshot -> calendar pipeline.
//
// It does exactly three things: accept an uploaded screenshot, and on the ntfy
// button callbacks either PUT the already-rendered event to Radicale (Add) or
// drop the record (Discard). No AI, no .ics rendering, no secrets beyond the
// Radicale app password — all the intelligence lives in the host triage
// (capture/scripts/), which talks to this container only through the shared
// capture/data/ spool.
//
// The <id> in the callback URLs is an unguessable UUID, so the callbacks are
// capability URLs: on the tailnet, "whoever knows the id" is effectively just
// the owner. That's the same trust model as every other service here.

import { mkdir, rename, rm, readFile, stat, appendFile } from "node:fs/promises";
import { existsSync } from "node:fs";

const DATA = process.env.CAPTURE_DATA ?? "/data";
const PORT = Number(process.env.CAPTURE_PORT ?? 8080);
const RADICALE = process.env.RADICALE_URL ?? "http://radicale:5232";
const DAV_USER = process.env.CAPTURE_DAV_USER ?? "carrein";
const DAV_B64 = process.env.MITSUME_DAV_B64 ?? ""; // base64(carrein:<app pw>)
const CAL: Record<string, string> = {
  general: process.env.CAL_GENERAL ?? "",
  birthday: process.env.CAL_BIRTHDAY ?? "",
};

const spool = (...p: string[]) => [DATA, ...p].join("/");

// Resolve a capture: stamp the verdict into the record, move the whole thing
// (screenshot + proposal + .ics) to the archive, and append one line to the
// ledger. Nothing is deleted — the screenshot plus the model's proposal plus the
// human verdict is a labelled example, and that dataset is the point of keeping
// captures indefinitely. Mirrors archive_record() in capture.lib.sh.
async function archive(id: string, outcome: string, note = ""): Promise<void> {
  const src = spool("pending", id);
  if (!existsSync(src)) return;

  // Recording off (data/.recording-disabled present): delete the record instead
  // of archiving it, and write nothing to the ledger. Checked per request, so the
  // flag can be toggled without restarting the container. Mirrors capture.lib.sh.
  if (existsSync(spool(".recording-disabled"))) {
    await rm(src, { recursive: true, force: true });
    console.log(`[not recorded: ${outcome}] ${id} — recording is disabled`);
    return;
  }
  const dest = spool("archive", id);
  const decidedAt = new Date().toISOString();
  let proposedAt = decidedAt;
  let latency = 0;
  try {
    const st = await stat(`${src}/proposal.json`);
    proposedAt = st.mtime.toISOString();
    latency = Math.round((Date.now() - st.mtimeMs) / 1000);
  } catch { /* record may predate proposal.json; fall back to now */ }

  const decision = { id, outcome, note, proposed_at: proposedAt, decided_at: decidedAt, latency_s: latency };
  await Bun.write(`${src}/decision.json`, JSON.stringify(decision));
  await mkdir(spool("archive"), { recursive: true });
  await rm(dest, { recursive: true, force: true });
  await rename(src, dest);
  // Genuinely append (O_APPEND), not read-concat-write: the previous form lost a
  // line when two callbacks raced, and truncated the whole ledger if it crashed
  // mid-write. capture.lib.sh has always used >> — this now matches it.
  await appendFile(spool("decisions.jsonl"), JSON.stringify(decision) + "\n");
}
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const PNG_SIG = [0x89, 0x50, 0x4e, 0x47]; // \x89PNG — client always emits PNG
const MAX_BYTES = 15 * 1024 * 1024;

for (const d of ["incoming", "pending", "archive"]) {
  await mkdir(spool(d), { recursive: true });
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

// POST /capture — receive a screenshot, drop it in the spool, return its id.
// The host triage's .path unit fires on the new file; this container does no
// more work until an Add/Discard callback arrives.
async function handleUpload(req: Request): Promise<Response> {
  const buf = new Uint8Array(await req.arrayBuffer());
  if (buf.length === 0 || buf.length > MAX_BYTES) return json({ error: "bad size" }, 413);
  if (!PNG_SIG.every((b, i) => buf[i] === b)) return json({ error: "not a png" }, 415);
  const id = crypto.randomUUID();
  // Write under a name the .path unit's glob (*.png) does NOT match, then rename.
  // rename(2) is atomic within a filesystem, so systemd only ever sees a complete
  // file — otherwise PathExistsGlob can fire mid-write and the triage reads a
  // truncated PNG, burning an API call on a corrupt image.
  const tmp = spool("incoming", `.part-${id}`);
  await Bun.write(tmp, buf);
  await rename(tmp, spool("incoming", `${id}.png`));
  return json({ id });
}

// POST /capture/:id/add[?alt=1] — the Add button. Read the rendered event + its
// calendar routing from pending/<id>/, PUT it to the mapped Radicale collection,
// and on success move the record to done/.
//
// `alt=1` selects the disambiguation variant (event.alt.ics), which the triage
// renders when the screenshot supported a second plausible reading — that's the
// second button on the notification. Both variants are pre-rendered, so either
// tap is a straight file read plus one PUT.
async function handleAdd(id: string, alt: boolean): Promise<Response> {
  const rec = spool("pending", id);
  if (!existsSync(rec)) return json({ error: "no pending record" }, 404);

  const icsFile = alt ? "event.alt.ics" : "event.ics";
  const propFile = alt ? "proposal.alt.json" : "proposal.json";

  let proposal: { calendar?: string };
  let ics: string;
  try {
    proposal = JSON.parse(await readFile(`${rec}/${propFile}`, "utf8"));
    ics = await readFile(`${rec}/${icsFile}`, "utf8");
  } catch {
    return json({ error: alt ? "no alternative on this record" : "record incomplete" }, 409);
  }

  const collection = proposal.calendar === "birthday" ? CAL.birthday : CAL.general;
  if (!collection) return json({ error: "collection not configured" }, 500);

  // If-None-Match: * makes this create-only; a duplicate Add tap gets 412, which
  // we treat as already-done (idempotent). The record <id> is the item href.
  const res = await fetch(`${RADICALE}/${DAV_USER}/${collection}/${id}.ics`, {
    method: "PUT",
    headers: {
      authorization: `Basic ${DAV_B64}`,
      "content-type": "text/calendar",
      "if-none-match": "*",
    },
    body: ics,
  });

  if (res.status === 201 || res.status === 204 || res.status === 412) {
    // 412 = If-None-Match tripped, i.e. a duplicate Add tap. The event already
    // exists, so treat it as success and still record the verdict.
    await archive(id, alt ? "add_alt" : "add", `caldav ${res.status}`);
    return json({ ok: true, status: res.status });
  }
  // Non-2xx: leave the record in pending/ so a retry is possible; the host
  // triage's ntfy already carries the buttons for another attempt.
  return json({ error: "caldav put failed", status: res.status }, 502);
}

// POST /capture/:id/drop — the Discard button. A rejection is as much a labelled
// example as an acceptance ("the model proposed this and I said no"), so the
// record is archived with the verdict rather than deleted.
async function handleDrop(id: string): Promise<Response> {
  await archive(id, "discard");
  await rm(spool("incoming", `${id}.png`), { force: true });
  return json({ ok: true });
}

Bun.serve({
  port: PORT,
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/healthz") return new Response("ok");

    const m = url.pathname.match(/^\/capture(?:\/([^/]+)\/(add|drop))?\/?$/);
    if (!m) return json({ error: "not found" }, 404);

    // Require a custom header on EVERY /capture route — the upload included.
    // This is NOT authentication: anyone who can read the ntfy topic still has the
    // callback ids, and ntfy is currently unauthenticated (accepted risk).
    //
    // What it kills is the no-preflight vector. A bare POST with no custom header
    // is a CORS "simple request", so any web page open on any tailnet device could
    // fire one cross-origin — and the .ts.net hostname is in Certificate
    // Transparency logs, not a secret. Requiring a custom header forces a preflight
    // this server never answers, so the browser refuses to send it. ntfy action
    // buttons set headers natively, so real taps are unaffected.
    //
    // The upload branch needs this MORE than the callbacks do: it is the endpoint
    // that spends money (one opus-5 vision call per accepted PNG) and it is
    // reachable container-to-container on the flat compose network, where Caddy is
    // bypassed entirely — changedetection-browser renders attacker-chosen pages and
    // archivebox fetches attacker-chosen URLs, and both can resolve capture:8080.
    if (req.headers.get("x-capture") !== "1") {
      return json({ error: "missing x-capture header" }, 403);
    }

    const [, id, action] = m;
    if (!id) {
      return req.method === "POST" ? handleUpload(req) : json({ error: "method not allowed" }, 405);
    }
    if (!UUID.test(id)) return json({ error: "bad id" }, 400); // reject path traversal
    if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

    return action === "add"
      ? handleAdd(id, url.searchParams.get("alt") === "1")
      : handleDrop(id);
  },
});

console.log(`capture listening on :${PORT}`);
