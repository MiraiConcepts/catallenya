#!/usr/bin/env python3
"""Keep the "Carrein's Holidays" calendar in Radicale in step with MOM's list.

Source: the Ministry of Manpower's public-holiday datasets on data.gov.sg (Open
Data Licence). Every year MOM publishes a NEW dataset; all of them hang off one
collection, so a year is found by walking that collection's children rather than
by a hard-coded id. A year that is not published yet is reported and skipped,
never a failure — next year's list normally lands July to September.

Sink: one CalDAV collection, carrein/singapore-holidays, one all-day VEVENT per
holiday date with a stable UID (sg-holiday-YYYY-MM-DD@hitome). Re-running writes
only what changed and deletes holidays MOM has withdrawn from a covered year, so
the calendar converges on the source and never duplicates. No other collection
is ever read or written.

Observed days: MOM's datasets already list the Monday in lieu as its own row
("Vesak Day (Observed)"). Those rows are used as they are. A Sunday holiday whose
Monday is missing from the source gets a synthesized "<name> (observed)" Monday
as a FALLBACK only — computing it unconditionally would collide with MOM's row.

Credential: the Radicale app password already on this host for afterimage
(afterimage/dav-secret, gitignored, never in an image or CI). Radicale is reached
container-to-container on its docker IP, the same path afterimage uses.

Output: exactly one line on stdout per run (that is what the ntfy courier quotes
on failure); diagnostics go to stderr. Exit non-zero on any failure.

Env:
  DATA_GOV_SG_API_KEY   optional; raises the data.gov.sg rate limit
  HOLIDAYS_DRY_RUN=1    fetch and build, print what would change, write nothing
"""

import base64
import datetime as dt
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

REPO = "/zpool/catallenya"
DAV_SECRET = f"{REPO}/afterimage/dav-secret"
DAV_USER = "carrein"
COLLECTION = "singapore-holidays"
DISPLAY_NAME = "Carrein's Holidays"
COLOR = "#D0021BFF"  # red, the colour paper calendars print public holidays in
UID_PREFIX = "sg-holiday-"
UID_SUFFIX = "@hitome"

# MOM's "Singapore Public Holidays" collection; each year is a child dataset.
COLLECTION_META = "https://api-production.data.gov.sg/v2/public/api/collections/691/metadata"
DATASTORE = "https://data.gov.sg/api/action/datastore_search"
# Used only if the collection lookup itself fails: consolidated, 2026, 2027.
KNOWN_DATASETS = [
    "d_8ef23381f9417e4d4254ee8b4dcdb176",
    "d_149b61ad0a22f61c09dc80f2df5bbec8",
    "d_0ba69fc6d56717ff0bf8083c6af3bb84",
]

SGT = dt.timezone(dt.timedelta(hours=8))
DRY_RUN = os.environ.get("HOLIDAYS_DRY_RUN") == "1"


def log(msg):
    print(msg, file=sys.stderr, flush=True)


# --- data.gov.sg ------------------------------------------------------------

def http_json(url):
    """GET JSON, waiting out the anonymous rate limit (429, "try again in 10s")."""
    headers = {"Accept": "application/json", "User-Agent": "catallenya-holidays/1"}
    key = os.environ.get("DATA_GOV_SG_API_KEY")
    if key:
        headers["x-api-key"] = key
    for attempt in range(6):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt == 5:
                raise
        time.sleep(11 + attempt * 5)
    raise RuntimeError("unreachable")


def dataset_ids():
    try:
        meta = http_json(COLLECTION_META)
        ids = meta["data"]["collectionMetadata"]["childDatasets"]
        if ids:
            return ids
        log("collection 691 lists no datasets; using known ids")
    except Exception as e:  # noqa: BLE001 — any failure here has the same fallback
        log(f"collection lookup failed ({e}); using known ids")
    return KNOWN_DATASETS


def dataset_records(rid):
    """All rows of one dataset, following `_links.next` until a short page."""
    out, offset = [], 0
    while True:
        res = http_json(f"{DATASTORE}?resource_id={rid}&limit=100&offset={offset}")
        if not res.get("success"):
            raise RuntimeError(f"{rid}: datastore_search returned success=false")
        rows = res["result"]["records"]
        out += rows
        if len(rows) < 100 or len(out) >= res["result"].get("total", 0):
            return out
        offset += 100


