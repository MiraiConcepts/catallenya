#!/usr/bin/env python3
"""Keep the "Filmhouse" calendar in Radicale in step with filmhouse.sg's listings.

Source: https://filmhouse.sg/films/ — WordPress with JACRO's Tapos ticketing plugin.
There is no public API (wp-json carries no film routes; JACRO's showtime feeds are
for operators), so this reads the page. One fetch per run: every film, every
showtime, the runtime and the rating are all on that one page.

What one card looks like (verified 2026-10-12, 29 films / 70 showtimes):

  <div class="jacro-event ...">
    <a class="liveeventtitle" href="http://filmhouse.sg/film/195/the-violinist">The Violinist</a>
    <div class="running-time"><span>2026</span><span>114mins</span><span>(PG)</span>...
    <ul class="performance-list-items">
      <div class="heading">Tuesday 13th October</div>
      <li class="4k lastchance">
        <a href="https://filmhouse.sg/filmhouse-singapore/booknow/1813" class="film_book_button">
          <span class="hover">Book</span><span class="time">4:45 pm</span></a>
        <div class="movietag"><span class="tag 4k">4K</span>...</div>
      </li>
      ...

A sold-out showing is `<a class="soldfilm_book_button">` with no href; an outside
booking (Peatix, for festival screenings) is an ordinary book button whose href
points off-site.

One event per showing, in its own collection so it can be toggled off. UID is the
BOOKING NUMBER (filmhouse-1813@hitome): JACRO's id for that showing, so a showing
moved to a new time keeps its event. A showing with no booking number (sold out, or
booked off-site) falls back to filmhouse-f<film>-<start>@hitome — and because a
showing that SELLS OUT loses its number, every event also carries an adopt key of
(film id, start): an event whose uid is new takes over an existing event with the
same key instead of the old one being cancelled and a duplicate created.

The page prints no year ("Tuesday 13th October"). The year is the one, within a year
of today, whose date is no more than a week past AND whose weekday matches the
heading. A heading that matches no year is a format change and fails the run.

Links: hitome opens URL on the web and the first https link in DESCRIPTION on
Android (DAVx⁵ does not expose URL), so both carry the BOOKING link; the film's page
is the second line. A sold-out showing has no booking link, so both fall back to
the film's page.

Past showings: the sink never touches them, except that unmarked ones are pruned 30
days after they end. Marked ones stay forever as the record of what was seen.

Env:
  FILMHOUSE_HTML   parse this file instead of fetching (tests)
"""

import datetime as dt
import html
import html.parser
import os
import re
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir
import feeds_sink as sink  # noqa: E402

PAGE = "https://filmhouse.sg/films/"
UID_PREFIX = "filmhouse-"
UID_SUFFIX = "@hitome"
DEFAULT_RUNTIME = 120  # minutes, when a card prints none
SGT = sink.SGT

# Showtime modifiers, keyed by their class (on the <li> and on each <span class="tag">).
TAGS = {"4k": "4K", "live-q-a": "Q&A", "q-a": "Q&A", "fundraiser": "Fundraiser",
        "lastchance": "Last Chance"}

FEED = sink.Feed(
    name="filmhouse", collection="filmhouse", display_name="Filmhouse",
    color="#3D6B73FF", prodid="-//catallenya//filmhouse//EN", uid_prefix=UID_PREFIX,
    prune_after=dt.timedelta(days=30),
    key_of=lambda se: key_of(se))


