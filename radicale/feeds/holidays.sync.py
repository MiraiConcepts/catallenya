#!/usr/bin/env python3
"""Keep the "Carrein's Holidays" calendar in Radicale in step with MOM's list.

Source: the Ministry of Manpower's public-holiday datasets on data.gov.sg (Open
Data Licence). Every year MOM publishes a NEW dataset; all of them hang off one
collection, so a year is found by walking that collection's children rather than
by a hard-coded id. A year that is not published yet is reported and skipped,
never a failure — next year's list normally lands July to September.

Sink: feeds_sink.py, shared with every calendar feed — this file is only the reader.
One CalDAV collection, carrein/singapore-holidays, one all-day VEVENT per holiday
date with a stable UID (sg-holiday-YYYY-MM-DD@hitome). The sink writes only what
changed, keeps whatever hitome added (TRANSP, alarms), and removes a holiday MOM has
withdrawn from a covered year — deleted, or set CANCELLED if it was marked "going".

Observed days: MOM's datasets already list the Monday in lieu as its own row
("Vesak Day (Observed)"). Those rows are used as they are. A Sunday holiday whose
Monday is missing from the source gets a synthesized "<name> (observed)" Monday
as a FALLBACK only — computing it unconditionally would collide with MOM's row.

Credential, output and the dry-run switch (FEEDS_DRY_RUN=1) are the sink's; see
the header of feeds_sink.py.

Env:
  DATA_GOV_SG_API_KEY   optional; raises the data.gov.sg rate limit
"""

import datetime as dt
import json
import os
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir
import feeds_sink as sink  # noqa: E402

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
log = sink.log


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
    events = []
    for date, summary in sorted(wanted.items()):
        day = dt.date.fromisoformat(date)
        events.append(sink.Event(uid=f"{UID_PREFIX}{date}{UID_SUFFIX}", summary=summary,
                                 start=day, end=day + dt.timedelta(days=1)))

    feed = sink.Feed(
        name="holidays", collection=COLLECTION, display_name=DISPLAY_NAME, color=COLOR,
        prodid="-//catallenya//sg-holidays//EN", uid_prefix=UID_PREFIX,
        # Withdrawn holidays are removed only in a year this run has fresh data for;
        # an unpublished year is left exactly as it is. (Past events are never
        # removed at all — the sink's rule.)
        in_scope=lambda start: start.year in data)
    line = sink.sync(feed, events)
    covered = ",".join(str(y) for y in sorted(data))
    tail = f"; {','.join(map(str, missing))} not published yet" if missing else ""
    return line.replace("ok: ", f"ok: years {covered}, ", 1) + tail


if __name__ == "__main__":
    sink.run(main)
