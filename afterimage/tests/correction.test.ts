// Drives the REAL server.ts against a stub Radicale. Run by tests/run.sh inside the
// afterimage image (bun is not on the host): the 2-minute correction window.
import { mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";

const DATA = "/tmp/spool";
const ID = "11111111-1111-1111-1111-111111111111";
const items = new Map<string, string>();
const stub = Bun.serve({
  port: 5999,
  async fetch(req) {
    const k = new URL(req.url).pathname;
    if (req.method === "PUT") {
      if (req.headers.get("if-none-match") === "*" && items.has(k)) return new Response("", { status: 412 });
      const had = items.has(k); items.set(k, await req.text());
      return new Response("", { status: had ? 204 : 201 });
    }
    if (req.method === "DELETE") { const had = items.delete(k); return new Response("", { status: had ? 204 : 404 }); }
    return new Response("", { status: 405 });
  },
});
process.env.CAPTURE_DATA = DATA; process.env.RADICALE_URL = "http://127.0.0.1:5999";
process.env.CAL_GENERAL = "gen"; process.env.CAPTURE_PORT = "5998"; process.env.NTFY_URL = "";
process.env.HITOME_DAV_B64 = "x";
await import("/app/src/server.ts");

let pass = 0, fail = 0;
const check = (name: string, got: unknown, want: unknown) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  ok ? pass++ : fail++; console.log(`  ${ok ? "ok  " : "FAIL"}  ${name}${ok ? "" : `\n     want ${JSON.stringify(want)}\n     got  ${JSON.stringify(got)}`}`);
};
const tap = async (act: string, alt = false) => {
  const r = await fetch(`http://127.0.0.1:5998/afterimage/${ID}/${act}${alt ? "?alt=1" : ""}`, { method: "POST", headers: { "x-afterimage": "1" } });
  return r.status;
};
const href = `/carrein/gen/${ID}.ics`;
const decision = () => JSON.parse(readFileSync(`${DATA}/archive/${ID}/decision.json`, "utf8"));
const seed = () => {
  items.clear();
  for (const d of ["pending", "archive", "incoming"]) mkdirSync(`${DATA}/${d}`, { recursive: true });
  const r = `${DATA}/pending/${ID}`; mkdirSync(r, { recursive: true });
  writeFileSync(`${r}/proposal.json`, '{"calendar":"general"}'); writeFileSync(`${r}/proposal.alt.json`, '{"calendar":"general"}');
  writeFileSync(`${r}/event.ics`, "MAIN"); writeFileSync(`${r}/event.alt.ics`, "ALT");
};
const age = (s: number) => { const d = decision(); d.decided_at = new Date(Date.now() - s * 1000).toISOString(); writeFileSync(`${DATA}/archive/${ID}/decision.json`, JSON.stringify(d)); };
const reset = () => { Bun.spawnSync(["rm", "-rf", `${DATA}/pending/${ID}`, `${DATA}/archive/${ID}`]); seed(); };

reset();
check("add writes the event", [await tap("add"), items.get(href)], [200, "MAIN"]);
check("outcome is add", decision().outcome, "add");
check("same button again: ok, nothing changes", [await tap("add"), items.get(href)], [200, "MAIN"]);
check("OTHER variant inside the window swaps", [await tap("add", true), items.get(href)], [200, "ALT"]);
check("and restamps add_alt", decision().outcome, "add_alt");
check("and can be swapped back", [await tap("add"), items.get(href), decision().outcome], [200, "MAIN", "add"]);
check("discard inside the window removes it", [await tap("drop"), items.has(href), decision().outcome], [200, false, "undone"]);
check("a second discard is a 409", await tap("drop"), 409);
check("add after undo is a 404", await tap("add"), 404);

reset(); await tap("add"); age(121);
check("past the window: other variant is a 404", [await tap("add", true), items.get(href)], [404, "MAIN"]);
check("past the window: discard is a 409 and keeps it", [await tap("drop"), items.has(href)], [409, true]);

reset(); await tap("add", true);
check("add_alt then main swaps the other way", [await tap("add"), items.get(href)], [200, "MAIN"]);

reset(); await tap("add"); items.clear();
check("undo when Radicale already lost it still succeeds", [await tap("drop"), decision().outcome], [200, "undone"]);

stub.stop(); console.log(`${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