class Page(html.parser.HTMLParser):
    """Films and their showtimes, in page order. Tolerant of attribute order and
    whitespace; strict about the class names it keys on, so a redesign produces no
    showings (and a loud failure) rather than wrong ones."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.films = []
        self.film = None
        self.capture = None      # which text we are inside: title|running|heading|time|tag
        self.buf = ""
        self.heading = ""
        self.show = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        cls = (a.get("class") or "").split()
        if tag == "div" and "jacro-event" in cls:
            self.film = {"title": "", "href": "", "running": [], "shows": []}
            self.films.append(self.film)
        if self.film is None:
            return
        if tag == "a" and "liveeventtitle" in cls:
            self.film["href"] = a.get("href", "")
            self._start("title")
        elif tag == "div" and "running-time" in cls:
            self.film["_in_running"] = True
        elif tag == "span" and self.film.get("_in_running") and not cls:
            self._start("running")
        elif tag == "div" and "heading" in cls:
            self._start("heading")
        elif tag == "li" and self.heading:
            self.show = {"date": self.heading, "classes": cls, "href": None, "sold": False,
                         "time": "", "tags": []}
            self.film["shows"].append(self.show)
        elif tag == "a" and self.show is not None and (
                "film_book_button" in cls or "soldfilm_book_button" in cls):
            self.show["href"] = a.get("href")
            self.show["sold"] = "soldfilm_book_button" in cls
        elif tag == "span" and self.show is not None and "time" in cls:
            self._start("time")
        elif tag == "span" and self.show is not None and "tag" in cls:
            self.tag_token = next((c for c in cls if c != "tag"), "")
            self._start("tag")

    def handle_endtag(self, tag):
        if self.film is None:
            return
        if self.capture and tag in ("a", "span", "div"):
            text = " ".join(self.buf.split())
            what, self.capture = self.capture, None
            if what == "title":
                self.film["title"] = text
            elif what == "running":
                self.film["running"].append(text)
            elif what == "heading":
                self.heading = text
            elif what == "time":
                self.show["time"] = text
            elif what == "tag":
                self.show["tags"].append((self.tag_token, text))
            return
        if tag == "div" and self.film.get("_in_running"):
            self.film["_in_running"] = False
        elif tag == "li":
            self.show = None
        elif tag == "ul":
            self.heading = ""

    def handle_data(self, data):
        if self.capture:
            self.buf += data

    def _start(self, what):
        self.capture, self.buf = what, ""


def https(url):
    return re.sub(r"^http://", "https://", url or "")


def film_id(url):
    m = re.search(r"/film/(\d+)/", url or "")
    return m.group(1) if m else None


def key_of(se):
    """Adopt key of an event already in the calendar: (film id, start instant)."""
    m = re.search(r"https://filmhouse\.sg/film/(\d+)/", se.description)
    if not m or se.start is None:
        return None
    return (m.group(1), sink.instant(se.start))


def resolve_date(heading, today):
    m = re.fullmatch(r"([A-Za-z]+)\s+(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]+)", heading.strip())
    if not m:
        raise RuntimeError(f"unreadable date heading {heading!r}")
    weekday, day, month = m.group(1)[:3].title(), int(m.group(2)), m.group(3)[:3].title()
    mon = dt.datetime.strptime(month, "%b").month
    fits = []
    for y in (today.year - 1, today.year, today.year + 1):
        try:
            d = dt.date(y, mon, day)
        except ValueError:
            continue
        if today - dt.timedelta(days=7) <= d <= today + dt.timedelta(days=366) \
                and d.strftime("%a") == weekday:
            fits.append(d)
    if not fits:
        raise RuntimeError(f"date heading {heading!r} fits no year near {today}")
    return min(fits)


def resolve_time(text):
    return dt.datetime.strptime(text.strip().upper().replace(" ", ""), "%I:%M%p").time()


def events_from(page_html, today):
    p = Page()
    p.feed(page_html)
    out = []
    for f in p.films:
        title = html.unescape(f["title"])
        fid = film_id(f["href"])
        if not title or not fid:
            continue
        film_url = https(f["href"])
        runtime = next((int(m.group(1)) for r in f["running"]
                        if (m := re.fullmatch(r"(\d+)\s*mins?", r))), None)
        rating = next((r.strip("()") for r in f["running"] if re.fullmatch(r"\(.+\)", r)), "")
        if runtime is None:
            sink.log(f"{title}: no runtime on the card, assuming {DEFAULT_RUNTIME} min")
        for s in f["shows"]:
            if not s["time"]:
                continue
            start = dt.datetime.combine(resolve_date(s["date"], today), resolve_time(s["time"]),
                                        tzinfo=SGT)
            end = start + dt.timedelta(minutes=runtime or DEFAULT_RUNTIME)
            # A known modifier gets our spelling; an unknown one (a new badge the site
            # adds) keeps the site's own text rather than vanishing.
            tags = [TAGS.get(tok, text) for tok, text in s["tags"]]
            tags += [TAGS[c] for c in s["classes"] if c in TAGS]
            if s["sold"]:
                tags.append("Sold Out")
            seen = []
            for t in tags:
                if t and t not in seen:
                    seen.append(t)
            summary = title + "".join(f" [{t}]" for t in seen)

            booking = https(s["href"]) if s["href"] and not s["sold"] else ""
            m = re.search(r"/booknow/(\d+)", booking)
            if m:
                uid = f"{UID_PREFIX}{m.group(1)}{UID_SUFFIX}"
            else:
                uid = f"{UID_PREFIX}f{fid}-{start.astimezone(dt.timezone.utc):%Y%m%dT%H%MZ}{UID_SUFFIX}"
            facts = " · ".join(x for x in (f"{runtime} min" if runtime else "", rating) if x)
            lines = [f"Book: {booking}" if booking else "Sold out" if s["sold"] else "",
                     f"Film: {film_url}", facts]
            out.append(sink.Event(
                uid=uid, summary=summary, start=start, end=end,
                url=booking or film_url,
                description="\n".join(l for l in lines if l),
                adopt_key=(fid, start.astimezone(dt.timezone.utc))))
    return out


def fetch():
    path = os.environ.get("FILMHOUSE_HTML")
    if path:
        with open(path, encoding="utf-8") as f:
            return f.read()
    req = urllib.request.Request(PAGE, headers={
        "User-Agent": "catallenya-feeds/1 (personal calendar; one request a day)",
        "Accept": "text/html"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", "replace")


def main():
    today = dt.datetime.now(SGT).date()
    events = events_from(fetch(), today)
    if not events:
        raise RuntimeError("no showings found on the page — layout changed? nothing written")
    films = len({e.adopt_key[0] for e in events})
    return sink.sync(FEED, events).replace("ok: ", f"ok: {films} films, ", 1)


if __name__ == "__main__":
    sink.run(main)
