#!/usr/bin/env python3
"""
ebooks.inspect.py — everything the ebooks pipeline needs to know about a book file.

Stdlib only, no network except `cover`, no model. The shell scripts own the state
machine (staging, notifying, moving); this owns the questions that need a zip
parser or a string rule.

  inspect <file> <shelf>        integrity + metadata + draft name + duplicate check
  cover   <file> <scratch>      look for a better cover (EPUB only); saves the candidate
  apply-cover <epub> <image> <media-type>

Every subcommand prints ONE JSON object on stdout and exits 0 when it produced an
answer — including "this book is broken". A non-zero exit means the helper itself
failed, which the caller treats as "could not inspect", never as "fine".
"""

import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import unicodedata
import zipfile
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
MIN_EPUB_BYTES = 5 * 1024
NAME_MAX_BYTES = 180   # leaves headroom under the 255-byte filesystem limit

OPF = '{http://www.idpf.org/2007/opf}'
DC = '{http://purl.org/dc/elements/1.1/}'

# Characters Windows and Android refuse. A colon becomes a semicolon (the library's
# existing convention); the rest are dropped rather than substituted so a name never
# gains an underscore the shelf does not already use.
COLON_LIKE = re.compile(r'\s*[:·•]\s*')
ILLEGAL = re.compile(r'[<>"/\\|?*\x00-\x1f]')

# Roles that are not the author. A missing role counts as an author.
NOT_AUTHOR_ROLES = {'trl', 'edt', 'ill', 'pbl', 'bkp', 'ctb', 'fwd', 'intro', 'aui',
                    'com', 'cmp', 'pht', 'cov'}
HONORIFICS = re.compile(r'^(graf|dr\.?|prof\.?|sir|lord|lady|mr\.?|mrs\.?|ms\.?)\s+', re.I)


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()


def out(obj):
    print(json.dumps(obj, ensure_ascii=False))


# ---------------------------------------------------------------------------
# Reading a book
# ---------------------------------------------------------------------------

def read_epub(path):
    """Return (problem, title, creators[(name, role)], isbn). problem is '' when fine."""
    if os.path.getsize(path) < MIN_EPUB_BYTES:
        return 'FILE_TOO_SMALL', '', [], ''
    try:
        with zipfile.ZipFile(path) as z:
            bad = z.testzip()
            if bad:
                return 'EPUB_CORRUPT', '', [], ''
            container = ET.fromstring(z.read('META-INF/container.xml'))
            rootfile = container.find('.//{*}rootfile')
            opf_path = rootfile.get('full-path')
            root = ET.fromstring(z.read(opf_path))
    except (zipfile.BadZipFile, KeyError, ET.ParseError, AttributeError, OSError):
        return 'EPUB_CORRUPT', '', [], ''
    title_el = root.find('.//' + DC + 'title')
    title = (title_el.text or '') if title_el is not None else ''
    creators = [((e.text or ''), e.get(OPF + 'role')) for e in root.findall('.//' + DC + 'creator')]
    isbn = ''
    for e in root.findall('.//' + DC + 'identifier'):
        digits = re.sub(r'[^0-9Xx]', '', e.text or '')
        if len(digits) in (10, 13) and (e.get(OPF + 'scheme', '').upper() == 'ISBN'
                                        or (e.text or '').lower().startswith(('urn:isbn', 'isbn'))):
            isbn = digits
    return '', title, creators, isbn


