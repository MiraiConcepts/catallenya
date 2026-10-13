"""The CalDAV sink every calendar feed writes through. Imported, never executed.

A FEED is a reader that turns some outside source (MOM's holiday datasets, the
Filmhouse listings page, ...) into a list of `Event`s, and hands that list to
`sync()`. Everything after the list is here, once: listing the collection, deciding
what changed, writing it, cancelling or deleting what vanished, and the guards.
The readers stay small and know nothing about CalDAV.

WHY SHARED, AND WHY ONLY THIS HALF. This is the only code in the repo that deletes
things from a calendar the owner reads. One tested copy beats one per source that
drift apart one at a time — the ntfy transport was four private curl copies, all
different, by the time anyone collected them. The fetching half is never shared:
every source is different and a "generic scraper" would be a framework for one.

THE CONTRACT WITH HITOME (2026-10-12). hitome shows these collections in a tray;
tapping + sets TRANSP:OPAQUE ("going") and adds a VALARM, on the server event
itself. So an event is SHARED between two writers, and the rules are:

  1. The feed owns exactly OWNED below. Every other line on the server copy is the
     user's and is kept byte for byte — TRANSP, every VALARM, and whatever DAVx⁵
     adds when Android saves (a VTIMEZONE, X- properties, SEQUENCE, reordering).
     Only TOP-LEVEL VEVENT lines are ever touched: a VALARM carries its own
     DESCRIPTION and (EMAIL alarms) SUMMARY, and editing those would rewrite the
     user's reminder with the film's synopsis.
  2. A marked event (TRANSP not TRANSPARENT) is never deleted. When it vanishes
     from the source it becomes STATUS:CANCELLED, and the owner is told. If it
     comes back, STATUS returns to CONFIRMED. A MISSING TRANSP counts as marked:
     OPAQUE is RFC 5545's default, our creates always write TRANSPARENT, so a
     missing one means a client removed it — and keeping is the safe direction.
  3. Every write is conditional: If-None-Match: * on create, If-Match: <etag> on
     update and delete. A 412 means someone edited the event since we read it; it
     is skipped, counted, and picked up next run. It never fails the run.
  4. New events carry TRANSP:TRANSPARENT and no VALARM.

Comparison is by MEANING, not text. DAVx⁵ re-serialises the whole event when
Android saves it — times come back as TZID=Asia/Singapore, STATUS:CONFIRMED appears,
lines reorder. A text comparison would rewrite every event the owner ever tapped,
every run, and race hitome on every one of them. So times are compared as instants
(we WRITE them in UTC, which needs no VTIMEZONE of our own), STATUS defaults to
CONFIRMED when absent, and text is compared unescaped.

THE MASS-REMOVAL GUARD. A scraped page can break silently, and a parser that finds
nothing looks exactly like a source that cancelled everything. If a run would remove
(delete or cancel) more than half of the feed's upcoming events — and more than
GUARD_MIN of them — nothing at all is written and the run fails. It is measured
against what is IN THE CALENDAR rather than against last run's count, so it needs no
state file and does not trip when a source's window legitimately changes size (the
holidays feed covers one year in January and two by September). FEEDS_FORCE=1 is the
override for a removal that really is real.

Past events (ended before this run) are never updated, cancelled or restored — a
source naturally drops what has screened. A feed may PRUNE them: unmarked past events
older than `prune_after` are deleted; marked ones are kept forever as the record of
what the owner actually went to.

Env (all optional):
  FEEDS_DRY_RUN=1      decide everything, print it, write nothing
  FEEDS_FORCE=1        let a run past the mass-removal guard
  FEEDS_DAV_BASE       http://host:port/<user>/ — test seam; default asks docker
                       for the radicale container's IP
  FEEDS_DAV_SECRET     path to base64(user:password); default afterimage/dav-secret
  FEEDS_NOTIFY_CMD     the notifier to exec; default feeds.notify.sh beside this file
"""

import base64
import dataclasses
import datetime as dt
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

