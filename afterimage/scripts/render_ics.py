#!/usr/bin/env python3
"""Deterministic iCalendar renderer for the capture pipeline.

Reads a triage proposal (JSON on stdin) and writes one VEVENT .ics to stdout.
The model only ever produces *fields* — never raw iCalendar — so all the
escaping/folding/timezone correctness lives here, where it's testable without
an API call. Ported from the ad-hoc builders used earlier this session.

Timed events are emitted in **UTC** (converted from the inferred timezone via
zoneinfo) rather than TZID + a hand-rolled VTIMEZONE: UTC is DST-safe for any
IANA zone and displays correctly in every client. All-day events use VALUE=DATE.

Input is ONE EVENT object from the proposal's events[] array, not the whole
proposal. is_event lives at the top level of the proposal and is checked by the
triage before it ever gets here.

Event fields consumed (see afterimage.lib.sh for the schema):
  calendar, title, date (YYYY-MM-DD), end_date (YYYY-MM-DD|null),
  start_time (HH:MM|null), end_time (HH:MM|null), all_day, timezone (IANA),
  recurrence (none|yearly|monthly|weekly|daily), location, description

end_date makes the event a SPAN — one thing running across days (a market open
both days, a festival, a trip). It is NOT the same as two alternatives: those are
separate occasions the user picks one of, and they arrive as separate .ics files.
"""
import argparse
import datetime
import json
import sys
from zoneinfo import ZoneInfo

FREQ = {
    "yearly": "YEARLY",
    "monthly": "MONTHLY",
    "weekly": "WEEKLY",
    "daily": "DAILY",
}


def esc(s):
    """Escape a TEXT value per RFC 5545.

    CR is normalised to LF *before* the newline escape. Radicale's parser (vobject)
    treats a bare CR as a line terminator, so an unescaped CR in a model-supplied
    string injects sibling properties into the same VEVENT — RRULE:FREQ=DAILY turns
    a one-off into a permanent entry, BEGIN:VALARM schedules a push alarm, URL: plants
    a clickable link — none of which appear in the ntfy body the user approves.
    Escaping (rather than deleting) keeps the text lossless.
    """
    return (str(s).replace("\\", "\\\\").replace(";", "\\;")
            .replace(",", "\\,")
            .replace("\r\n", "\n").replace("\r", "\n")
            .replace("\n", "\\n"))


def fold(line):
    """Fold to <=75 octets, continuations prefixed with a single space."""
    raw = line.encode("utf-8")
    if len(raw) <= 75:
        return line
    out, cur = [], b""
    for ch in line:
        b = ch.encode("utf-8")
        limit = 75 if not out else 74  # continuation lines carry a leading space
        if len(cur) + len(b) > limit:
            out.append(cur.decode("utf-8"))
            cur = b""
        cur += b
    if cur:
        out.append(cur.decode("utf-8"))
    return "\r\n ".join(out)


def parse_hhmm(s):
    s = str(s or "").strip()
    for fmt in ("%H:%M", "%H%M"):
        try:
            t = datetime.datetime.strptime(s, fmt)
            return t.hour, t.minute
        except ValueError:
            continue
    return None


def build(p, uid, now_iso, duration_min):
    d = datetime.date.fromisoformat(p["date"])
    tzname = p.get("timezone") or "Asia/Singapore"
    try:
        tz = ZoneInfo(tzname)
    except Exception:
        tz, tzname = ZoneInfo("Asia/Singapore"), "Asia/Singapore"

    lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "CALSCALE:GREGORIAN",
             "PRODID:-//catallenya//capture//EN", "BEGIN:VEVENT", "UID:" + uid,
             "DTSTAMP:" + now_iso, "CREATED:" + now_iso, "LAST-MODIFIED:" + now_iso,
             "SEQUENCE:0", "STATUS:CONFIRMED"]

    # The LAST day of the span, defaulting to the only day. A value that will not
    # parse, or one earlier than the start, is ignored rather than trusted — the
    # gate rejects those before they get here, but this renderer is also run
    # directly by the tests and by hand.
    end_d = d
    if p.get("end_date"):
        try:
            parsed = datetime.date.fromisoformat(str(p["end_date"]))
            if parsed >= d:
                end_d = parsed
        except (ValueError, TypeError):
            pass

    time = None if p.get("all_day") else parse_hhmm(p.get("start_time"))
    if time is None:
        # all-day (or no usable time): floating DATE values, no timezone.
        # DTEND is EXCLUSIVE in iCalendar, so a span ending on the 30th must say
        # the 31st — the same +1 a single-day event already needed.
        lines.append("DTSTART;VALUE=DATE:" + d.strftime("%Y%m%d"))
        lines.append("DTEND;VALUE=DATE:" + (end_d + datetime.timedelta(days=1)).strftime("%Y%m%d"))
        lines.append("TRANSP:TRANSPARENT")
    else:
        start_local = datetime.datetime(d.year, d.month, d.day, time[0], time[1], tzinfo=tz)
        # Prefer an explicit end time from the screenshot ("5:00 PM - 7:00 PM");
        # fall back to the default duration when only a start was shown. The end
        # time is placed on end_d, so a timed span ends on its last day.
        end_local = None
        if p.get("end_time"):
            try:
                eh, em = (int(x) for x in str(p["end_time"]).split(":")[:2])
                end_local = datetime.datetime(end_d.year, end_d.month, end_d.day,
                                              eh, em, tzinfo=tz)
                # Only a SAME-DAY end that lands at or before the start crossed
                # midnight. With an explicit end_date the day is already known, so
                # rolling forward again would add a spurious extra day.
                if end_local <= start_local and end_d == d:
                    end_local += datetime.timedelta(days=1)
            except (ValueError, TypeError):
                end_local = None
        if end_local is None:
            end_local = start_local + datetime.timedelta(minutes=duration_min)
            # A span with no end time still has to reach its last day.
            if end_d > d:
                end_local = datetime.datetime(end_d.year, end_d.month, end_d.day,
                                              start_local.hour, start_local.minute,
                                              tzinfo=tz) + datetime.timedelta(minutes=duration_min)
        z = lambda dt: dt.astimezone(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        lines.append("DTSTART:" + z(start_local))
        lines.append("DTEND:" + z(end_local))
        lines.append("TRANSP:OPAQUE")

    rec = p.get("recurrence", "none")
    if rec in FREQ:
        lines.append("RRULE:FREQ=" + FREQ[rec])

    lines.append("SUMMARY:" + esc(p.get("title", "Untitled")))
    if p.get("location"):
        lines.append("LOCATION:" + esc(p["location"]))
    if p.get("description"):
        lines.append("DESCRIPTION:" + esc(p["description"]))

    lines += ["END:VEVENT", "END:VCALENDAR", ""]
    return "\r\n".join(fold(x) if x else x for x in lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--uid", required=True)
    ap.add_argument("--now", required=True, help="DTSTAMP, e.g. 20260725T060000Z")
    ap.add_argument("--duration-min", type=int, default=60)
    a = ap.parse_args()
    p = json.load(sys.stdin)
    # No is_event check: this receives a single event from events[], which by
    # construction is one. The flag is a property of the proposal, not the event,
    # and the triage gates on it before the fan-out.
    sys.stdout.write(build(p, a.uid, a.now, a.duration_min))


if __name__ == "__main__":
    main()
