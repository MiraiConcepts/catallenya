"""Offline suite for the calendar feeds: the shared sink and the Filmhouse reader.

The sink runs against FakeDav, an in-process CalDAV server that keeps objects in a
dict and enforces ETags exactly where Radicale does (If-Match / If-None-Match ->
412). Nothing here touches docker, Radicale or ntfy: the notifier is a stub that
records its arguments.

Every sink case is a promise made to the hitome session on 2026-10-12 (see the
header of feeds_sink.py); the Filmhouse cases run the reader over a saved copy of
the real page.
"""

import datetime as dt
import hashlib
import http.server
import importlib.util
import os
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
FEEDS = os.path.dirname(HERE)
sys.path.insert(0, FEEDS)
import feeds_sink as sink  # noqa: E402


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(FEEDS, file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


filmhouse = load("filmhouse", "filmhouse.sync.py")

NOW = dt.datetime(2026, 10, 12, 4, 0, tzinfo=dt.timezone.utc)  # Mon 12:00 SGT
SGT = sink.SGT


class FakeDav:
    """Objects live in self.store[name] = text. `fail_next[(method, name)]` makes
    someone else edit (or create) that object just before our next such request
    arrives — an edit landing between our GET and our write. Whether that turns into
    a 412 is then up to the preconditions the sink actually sent, so dropping
    If-Match / If-None-Match from the sink fails these tests."""

    def __init__(self):
        self.store = {}
        self.collection = False
        self.fail_next = set()
        self.writes = []  # (method, name)
        fake = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _name(self):
                path = urllib.parse.unquote(urllib.parse.urlparse(self.path).path)
                parts = [p for p in path.split("/") if p]
                return parts[2] if len(parts) > 2 else None

            def _send(self, code, body=b"", headers=None):
                self.send_response(code)
                for k, v in (headers or {}).items():
                    self.send_header(k, v)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _body(self):
                return self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()

            def do_PROPFIND(self):
                if not fake.collection:
                    return self._send(404)
                hrefs = [f"<D:response><D:href>/carrein/test/</D:href></D:response>"]
                if self.headers.get("Depth") == "1":
                    for n in fake.store:
                        hrefs.append(f"<D:response><D:href>/carrein/test/"
                                     f"{urllib.parse.quote(n)}</D:href></D:response>")
                xml = f'<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">{"".join(hrefs)}</D:multistatus>'
                self._send(207, xml.encode())

            def do_MKCALENDAR(self):
                self._body()
                fake.collection = True
                self._send(201)

            def do_GET(self):
                n = self._name()
                if n not in fake.store:
                    return self._send(404)
                self._send(200, fake.store[n].encode(), {"ETag": fake.etag(n)})

            def _precondition(self, method, n):
                if (method, n) in fake.fail_next:
                    fake.fail_next.discard((method, n))
                    fake.store[n] = fake.store.get(n, CONCURRENT).replace(
                        "END:VEVENT", "X-EDITED-ELSEWHERE:1\r\nEND:VEVENT")
                im, inm = self.headers.get("If-Match"), self.headers.get("If-None-Match")
                if inm == "*" and n in fake.store:
                    return False
                if im is not None and (n not in fake.store or im != fake.etag(n)):
                    return False
                return True

            def do_PUT(self):
                n, body = self._name(), self._body()
                if not self._precondition("PUT", n):
                    return self._send(412)
                fake.store[n] = body
                fake.writes.append(("PUT", n))
                self._send(201)

            def do_DELETE(self):
                n = self._name()
                if not self._precondition("DELETE", n):
                    return self._send(412)
                fake.store.pop(n, None)
                fake.writes.append(("DELETE", n))
                self._send(204)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.server.serve_forever, args=(0.05,), daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}/carrein/"

    def etag(self, n):
        return '"' + hashlib.sha1(self.store[n].encode()).hexdigest() + '"'

    def close(self):
        self.server.shutdown()
        self.server.server_close()


CONCURRENT = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:someone-else\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

FEED = sink.Feed(name="test", collection="test", display_name="Test", color="#000000FF",
                 prodid="-//test//EN", uid_prefix="t-")