REPO = "/zpool/catallenya"
HERE = os.path.dirname(os.path.abspath(__file__))
DAV_USER = "carrein"
SGT = ZoneInfo("Asia/Singapore")

# What the feed writes. DTSTAMP is housekeeping (RFC 5545 requires one, and it is
# refreshed whenever we write); DURATION is listed so a client that turned DTEND into
# DURATION does not leave both on the event after our next write. Nothing else.
OWNED = ("SUMMARY", "DTSTART", "DTEND", "DURATION", "URL", "DESCRIPTION", "STATUS", "DTSTAMP")
# What decides "has this event changed". DTSTAMP is not here: a fresh stamp alone would
# rewrite every event every run and bump every ETag.
COMPARED = ("SUMMARY", "START", "END", "URL", "DESCRIPTION", "STATUS")

GUARD_MIN = 5


def log(msg):
    print(msg, file=sys.stderr, flush=True)


@dataclasses.dataclass
class Event:
    """One event as a reader sees it. `start`/`end` are both dates (all-day, `end`
    exclusive) or both aware datetimes. `adopt_key`, when set, lets an event with a
    NEW uid take over an existing event that has no match by uid but the same key —
    how a Filmhouse showing keeps its event when it sells out and loses its booking
    number. The reader also supplies `Feed.key_of` to compute the key from a server
    event."""
    uid: str
    summary: str
    start: object
    end: object
    url: str = ""
    description: str = ""
    adopt_key: object = None


@dataclasses.dataclass
class Feed:
    name: str            # short label for logs and the notification
    collection: str      # CalDAV collection under carrein/
    display_name: str
    color: str           # #RRGGBBAA, Apple's calendar-color property
    prodid: str
    uid_prefix: str      # the ONLY events this feed ever touches
    # May an existing event that the source no longer lists be removed? Called with
    # the server event's start; default yes. holidays answers only for years it has
    # fresh data for.
    in_scope: object = None
    prune_after: object = None   # timedelta: delete unmarked past events this old
    key_of: object = None        # Server event -> adopt key, see Event.adopt_key


# --- iCalendar, as little as this needs ----------------------------------------

def ics_escape(s):
    return s.replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\n", "\\n")