def fetch_years(years):
    """{year: [(date, name)]} for each year MOM has published.

    A dataset covering exactly one year is that year's authoritative list. Children
    are walked newest-first (MOM appends each new year to the end) and the walk
    stops once every wanted year has one, which keeps a normal run to 2-3 calls.
    Multi-year datasets (the 2020-2027 consolidation) are only a fallback.
    """
    single, multi = {}, {}
    for rid in reversed(dataset_ids()):
        rows = [(r["date"], r["holiday"].strip()) for r in dataset_records(rid)]
        spanned = {int(d[:4]) for d, _ in rows}
        if len(spanned) == 1:
            y = spanned.pop()
            if y in years and y not in single:
                single[y] = rows
        else:
            for d, n in rows:
                if int(d[:4]) in years:
                    multi.setdefault(int(d[:4]), []).append((d, n))
        if all(y in single for y in years):
            break
    return {y: single.get(y) or multi[y] for y in years if y in single or y in multi}


# --- holidays -> events -----------------------------------------------------

def build_events(rows):
    """{date: summary}, one event per date, plus fallback observed Mondays."""
    by_date = {}
    for d, name in rows:
        dt.date.fromisoformat(d)  # refuse anything that is not a real date
        name = name.replace("(Observed)", "(observed)")
        if name not in by_date.setdefault(d, []):
            by_date[d].append(name)
    events = {d: " / ".join(ns) for d, ns in by_date.items()}
    for d, ns in list(by_date.items()):
        day = dt.date.fromisoformat(d)
        monday = (day + dt.timedelta(days=1)).isoformat()
        if day.weekday() == 6 and monday not in events and not any("(observed)" in n for n in ns):
            events[monday] = f"{ns[0]} (observed)"
            log(f"synthesized {monday} {events[monday]} (absent from source)")
    return events


def ics_text(s):
    return s.replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\n", "\\n")


def fold(line):
    raw, out = line.encode(), []
    while len(raw) > 75:
        cut = 75 if not out else 74
        while (raw[cut] & 0xC0) == 0x80:  # never split a UTF-8 sequence
            cut -= 1
        out.append(raw[:cut])
        raw = raw[cut:]
    out.append(raw)
    return b"\r\n ".join(out).decode()


def vevent(date, summary, stamp):
    start = dt.date.fromisoformat(date)
    lines = [
        "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//catallenya//sg-holidays//EN",
        "BEGIN:VEVENT",
        f"UID:{UID_PREFIX}{date}{UID_SUFFIX}",
        f"DTSTAMP:{stamp}",
        f"DTSTART;VALUE=DATE:{start:%Y%m%d}",
        f"DTEND;VALUE=DATE:{start + dt.timedelta(days=1):%Y%m%d}",
        f"SUMMARY:{ics_text(summary)}",
        "TRANSP:TRANSPARENT",
        "END:VEVENT", "END:VCALENDAR",
    ]
    return "".join(fold(l) + "\r\n" for l in lines)


def essence(ics):
    """The fields this job owns, so an unchanged event is not rewritten weekly
    (a fresh DTSTAMP alone would bump every ETag and make every client resync)."""
    unfolded = ics.replace("\r\n ", "").replace("\n ", "")
    keep = ("SUMMARY", "DTSTART", "DTEND", "TRANSP")
    return sorted(l.strip() for l in unfolded.splitlines() if l.split(":")[0].split(";")[0] in keep)


# --- CalDAV -----------------------------------------------------------------