def read_pdf(path):
    try:
        r = subprocess.run(['pdfinfo', path], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return 'PDF_UNREADABLE', '', []
    if r.returncode != 0:
        return 'PDF_UNREADABLE', '', []
    info = {}
    for line in r.stdout.splitlines():
        if ':' in line:
            k, v = line.split(':', 1)
            info[k.strip()] = v.strip()
    if info.get('Encrypted', '').lower().startswith('yes'):
        return 'PDF_ENCRYPTED', '', []
    def real(v):
        # pdfinfo prints the literal word for a missing field in some producers.
        return '' if v.strip().lower() in ('', 'not defined', 'untitled', 'unknown', 'null') else v
    author = real(info.get('Author', ''))
    return '', real(info.get('Title', '')), [(author, None)] if author else []


# ---------------------------------------------------------------------------
# Name rules. Deterministic: the same book gives the same draft, every time.
# Anything these rules cannot be sure of is a FLAG, never a guess.
# ---------------------------------------------------------------------------

def clean_author(raw):
    """One creator string -> list of 'First Last' names."""
    names = []
    # "Zweig, Stefan; Stone, Will" is two people joined by ';'. Split there first.
    for part in re.split(r'\s*;\s*', raw.strip()):
        part = part.strip(' ,;')
        if not part:
            continue
        # "Jean-Jacques Rousseau, Maurice Cranston (translator)": remove only the
        # contributor's own chunk, never the author sharing the string with them.
        part = re.sub(r',?\s*[^,;()]+\((translator|editor|illustrator|foreword|introduction)[^)]*\)',
                      '', part, flags=re.I).strip(' ,;')
        if not part:
            continue
        if part.count(',') == 1:
            last, first = [s.strip() for s in part.split(',')]
            if first and last:
                part = first + ' ' + last
        part = HONORIFICS.sub('', part)
        part = re.sub(r'\s*&\s*', ' and ', part)
        part = re.sub(r'\bE\.\s?M\.', 'E.M.', part)
        names.append(re.sub(r'\s+', ' ', part))
    return names


def portable(s):
    s = s.replace('’', "'").replace('‘', "'").replace('“', '"').replace('”', '"')
    s = unicodedata.normalize('NFC', s)
    s = COLON_LIKE.sub('; ', s)
    s = ILLEGAL.sub('', s)
    s = re.sub(r'\s+', ' ', s).strip()
    return s.rstrip('. ')


def clean_title(raw):
    """Strip decoration. Returns (title, flags)."""
    flags = []
    t = raw.strip()
    # "[E 01] • e" style series prefixes
    t = re.sub(r'^\[[^\]]*\]\s*[•·]?\s*', '', t)
    # trailing parenthetical decoration: (Oprah's Book Club), (Mark Harman 1998 Translation)
    stripped = re.sub(r'\s*\([^)]*\)\s*$', '', t)
    if stripped != t and stripped:
        t = stripped
    t = portable(t)
    # Things a rule cannot repair. The tap is the check.
    if re.search(r'_|\bisbn\b|anna.s archive|\.com\b|\[|\]|\b[0-9a-f]{16,}\b', t, re.I):
        flags.append('NAME_UNCLEAR')
    if not t:
        flags.append('NAME_UNCLEAR')
    return t, flags


def draft_name(title, creators):
    flags = []
    authors = []
    for raw, role in creators:
        if role and role.lower() in NOT_AUTHOR_ROLES:
            continue
        authors.extend(clean_author(raw))
    seen = set()
    authors = [a for a in authors if not (a.lower() in seen or seen.add(a.lower()))]
    t, tflags = clean_title(title)
    flags.extend(tflags)
    if not authors:
        flags.append('NO_AUTHOR')
    a = ' and '.join(authors)
    a = portable(a)
    if re.search(r'_|\[|\]|\.com\b', a):
        flags.append('NAME_UNCLEAR')
    stem = f'{t} - {a}' if a else t
    # Trim to the byte budget on a character boundary.
    while len(stem.encode('utf-8')) > NAME_MAX_BYTES:
        stem = stem[:-1]
    return stem.strip(), sorted(set(flags))


def norm_key(title, author_blob):
    """Collapse a book to letters+digits so 'Gift from the Sea' == 'Gift From The Sea'."""
    def n(s):
        s = unicodedata.normalize('NFKD', s).lower()
        return re.sub(r'[^a-z0-9]+', '', s)
    # Compare on the main title only: the library keeps some subtitles and drops others.
    main = re.split(r'\s*[;:]\s*', title, maxsplit=1)[0]
    return n(main), n(author_blob)


def find_duplicate(shelf, title_stem, sha):
    """Is this book already on the shelf — same bytes, or same title+author in any format?"""
    want_title, want_author = None, None
    if ' - ' in title_stem:
        want_title, want_author = norm_key(*title_stem.rsplit(' - ', 1))
    else:
        want_title = norm_key(title_stem, '')[0]
    for name in sorted(os.listdir(shelf)):
        p = os.path.join(shelf, name)
        if not os.path.isfile(p) or name.startswith('.'):
            continue
        if not name.lower().endswith(('.epub', '.pdf')):
            continue
        stem = name.rsplit('.', 1)[0]
        if ' - ' in stem:
            t, a = norm_key(*stem.rsplit(' - ', 1))
        else:
            t, a = norm_key(stem, '')[0], ''
        if t and t == want_title and (a == want_author or not want_author or not a):
            return name
    # byte-identical under a different name
    for name in sorted(os.listdir(shelf)):
        p = os.path.join(shelf, name)
        if os.path.isfile(p) and name.lower().endswith(('.epub', '.pdf')) \
                and os.path.getsize(p) == os.path.getsize(sha[1]) and sha256_of(p) == sha[0]:
            return name
    return ''


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

def cmd_inspect(path, shelf):
    ext = os.path.splitext(path)[1].lower().lstrip('.')
    res = {'name': os.path.basename(path), 'ext': ext, 'sha256': '', 'problem': '',
           'title': '', 'authors': [], 'draft': '', 'flags': [], 'duplicate_of': '', 'isbn': ''}
    if ext not in ('epub', 'pdf'):
        res['problem'] = 'UNSUPPORTED_TYPE'
        return out(res)
    if os.path.getsize(path) == 0:
        res['problem'] = 'FILE_EMPTY'
        return out(res)
    res['sha256'] = sha256_of(path)
    if ext == 'epub':
        problem, title, creators, isbn = read_epub(path)
    else:
        problem, title, creators = read_pdf(path)
        isbn = ''
    res['isbn'] = isbn
    if problem:
        res['problem'] = problem
        return out(res)
    res['title'] = title
    res['authors'] = [c for c, r in creators]
    stem, flags = draft_name(title, creators)
    if ext == 'pdf' and not title:
        # No metadata at all: fall back to the filename, but say so.
        stem = portable(os.path.splitext(os.path.basename(path))[0])
        flags = sorted(set(flags) | {'NAME_UNCLEAR'})
    res['draft'] = f'{stem}.{ext}'
    res['flags'] = flags
    dup = find_duplicate(shelf, stem, (res['sha256'], path))
    if dup:
        res['duplicate_of'] = dup
    out(res)


def load_cover_module():
    spec = importlib.util.spec_from_file_location('ebooks_cover', os.path.join(HERE, 'ebooks.cover.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def cmd_cover(path, scratch):
    """Dry-run the cover finder on ONE book. Never modifies the book."""
    res = {'action': 'NONE', 'reason': '', 'current_w': 0, 'current_h': 0,
           'online_w': 0, 'online_h': 0, 'source': '', 'image': '', 'media_type': ''}
    if not path.lower().endswith('.epub'):
        res['reason'] = 'PDF: no cover upgrade'
        return out(res)
    # Test seam: the offline suite must never touch the network. Never set in production.
    if os.environ.get('EBOOKS_COVER_OFFLINE') == '1':
        res['reason'] = 'cover lookup disabled'
        return out(res)
    cu = load_cover_module()
    os.makedirs(scratch, exist_ok=True)
    work = os.path.join(scratch, 'cover-work')
    os.makedirs(work, exist_ok=True)
    link = os.path.join(work, os.path.basename(path))
    if os.path.lexists(link):
        os.remove(link)
    os.symlink(os.path.abspath(path), link)
    # scan_collection prints progress to stdout; the caller wants one JSON object.
    real, sys.stdout = sys.stdout, sys.stderr
    try:
        results = cu.scan_collection(work, use_cache=False)
    finally:
        sys.stdout = real
    if not results:
        res['reason'] = 'scanner returned nothing'
        return out(res)
    r = results[0]
    res.update(action=r['action'], reason=r['reason'], current_w=r['current_w'],
               current_h=r['current_h'], online_w=r['online_w'], online_h=r['online_h'],
               source=r['online_source'])
    if r['action'] in ('UPGRADE', 'ADD', 'REPLACE') and r.get('image_data'):
        ext = '.png' if r['media_type'] == 'image/png' else '.jpeg'
        img = os.path.join(scratch, os.path.basename(path) + '.cover' + ext)
        with open(img, 'wb') as f:
            f.write(r['image_data'])
        res['image'] = img
        res['media_type'] = r['media_type']
    out(res)


def cmd_apply_cover(epub, image, media_type):
    cu = load_cover_module()
    with open(image, 'rb') as f:
        data = f.read()
    cu.set_epub_cover(epub, data, media_type)
    with zipfile.ZipFile(epub) as z:
        bad = z.testzip()
    if bad:
        out({'ok': False, 'reason': f'zip corruption in {bad}'})
        sys.exit(0)
    out({'ok': True})


def main():
    a = sys.argv[1:]
    try:
        if len(a) == 3 and a[0] == 'inspect':
            return cmd_inspect(a[1], a[2])
        if len(a) == 3 and a[0] == 'cover':
            return cmd_cover(a[1], a[2])
        if len(a) == 4 and a[0] == 'apply-cover':
            return cmd_apply_cover(a[1], a[2], a[3])
    except Exception as e:  # noqa: BLE001 — surfaced to the caller as a failure, not swallowed
        print(f'ebooks.inspect.py: {type(e).__name__}: {e}', file=sys.stderr)
        sys.exit(2)
    print(__doc__, file=sys.stderr)
    sys.exit(64)


if __name__ == '__main__':
    main()