def ics_unescape(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            out.append("\n" if n in "nN" else n)
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


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


def logical_lines(text):
    """[(raw, unfolded)] — `raw` is the line exactly as stored, continuation lines and
    line ending included, so a line we do not own can be written back untouched."""
    out = []
    for phys in text.splitlines(keepends=True):
        if phys[:1] in (" ", "\t") and out:
            raw, logical = out[-1]
            out[-1] = (raw + phys, logical + phys[1:].rstrip("\r\n"))
        else:
            out.append((phys, phys.rstrip("\r\n")))
    return out


def split_prop(line):
    """'DTSTART;TZID=Asia/Singapore:20261013T164500' -> ('DTSTART', {'TZID': ...}, value)"""
    head, _, value = line.partition(":")
    # A quoted parameter value may itself contain ':' — rare, and never in a name.
    while head.count('"') % 2:
        more, _, value = value.partition(":")
        head += ":" + more
    name, *params = head.split(";")
    pd = {}
    for p in params:
        k, _, v = p.partition("=")
        pd[k.upper()] = v.strip('"')
    return name.upper(), pd, value


def parse_time(params, value):
    """A DTSTART/DTEND value as a date (all-day) or an aware datetime."""
    if params.get("VALUE", "").upper() == "DATE" or (len(value) == 8 and value.isdigit()):
        return dt.date(int(value[:4]), int(value[4:6]), int(value[6:8]))
    naive = dt.datetime.strptime(value.rstrip("Z"), "%Y%m%dT%H%M%S")
    if value.endswith("Z"):
        return naive.replace(tzinfo=dt.timezone.utc)
    tzid = params.get("TZID")
    try:
        return naive.replace(tzinfo=ZoneInfo(tzid) if tzid else SGT)
    except (ZoneInfoNotFoundError, ValueError):
        # A TZID we cannot resolve (Windows names, a custom VTIMEZONE). Floating in SGT
        # is the honest guess; if it is wrong the comparison differs and we rewrite the
        # time in UTC, which is the self-healing direction.
        return naive.replace(tzinfo=SGT)


def parse_duration(value):
    sign = -1 if value.startswith("-") else 1
    v = value.lstrip("+-").lstrip("P")
    days = secs = 0
    num = ""
    in_time = False
    for c in v:
        if c == "T":
            in_time = True
        elif c.isdigit():
            num += c
        else:
            n = int(num or 0)
            num = ""
            if c == "W":
                days += 7 * n
            elif c == "D":
                days += n
            elif c == "H" and in_time:
                secs += 3600 * n
            elif c == "M" and in_time:
                secs += 60 * n
            elif c == "S" and in_time:
                secs += n
    return sign * dt.timedelta(days=days, seconds=secs)


def fmt_time(name, t):
    if isinstance(t, dt.datetime):
        return f"{name}:{t.astimezone(dt.timezone.utc):%Y%m%dT%H%M%SZ}"
    return f"{name};VALUE=DATE:{t:%Y%m%d}"


def instant(t):
    """Comparable form: dates stay dates, datetimes become UTC."""
    return t.astimezone(dt.timezone.utc) if isinstance(t, dt.datetime) else t


class ServerEvent:
    """The top-level VEVENT of one stored object, read for comparison. Lines inside a
    VALARM (or any other nested component) are never read as the event's own."""

    def __init__(self, text):
        self.text = text
        self.props = {}
        stack = []
        for _, line in logical_lines(text):
            upper = line.upper()
            if upper.startswith("BEGIN:"):
                stack.append(upper[6:])
                continue
            if upper.startswith("END:"):
                if stack:
                    stack.pop()
                continue
            if stack == ["VCALENDAR", "VEVENT"]:
                name, params, value = split_prop(line)
                self.props.setdefault(name, (params, value))
        p = self.props
        self.uid = p.get("UID", ({}, ""))[1]
        self.start = parse_time(*p["DTSTART"]) if "DTSTART" in p else None
        if "DTEND" in p:
            self.end = parse_time(*p["DTEND"])
        elif "DURATION" in p and self.start is not None:
            self.end = self.start + parse_duration(p["DURATION"][1])
        elif isinstance(self.start, dt.date) and not isinstance(self.start, dt.datetime):
            self.end = self.start + dt.timedelta(days=1)
        else:
            self.end = self.start
        self.summary = ics_unescape(p.get("SUMMARY", ({}, ""))[1])
        self.url = p.get("URL", ({}, ""))[1]
        self.description = ics_unescape(p.get("DESCRIPTION", ({}, ""))[1])
        self.status = (p.get("STATUS", ({}, ""))[1] or "CONFIRMED").upper()
        self.marked = p.get("TRANSP", ({}, "OPAQUE"))[1].upper() != "TRANSPARENT"

    def essence(self):
        return (self.summary, instant(self.start), instant(self.end),
                self.url, self.description, self.status)


def owned_lines(ev, status, stamp):
    lines = [f"DTSTAMP:{stamp}", fmt_time("DTSTART", ev.start), fmt_time("DTEND", ev.end),
             f"SUMMARY:{ics_escape(ev.summary)}"]
    if ev.url:
        lines.append(f"URL:{ev.url}")
    if ev.description:
        lines.append(f"DESCRIPTION:{ics_escape(ev.description)}")
    lines.append(f"STATUS:{status}")
    return lines


def essence_of(ev, status="CONFIRMED"):
    return (ev.summary, instant(ev.start), instant(ev.end), ev.url, ev.description, status)


def create_text(feed, ev, stamp):
    lines = ["BEGIN:VCALENDAR", "VERSION:2.0", f"PRODID:{feed.prodid}", "BEGIN:VEVENT",
             f"UID:{ev.uid}", *owned_lines(ev, "CONFIRMED", stamp),
             "TRANSP:TRANSPARENT", "END:VEVENT", "END:VCALENDAR"]
    return "".join(fold(l) + "\r\n" for l in lines)


def splice(text, new_lines, replace=OWNED):
    """Swap the top-level VEVENT lines named in `replace` for `new_lines`, keeping
    every other byte of the stored object. The new lines go where the first replaced
    line was (else just after UID, else after BEGIN:VEVENT), so a re-run of an
    unchanged splice is a no-op on layout too."""
    out, stack, inserted, anchor = [], [], False, None
    newline = "\r\n" if "\r\n" in text else "\n"
    block = "".join(fold(l) + newline for l in new_lines)
    for raw, line in logical_lines(text):
        upper = line.upper()
        top = stack == ["VCALENDAR", "VEVENT"]
        if upper.startswith("BEGIN:"):
            stack.append(upper[6:])
            if stack == ["VCALENDAR", "VEVENT"]:
                anchor = len(out) + 1
        elif upper.startswith("END:"):
            if top and not inserted:
                out.insert(anchor if anchor is not None else len(out), block)
                inserted = True
            if stack:
                stack.pop()
        elif top:
            name = split_prop(line)[0]
            if name in replace:
                if not inserted:
                    out.append(block)
                    inserted = True
                continue
            if name == "UID" and not inserted:
                anchor = len(out) + 1
        out.append(raw)
    return "".join(out)


# --- CalDAV ---------------------------------------------------------------------

class Conflict(Exception):
    """412: the object changed since we read it (or exists, on create)."""


class Dav:
    def __init__(self, collection):
        base = os.environ.get("FEEDS_DAV_BASE")
        if not base:
            ip = subprocess.run(
                ["docker", "inspect", "-f",
                 "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", "radicale"],
                check=True, capture_output=True, text=True).stdout.split()[0]
            base = f"http://{ip}:5232/{DAV_USER}/"
        secret = os.environ.get("FEEDS_DAV_SECRET", f"{REPO}/afterimage/dav-secret")
        with open(secret) as f:
            self.auth = f.read().strip()
        if not base64.b64decode(self.auth).decode().startswith(f"{DAV_USER}:"):
            raise RuntimeError(f"{secret} does not decode to user {DAV_USER}")
        self.base = base.rstrip("/") + f"/{collection}/"

    def req(self, method, url, body=None, headers=None, ok=(200, 201, 204, 207)):
        h = {"Authorization": f"Basic {self.auth}", **(headers or {})}
        data = body.encode() if isinstance(body, str) else body
        r = urllib.request.Request(url, data=data, headers=h, method=method)
        try:
            with urllib.request.urlopen(r, timeout=30) as resp:
                return resp.status, resp.read().decode(), resp.headers
        except urllib.error.HTTPError as e:
            with e:
                if e.code == 412:
                    raise Conflict(f"{method} {url}") from None
                if e.code in ok:
                    return e.code, e.read().decode(), e.headers
                raise RuntimeError(f"{method} {url} -> HTTP {e.code}") from None

    def ensure_collection(self, feed, dry_run):
        status, _, _ = self.req("PROPFIND", self.base, headers={"Depth": "0"}, ok=(207, 404))
        if status != 404:
            return False
        body = f"""<?xml version="1.0" encoding="utf-8"?>
<C:mkcalendar xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:I="http://apple.com/ns/ical/">
 <D:set><D:prop>
  <D:displayname>{feed.display_name}</D:displayname>
  <I:calendar-color>{feed.color}</I:calendar-color>
  <C:supported-calendar-component-set><C:comp name="VEVENT"/></C:supported-calendar-component-set>
 </D:prop></D:set>
</C:mkcalendar>"""
        if not dry_run:
            self.req("MKCALENDAR", self.base, body, {"Content-Type": "application/xml; charset=utf-8"})
        return True

    def names(self):
        """Every .ics object name in the collection. Radicale returns hrefs
        URL-encoded (@ -> %40), hence the unquote — without it every run rewrote
        every event."""
        status, xml, _ = self.req("PROPFIND", self.base, headers={"Depth": "1"}, ok=(207, 404))
        if status == 404:
            return []
        out = []
        for href in ET.fromstring(xml).iter("{DAV:}href"):
            name = urllib.parse.unquote(href.text.rstrip("/").rsplit("/", 1)[-1])
            if name.endswith(".ics"):
                out.append(name)
        return out

    def url(self, name):
        return self.base + urllib.parse.quote(name)

    def get(self, name):
        _, body, headers = self.req("GET", self.url(name))
        return body, headers.get("ETag")

    def create(self, name, text):
        self.req("PUT", self.url(name), text,
                 {"Content-Type": "text/calendar; charset=utf-8", "If-None-Match": "*"})

    def update(self, name, text, etag):
        self.req("PUT", self.url(name), text,
                 {"Content-Type": "text/calendar; charset=utf-8", "If-Match": etag})

    def delete(self, name, etag):
        self.req("DELETE", self.url(name), headers={"If-Match": etag})


# --- reconcile ------------------------------------------------------------------

def is_past(start, end, now):
    if isinstance(end, dt.datetime):
        return end <= now
    return end <= now.astimezone(SGT).date()


def when(t):
    """'Tue 13 Oct, 16:45' — the notification's detail line."""
    if isinstance(t, dt.datetime):
        t = t.astimezone(SGT)
        return f"{t:%a} {t.day} {t:%b}, {t:%H:%M}"
    return f"{t:%a} {t.day} {t:%b}"


def notify_cancelled(items):
    cmd = os.environ.get("FEEDS_NOTIFY_CMD", os.path.join(HERE, "feeds.notify.sh"))
    args = [cmd, "cancelled"] + [f"{s}\t{w}" for s, w in items]
    r = subprocess.run(args, capture_output=True, text=True, timeout=120)
    # The transport is best-effort and silent on success, so ANY output (or a non-zero
    # exit) is an alert that did not arrive — the same test disk.sh applies.
    if r.returncode != 0 or r.stdout.strip() or r.stderr.strip():
        raise RuntimeError(f"cancellation notice not delivered: {(r.stdout + r.stderr).strip()[:200]}")


def sync(feed, events, now=None):
    """Make the collection agree with `events`. Returns the one summary line."""
    dry = os.environ.get("FEEDS_DRY_RUN") == "1"
    force = os.environ.get("FEEDS_FORCE") == "1"
    now = now or dt.datetime.now(dt.timezone.utc)
    stamp = now.astimezone(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    verb = (lambda s: f"would {s}") if dry else (lambda s: s)

    uids = [e.uid for e in events]
    if len(set(uids)) != len(uids):
        raise RuntimeError("reader produced duplicate uids")
    if any(not e.uid.startswith(feed.uid_prefix) for e in events):
        raise RuntimeError(f"reader produced a uid outside {feed.uid_prefix}")

    dav = Dav(feed.collection)
    created_coll = dav.ensure_collection(feed, dry)
    have = {}  # name -> (ServerEvent, etag)
    if not (created_coll and dry):
        for name in dav.names():
            if not name.startswith(feed.uid_prefix):
                continue  # not ours: never read, never touched
            text, etag = dav.get(name)
            have[name] = (ServerEvent(text), etag)

    # Which stored object each wanted event lands on: its own uid, else an adoptable
    # orphan with the same key (see Event.adopt_key).
    plan = {}
    claimed = set()
    for ev in events:
        name = f"{ev.uid}.ics"
        if name in have:
            plan[ev.uid] = name
            claimed.add(name)
    if feed.key_of:
        orphans = {}
        for name, (se, _) in have.items():
            if name not in claimed:
                k = feed.key_of(se)
                if k is not None:
                    orphans.setdefault(k, name)
        for ev in events:
            if ev.uid not in plan and ev.adopt_key is not None and ev.adopt_key in orphans:
                name = orphans.pop(ev.adopt_key)
                plan[ev.uid] = name
                claimed.add(name)
                log(f"{ev.uid} adopts {name} (same {feed.name} key)")

    # What vanished, decided before anything is written so the guard sees all of it.
    removals = []  # (name, action) action in delete|cancel
    upcoming = 0
    in_scope = feed.in_scope or (lambda start: True)
    for name, (se, _) in sorted(have.items()):
        if se.start is None:
            log(f"leave {name}: no DTSTART, so it cannot be placed in time")
            continue
        past = is_past(se.start, se.end, now)
        if not past:
            upcoming += 1
        if name in claimed:
            continue
        if past:
            if (feed.prune_after is not None and not se.marked
                    and now - feed.prune_after >= _as_dt(se.end)):
                removals.append((name, "prune"))
            continue
        if not in_scope(se.start):
            continue
        if se.marked:
            if se.status != "CANCELLED":
                removals.append((name, "cancel"))
        else:
            removals.append((name, "delete"))

    removing = [n for n, a in removals if a in ("delete", "cancel")]
    if len(removing) > GUARD_MIN and len(removing) * 2 > upcoming and not force:
        raise RuntimeError(
            f"refusing to remove {len(removing)} of {upcoming} upcoming events — the source "
            f"may be broken rather than empty; nothing written (FEEDS_FORCE=1 if this is real)")

    created = updated = unchanged = deleted = cancelled = pruned = skipped = 0
    cancelled_items = []
    for ev in events:
        name = plan.get(ev.uid)
        try:
            if name is None:
                log(f"{verb('create')} {ev.uid} {ev.summary}")
                if not dry:
                    dav.create(f"{ev.uid}.ics", create_text(feed, ev, stamp))
                created += 1
                continue
            se, etag = have[name]
            if se.essence() == essence_of(ev):
                unchanged += 1
                continue
            log(f"{verb('update')} {name} {ev.summary}"
                + (" (restored)" if se.status == "CANCELLED" else ""))
            if not dry:
                dav.update(name, splice(se.text, owned_lines(ev, "CONFIRMED", stamp)), etag)
            updated += 1
        except Conflict:
            log(f"skip {ev.uid}: changed on the server since it was read (412); next run")
            skipped += 1

    for name, action in removals:
        se, etag = have[name]
        try:
            if action == "cancel":
                log(f"{verb('cancel')} {name} {se.summary} (marked, kept)")
                if not dry:
                    dav.update(name, splice(se.text, [f"DTSTAMP:{stamp}", "STATUS:CANCELLED"],
                                            replace=("DTSTAMP", "STATUS")), etag)
                cancelled += 1
                cancelled_items.append((se.summary, when(se.start)))
            else:
                log(f"{verb('delete')} {name} {se.summary}" + (" (past, pruned)" if action == "prune" else ""))
                if not dry:
                    dav.delete(name, etag)
                if action == "prune":
                    pruned += 1
                else:
                    deleted += 1
        except Conflict:
            log(f"skip {name}: changed on the server since it was read (412); next run")
            skipped += 1

    if cancelled_items and not dry:
        notify_cancelled(cancelled_items)

    parts = [f"{len(events)} events", f"{created} created", f"{updated} updated",
             f"{unchanged} unchanged", f"{deleted} deleted", f"{cancelled} cancelled"]
    if feed.prune_after is not None:
        parts.append(f"{pruned} pruned")
    if skipped:
        parts.append(f"{skipped} skipped (412)")
    tail = ", calendar created" if created_coll else ""
    return f"{'DRY RUN ' if dry else ''}ok: " + ", ".join(parts) + tail


def _as_dt(t):
    if isinstance(t, dt.datetime):
        return t
    return dt.datetime.combine(t, dt.time(), tzinfo=SGT)


def run(main):
    """Entry point shape every feed shares: exactly one line on stdout (what the ntfy
    courier quotes on failure), diagnostics on stderr, non-zero on any failure."""
    try:
        print(main())
    except Exception as e:  # noqa: BLE001 — the one line the courier quotes
        print(f"FAILED: {e}")
        sys.exit(1)