class Dav:
    def __init__(self):
        ip = subprocess.run(
            ["docker", "inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", "radicale"],
            check=True, capture_output=True, text=True).stdout.split()[0]
        with open(DAV_SECRET) as f:
            self.auth = f.read().strip()
        if not base64.b64decode(self.auth).decode().startswith(f"{DAV_USER}:"):
            raise RuntimeError(f"{DAV_SECRET} does not decode to user {DAV_USER}")
        self.base = f"http://{ip}:5232/{DAV_USER}/{COLLECTION}/"

    def req(self, method, url, body=None, headers=None, ok=(200, 201, 204, 207)):
        h = {"Authorization": f"Basic {self.auth}", **(headers or {})}
        data = body.encode() if isinstance(body, str) else body
        r = urllib.request.Request(url, data=data, headers=h, method=method)
        try:
            with urllib.request.urlopen(r, timeout=30) as resp:
                return resp.status, resp.read().decode()
        except urllib.error.HTTPError as e:
            if e.code in ok:
                return e.code, e.read().decode()
            raise RuntimeError(f"{method} {url} -> HTTP {e.code}") from None

    def ensure_collection(self):
        status, _ = self.req("PROPFIND", self.base, headers={"Depth": "0"}, ok=(207, 404))
        if status != 404:
            return False
        body = f"""<?xml version="1.0" encoding="utf-8"?>
<C:mkcalendar xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:I="http://apple.com/ns/ical/">
 <D:set><D:prop>
  <D:displayname>{DISPLAY_NAME}</D:displayname>
  <I:calendar-color>{COLOR}</I:calendar-color>
  <C:supported-calendar-component-set><C:comp name="VEVENT"/></C:supported-calendar-component-set>
 </D:prop></D:set>
</C:mkcalendar>"""
        if not DRY_RUN:
            self.req("MKCALENDAR", self.base, body, {"Content-Type": "application/xml; charset=utf-8"})
        return True

    def existing(self):
        """{href basename: path} for every object in the collection."""
        status, xml = self.req("PROPFIND", self.base, headers={"Depth": "1"}, ok=(207, 404))
        if status == 404:
            return {}
        out = {}
        for href in ET.fromstring(xml).iter("{DAV:}href"):
            name = urllib.parse.unquote(href.text.rstrip("/").rsplit("/", 1)[-1])
            if name.endswith(".ics"):
                out[name] = href.text
        return out

    def get(self, name):
        return self.req("GET", self.base + name)[1]

    def put(self, name, ics):
        self.req("PUT", self.base + name, ics, {"Content-Type": "text/calendar; charset=utf-8"})

    def delete(self, name):
        self.req("DELETE", self.base + name)


# --- main -------------------------------------------------------------------

def main():
    this_year = dt.datetime.now(SGT).year
    years = [this_year, this_year + 1]
    data = fetch_years(set(years))
    if this_year not in data:
        raise RuntimeError(f"no holidays found for the current year {this_year}")
    missing = [y for y in years if y not in data]

    wanted = {}
    for y in sorted(data):
        wanted.update(build_events(data[y]))

    dav = Dav()
    created = dav.ensure_collection()
    have = {} if created and DRY_RUN else dav.existing()
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    written = unchanged = deleted = 0
    for date, summary in sorted(wanted.items()):
        name = f"{UID_PREFIX}{date}{UID_SUFFIX}.ics"
        ics = vevent(date, summary, stamp)
        if name in have and essence(dav.get(name)) == essence(ics):
            unchanged += 1
            continue
        log(f"{'would write' if DRY_RUN else 'write'} {date} {summary}")
        if not DRY_RUN:
            dav.put(name, ics)
        written += 1
    # Withdrawn holidays: only ours, and only in a year this run has fresh data for.
    # Past years and unpublished years are left exactly as they are.
    for name in sorted(have):
        if not name.startswith(UID_PREFIX):
            continue
        date = name[len(UID_PREFIX):len(UID_PREFIX) + 10]
        if date[:4].isdigit() and int(date[:4]) in data and date not in wanted:
            log(f"{'would delete' if DRY_RUN else 'delete'} {name}")
            if not DRY_RUN:
                dav.delete(name)
            deleted += 1

    covered = ",".join(str(y) for y in sorted(data))
    tail = f"; {','.join(map(str, missing))} not published yet" if missing else ""
    print(f"{'DRY RUN ' if DRY_RUN else ''}ok: years {covered}, {len(wanted)} holidays, "
          f"{written} written, {unchanged} unchanged, {deleted} deleted"
          f"{', calendar created' if created else ''}{tail}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001 — the one line the courier quotes
        print(f"FAILED: {e}")
        sys.exit(1)