def ev(uid, summary, start, minutes=120, **kw):
    return sink.Event(uid=f"t-{uid}", summary=summary, start=start,
                      end=start + dt.timedelta(minutes=minutes), **kw)


def at(day, hh, mm=0):
    return dt.datetime(2026, 10, day, hh, mm, tzinfo=SGT)


def mark(text, alarm=None):
    """What hitome does on +: TRANSP -> OPAQUE, and a VALARM."""
    text = text.replace("TRANSP:TRANSPARENT", "TRANSP:OPAQUE")
    alarm = alarm or ("BEGIN:VALARM\r\nACTION:DISPLAY\r\nDESCRIPTION:Reminder\r\n"
                      "TRIGGER:-PT30M\r\nEND:VALARM\r\n")
    return text.replace("END:VEVENT", alarm + "END:VEVENT")


class SinkCase(unittest.TestCase):
    def setUp(self):
        self.dav = FakeDav()
        self.tmp = tempfile.TemporaryDirectory()
        self.notes = os.path.join(self.tmp.name, "notes")
        stub = os.path.join(self.tmp.name, "notify")
        with open(stub, "w") as f:
            f.write(f'#!/bin/sh\nfor a in "$@"; do printf "%s\\n" "$a"; done >> "{self.notes}"\n')
        os.chmod(stub, 0o755)
        secret = os.path.join(self.tmp.name, "secret")
        with open(secret, "w") as f:
            f.write("Y2FycmVpbjpwdw==")  # carrein:pw
        self.env = {"FEEDS_DAV_BASE": self.dav.base, "FEEDS_DAV_SECRET": secret,
                    "FEEDS_NOTIFY_CMD": stub}
        self.old = {k: os.environ.get(k) for k in [*self.env, "FEEDS_FORCE", "FEEDS_DRY_RUN"]}
        os.environ.update(self.env)
        os.environ.pop("FEEDS_FORCE", None)
        os.environ.pop("FEEDS_DRY_RUN", None)

    def tearDown(self):
        for k, v in self.old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.dav.close()
        self.tmp.cleanup()

    def sync(self, events, feed=FEED, now=NOW):
        self.dav.writes.clear()
        return sink.sync(feed, events, now=now)

    def obj(self, uid):
        return self.dav.store[f"t-{uid}.ics"]

    def notes_text(self):
        if not os.path.exists(self.notes):
            return ""
        with open(self.notes) as f:
            return f.read()


class SinkContract(SinkCase):
    # --- the five cases hitome asked for ------------------------------------

    def test_marked_event_keeps_transp_and_alarm_when_time_and_title_change(self):
        self.sync([ev("a", "Film", at(13, 16, 45))])
        self.dav.store["t-a.ics"] = mark(self.obj("a"))
        line = self.sync([ev("a", "Film [4K]", at(13, 18, 0))])
        self.assertIn("1 updated", line)
        text = self.obj("a")
        self.assertIn("TRANSP:OPAQUE", text)
        self.assertIn("BEGIN:VALARM", text)
        self.assertIn("DESCRIPTION:Reminder", text)
        self.assertIn("SUMMARY:Film [4K]", text)
        self.assertIn("DTSTART:20261013T100000Z", text)
        self.assertEqual(text.count("DTSTART"), 1)

    def test_marked_event_that_vanishes_is_cancelled_not_deleted(self):
        self.sync([ev("a", "Film", at(13, 16, 45)), ev("b", "Other", at(14, 17))])
        self.dav.store["t-a.ics"] = mark(self.obj("a"))
        line = self.sync([ev("b", "Other", at(14, 17))])
        self.assertIn("1 cancelled", line)
        self.assertIn("STATUS:CANCELLED", self.obj("a"))
        self.assertIn("TRANSP:OPAQUE", self.obj("a"))
        self.assertIn("BEGIN:VALARM", self.obj("a"))
        self.assertIn("Film\tTue 13 Oct, 16:45", self.notes_text())

    def test_unmarked_event_that_vanishes_is_deleted(self):
        self.sync([ev("a", "Film", at(13, 16, 45)), ev("b", "Other", at(14, 17))])
        line = self.sync([ev("b", "Other", at(14, 17))])
        self.assertIn("1 deleted", line)
        self.assertNotIn("t-a.ics", self.dav.store)
        self.assertEqual(self.notes_text(), "")

    def test_412_on_update_is_skipped_and_the_run_succeeds(self):
        self.sync([ev("a", "Film", at(13, 16, 45))])
        self.dav.fail_next.add(("PUT", "t-a.ics"))
        line = self.sync([ev("a", "Film", at(13, 18))])
        self.assertIn("1 skipped (412)", line)
        self.assertTrue(line.startswith("ok:"))
        self.assertIn("X-EDITED-ELSEWHERE", self.obj("a"))  # their edit, not overwritten
        self.assertIn("DTSTART:20261013T084500Z", self.obj("a"))
        self.assertIn("1 updated", self.sync([ev("a", "Film", at(13, 18))]))

    def test_email_alarm_with_its_own_summary_does_not_trigger_a_rewrite(self):
        self.sync([ev("a", "Film", at(13, 16, 45))])
        self.dav.store["t-a.ics"] = mark(self.obj("a"), alarm=(
            "BEGIN:VALARM\r\nACTION:EMAIL\r\nSUMMARY:Go to the cinema\r\n"
            "DESCRIPTION:Leave now\r\nATTENDEE:mailto:a@example.com\r\n"
            "TRIGGER:-PT1H\r\nEND:VALARM\r\n"))
        line = self.sync([ev("a", "Film", at(13, 16, 45))])
        self.assertIn("1 unchanged", line)
        self.assertEqual(self.dav.writes, [])

    # --- the five added in review ------------------------------------------

    def test_davx5_reserialised_event_is_not_rewritten(self):
        self.sync([ev("a", "Film", at(13, 16, 45), url="https://x/1", description="Book: https://x/1")])
        # Android saved it: SGT local time with a VTIMEZONE, explicit CONFIRMED,
        # reordered lines, DAVx⁵'s own PRODID and X- properties, LF line endings.
        self.dav.store["t-a.ics"] = (
            "BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:DAVx5/4.4 ical4j/3.2\n"
            "BEGIN:VTIMEZONE\nTZID:Asia/Singapore\nBEGIN:STANDARD\nTZOFFSETFROM:+0800\n"
            "TZOFFSETTO:+0800\nDTSTART:19700101T000000\nEND:STANDARD\nEND:VTIMEZONE\n"
            "BEGIN:VEVENT\nDTSTAMP:20261012T050000Z\nUID:t-a\nSUMMARY:Film\n"
            "DTSTART;TZID=Asia/Singapore:20261013T164500\n"
            "DTEND;TZID=Asia/Singapore:20261013T184500\nSTATUS:CONFIRMED\n"
            "URL;VALUE=URI:https://x/1\nDESCRIPTION:Book: https://x/1\nTRANSP:OPAQUE\n"
            "X-MOZ-LASTACK:20261012T050000Z\nBEGIN:VALARM\nACTION:DISPLAY\n"
            "DESCRIPTION:Film\nTRIGGER:-PT15M\nEND:VALARM\nEND:VEVENT\nEND:VCALENDAR\n")
        line = self.sync([ev("a", "Film", at(13, 16, 45), url="https://x/1",
                             description="Book: https://x/1")])
        self.assertIn("1 unchanged", line)
        self.assertEqual(self.dav.writes, [])

    def test_alarm_description_survives_an_event_description_change(self):
        self.sync([ev("a", "Film", at(13, 16, 45), description="old")])
        self.dav.store["t-a.ics"] = mark(self.obj("a"))
        self.sync([ev("a", "Film", at(13, 16, 45), description="new text")])
        text = self.obj("a")
        self.assertIn("DESCRIPTION:new text", text)
        self.assertIn("DESCRIPTION:Reminder", text)
        self.assertEqual(text.count("DESCRIPTION:"), 2)

    def test_cancelled_event_that_reappears_is_restored(self):
        self.sync([ev("a", "Film", at(13, 16, 45)), ev("b", "Other", at(14, 17))])
        self.dav.store["t-a.ics"] = mark(self.obj("a"))
        self.sync([ev("b", "Other", at(14, 17))])
        line = self.sync([ev("a", "Film", at(13, 16, 45)), ev("b", "Other", at(14, 17))])
        self.assertIn("1 updated", line)
        self.assertIn("STATUS:CONFIRMED", self.obj("a"))
        self.assertNotIn("CANCELLED", self.obj("a"))
        self.assertIn("TRANSP:OPAQUE", self.obj("a"))
        self.assertIn("BEGIN:VALARM", self.obj("a"))

    def test_guard_refuses_a_mass_removal_and_writes_nothing(self):
        many = [ev(str(i), f"Film {i}", at(13 + i % 5, 10 + i)) for i in range(10)]
        self.sync(many)
        before = dict(self.dav.store)
        with self.assertRaisesRegex(RuntimeError, "refusing to remove 9 of 10"):
            self.sync(many[:1])
        self.assertEqual(self.dav.writes, [])
        self.assertEqual(self.dav.store, before)
        os.environ["FEEDS_FORCE"] = "1"
        self.assertIn("9 deleted", self.sync(many[:1]))

    def test_412_on_delete_is_skipped(self):
        self.sync([ev("a", "Film", at(13, 16, 45)), ev("b", "Other", at(14, 17))])
        self.dav.fail_next.add(("DELETE", "t-a.ics"))
        line = self.sync([ev("b", "Other", at(14, 17))])
        self.assertIn("1 skipped (412)", line)
        self.assertIn("t-a.ics", self.dav.store)

    def test_412_on_create_is_skipped(self):
        self.dav.collection = True
        self.dav.fail_next.add(("PUT", "t-a.ics"))
        line = self.sync([ev("a", "Film", at(13, 16, 45))])
        self.assertIn("1 skipped (412)", line)
        self.assertIn("UID:someone-else", self.dav.store["t-a.ics"])  # not clobbered

    # --- the rest of the contract -------------------------------------------

    def test_new_events_are_transparent_confirmed_and_carry_no_alarm(self):
        self.sync([ev("a", "Film", at(13, 16, 45), url="https://b/1", description="Book: https://b/1")])
        text = self.obj("a")
        for line in ("TRANSP:TRANSPARENT", "STATUS:CONFIRMED", "URL:https://b/1",
                     "DTSTART:20261013T084500Z", "DTEND:20261013T104500Z", "UID:t-a"):
            self.assertIn(line, text)
        self.assertNotIn("VALARM", text)

    def test_missing_transp_counts_as_marked(self):
        self.sync([ev("a", "Film", at(13, 16, 45)), ev("b", "Other", at(14, 17))])
        self.dav.store["t-a.ics"] = self.obj("a").replace("TRANSP:TRANSPARENT\r\n", "")
        self.sync([ev("b", "Other", at(14, 17))])
        self.assertIn("STATUS:CANCELLED", self.obj("a"))

    def test_foreign_events_are_never_touched(self):
        self.sync([ev("a", "Film", at(13, 16, 45))])
        self.dav.store["mine.ics"] = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:mine\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        self.sync([ev("a", "Film", at(13, 16, 45))])
        self.sync([])
        self.assertIn("mine.ics", self.dav.store)

    def test_past_events_are_never_cancelled_or_deleted(self):
        self.sync([ev("old", "Old", at(10, 16))], now=dt.datetime(2026, 10, 9, tzinfo=dt.timezone.utc))
        self.sync([ev("a", "Film", at(13, 16))])
        self.assertIn("t-old.ics", self.dav.store)

    def test_scope_limits_what_may_be_removed(self):
        feed = sink.Feed(**{**FEED.__dict__, "in_scope": lambda s: s.day != 14})
        self.sync([ev("a", "A", at(13, 10)), ev("b", "B", at(14, 10))], feed=feed)
        self.sync([], feed=feed)
        self.assertNotIn("t-a.ics", self.dav.store)
        self.assertIn("t-b.ics", self.dav.store)

    def test_prune_deletes_unmarked_past_events_after_the_grace_and_keeps_marked(self):
        feed = sink.Feed(**{**FEED.__dict__, "prune_after": dt.timedelta(days=30)})
        early = dt.datetime(2026, 9, 1, tzinfo=dt.timezone.utc)
        self.sync([ev("x", "X", at(2, 10).replace(month=9)), ev("y", "Y", at(3, 10).replace(month=9))],
                  feed=feed, now=early)
        self.dav.store["t-y.ics"] = mark(self.obj("y"))
        self.sync([], feed=feed, now=dt.datetime(2026, 9, 20, tzinfo=dt.timezone.utc))
        self.assertIn("t-x.ics", self.dav.store)  # within 30 days
        line = self.sync([], feed=feed, now=NOW)
        self.assertIn("1 pruned", line)
        self.assertNotIn("t-x.ics", self.dav.store)
        self.assertIn("t-y.ics", self.dav.store)

    def test_adoption_keeps_the_event_when_the_uid_changes(self):
        feed = sink.Feed(**{**FEED.__dict__, "key_of": lambda se: (se.summary, sink.instant(se.start))})
        start = at(14, 19, 30)
        self.sync([ev("1813", "Film", start, adopt_key=("Film", sink.instant(start)))], feed=feed)
        self.dav.store["t-1813.ics"] = mark(self.obj("1813"))
        line = self.sync([ev("f186-x", "Film", start, adopt_key=("Film", sink.instant(start)),
                             description="Sold out")], feed=feed)
        self.assertIn("1 updated", line)
        self.assertIn("0 cancelled", line)
        self.assertNotIn("t-f186-x.ics", self.dav.store)
        self.assertIn("DESCRIPTION:Sold out", self.obj("1813"))
        self.assertIn("TRANSP:OPAQUE", self.obj("1813"))
        self.assertEqual(self.notes_text(), "")

    def test_dry_run_writes_nothing(self):
        self.sync([ev("a", "Film", at(13, 16, 45))])
        os.environ["FEEDS_DRY_RUN"] = "1"
        line = self.sync([ev("b", "Other", at(14, 17))])
        self.assertTrue(line.startswith("DRY RUN ok:"))
        self.assertEqual(self.dav.writes, [])

    def test_existing_holiday_objects_are_unchanged_by_the_migration(self):
        # Exactly what holidays.sync.py wrote before it moved onto the sink.
        self.dav.collection = True
        self.dav.store["t-2026-12-25.ics"] = (
            "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//catallenya//sg-holidays//EN\r\n"
            "BEGIN:VEVENT\r\nUID:t-2026-12-25\r\nDTSTAMP:20261012T023000Z\r\n"
            "DTSTART;VALUE=DATE:20261225\r\nDTEND;VALUE=DATE:20261226\r\n"
            "SUMMARY:Christmas Day\r\nTRANSP:TRANSPARENT\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
        day = dt.date(2026, 12, 25)
        line = self.sync([sink.Event(uid="t-2026-12-25", summary="Christmas Day", start=day,
                                     end=day + dt.timedelta(days=1))])
        self.assertIn("1 unchanged", line)
        self.assertEqual(self.dav.writes, [])

    def test_folded_and_escaped_text_compares_by_meaning(self):
        long = "A very long film title, with commas; and semicolons " * 3
        self.sync([ev("a", long.strip(), at(13, 16, 45), description="line one\nline two")])
        self.assertIn("\r\n ", self.obj("a"))  # folded on disk
        line = self.sync([ev("a", long.strip(), at(13, 16, 45), description="line one\nline two")])
        self.assertIn("1 unchanged", line)


class Notifier(unittest.TestCase):
    def run_notify(self, *items):
        script = os.path.join(FEEDS, "feeds.notify.sh")
        prog = (f'source "{script}"; notify_receipt() {{ printf "%s\\n--\\n%s" "$1" "$2"; }}; '
                'send_cancelled "$@"')
        return subprocess.run(["bash", "-c", prog, "x", *items], capture_output=True,
                              text=True, env={**os.environ, "NTFY_DISABLE": "1"})

    def test_one_cancelled_event_names_it(self):
        r = self.run_notify("The Violinist\tTue 13 Oct, 16:45")
        title, body = r.stdout.split("\n--\n")
        self.assertEqual(title, "Cancelled: The Violinist")
        self.assertIn("The Violinist", body)
        self.assertIn("Tue 13 Oct, 16:45", body)

    def test_several_are_counted(self):
        r = self.run_notify("A\tTue 13 Oct, 16:45", "B\tWed 14 Oct, 17:00")
        self.assertEqual(r.stdout.split("\n--\n")[0], "Cancelled: 2 Events")


class Filmhouse(unittest.TestCase):
    TODAY = dt.date(2026, 10, 12)

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(HERE, "fixtures", "filmhouse.films.html"), encoding="utf-8") as f:
            cls.events = filmhouse.events_from(f.read(), cls.TODAY)
        cls.by_uid = {e.uid: e for e in cls.events}

    def test_every_showing_on_the_page_is_read(self):
        self.assertEqual(len(self.events), 70)
        self.assertEqual(len({e.adopt_key[0] for e in self.events}), 29)
        self.assertEqual(len(self.by_uid), 70)

    def test_a_bookable_showing(self):
        e = self.by_uid["filmhouse-1813@hitome"]
        self.assertEqual(e.summary, "The Violinist")
        self.assertEqual(e.start, dt.datetime(2026, 10, 13, 16, 45, tzinfo=SGT))
        self.assertEqual(e.end - e.start, dt.timedelta(minutes=114))
        self.assertEqual(e.url, "https://filmhouse.sg/filmhouse-singapore/booknow/1813")
        self.assertEqual(e.description.splitlines(), [
            "Book: https://filmhouse.sg/filmhouse-singapore/booknow/1813",
            "Film: https://filmhouse.sg/film/195/the-violinist",
            "114 min · PG"])

    def test_tags_reach_the_title(self):
        self.assertEqual(self.by_uid["filmhouse-1835@hitome"].summary,
                         "Five Broken Cameras [Fundraiser] [Last Chance]")
        self.assertEqual(self.by_uid["filmhouse-1816@hitome"].summary, "The Invite [4K]")

    def test_sold_out_falls_back_to_the_film_page(self):
        e = next(e for e in self.events if e.summary.startswith("Fatherland [Sold Out]"))
        self.assertEqual(e.uid, "filmhouse-f186-20261014T1130Z@hitome")
        self.assertEqual(e.url, "https://filmhouse.sg/film/186/fatherland")
        self.assertTrue(e.description.startswith("Sold out\nFilm: https://filmhouse.sg/film/186/"))

    def test_an_offsite_booking_is_the_booking_link(self):
        e = next(e for e in self.events if e.summary.startswith("OSFF"))
        self.assertIn("&", e.summary)  # entities decoded
        self.assertTrue(e.summary.endswith("[Q&A]"))
        self.assertEqual(e.url, "https://osff-25oct.peatix.com/")
        self.assertTrue(e.uid.startswith("filmhouse-f218-"))

    def test_key_of_reads_back_what_the_reader_wrote(self):
        e = self.by_uid["filmhouse-1813@hitome"]
        text = sink.create_text(filmhouse.FEED, e, "20261012T000000Z")
        self.assertEqual(filmhouse.key_of(sink.ServerEvent(text)), e.adopt_key)

    def test_year_is_inferred_across_new_year(self):
        r = filmhouse.resolve_date
        self.assertEqual(r("Saturday 2nd January", dt.date(2026, 12, 20)), dt.date(2027, 1, 2))
        self.assertEqual(r("Monday 28th December", dt.date(2027, 1, 2)), dt.date(2026, 12, 28))
        with self.assertRaisesRegex(RuntimeError, "fits no year"):
            r("Monday 13th October", self.TODAY)  # 13 Oct 2026 is a Tuesday
        with self.assertRaisesRegex(RuntimeError, "unreadable"):
            r("13/10", self.TODAY)

    def test_a_redesigned_page_yields_nothing(self):
        self.assertEqual(filmhouse.events_from("<html><body>new site</body></html>", self.TODAY), [])


if __name__ == "__main__":
    unittest.main()
