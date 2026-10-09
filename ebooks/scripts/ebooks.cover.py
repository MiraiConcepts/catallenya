#!/usr/bin/env python3
"""
EPUB Cover Upgrader — scans EPUBs, checks cover quality, fetches better covers from free APIs.

Usage:
    python3 cover_upgrade.py [folder]            # Dry run (report only)
    python3 cover_upgrade.py [folder] --apply    # Apply upgrades after confirmation
    python3 cover_upgrade.py [folder] --no-cache # Ignore cache, re-audit everything
    python3 cover_upgrade.py [folder] --files F  # Re-audit specific files (exact names)

Stdlib only — no pip installs required.
"""

import hashlib
import json
import os
import re
import struct
import sys
import tempfile
import time
import urllib.request
import urllib.error
import ssl
import zipfile
import xml.etree.ElementTree as ET

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
MIN_SHORT_SIDE = 600  # Minimum pixels on shorter side for "HQ"
API_DELAY = 1.0       # Seconds between API calls (rate-limit courtesy)
CACHE_FILE = '.cover_cache.json'
CACHE_VERSION = 2     # Bump to invalidate old filename-keyed caches
UPGRADE_DIR = '.cover_upgrades'  # Temp dir for cached upgrade images

# XML namespaces used in EPUB
NS = {
    'container': 'urn:oasis:names:tc:opendocument:xmlns:container',
    'opf': 'http://www.idpf.org/2007/opf',
    'dc': 'http://purl.org/dc/elements/1.1/',
}

# ---------------------------------------------------------------------------
# Cache — skip already-audited files whose content hasn't changed
# ---------------------------------------------------------------------------

def _file_hash(path):
    """SHA-256 of file contents."""
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()


def load_cache(folder):
    """Load cache from folder/.cover_cache.json. Returns dict keyed by content hash."""
    path = os.path.join(folder, CACHE_FILE)
    if os.path.exists(path):
        try:
            with open(path, 'r') as f:
                data = json.load(f)
            if data.get('_version') == CACHE_VERSION:
                return data
        except (json.JSONDecodeError, OSError):
            pass
    return {'_version': CACHE_VERSION}


def save_cache(folder, cache):
    """Save cache to folder/.cover_cache.json."""
    cache['_version'] = CACHE_VERSION
    path = os.path.join(folder, CACHE_FILE)
    with open(path, 'w') as f:
        json.dump(cache, f, indent=2, sort_keys=True)


# ---------------------------------------------------------------------------
# Phase A: Core EPUB utilities
# ---------------------------------------------------------------------------

def get_image_dimensions(data):
    """Get (width, height) from raw JPEG or PNG bytes. Returns (0, 0) on failure."""
    if len(data) < 24:
        return (0, 0)

    # PNG: fixed location in IHDR chunk
    if data[:8] == b'\x89PNG\r\n\x1a\n':
        w = struct.unpack('>I', data[16:20])[0]
        h = struct.unpack('>I', data[20:24])[0]
        return (w, h)

    # JPEG: scan for SOF markers
    if data[:2] == b'\xff\xd8':
        i = 2
        while i < len(data) - 9:
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            # SOF0, SOF1, SOF2, SOF3 (progressive, etc.)
            if marker in (0xC0, 0xC1, 0xC2, 0xC3):
                h = struct.unpack('>H', data[i + 5:i + 7])[0]
                w = struct.unpack('>H', data[i + 7:i + 9])[0]
                return (w, h)
            # Skip marker segment
            if 0xC0 <= marker <= 0xFE and marker not in (0xD0, 0xD1, 0xD2, 0xD3,
                                                          0xD4, 0xD5, 0xD6, 0xD7,
                                                          0xD8, 0xD9, 0xDA):
                seg_len = struct.unpack('>H', data[i + 2:i + 4])[0]
                i += 2 + seg_len
            else:
                i += 2

    return (0, 0)


def _is_placeholder(data, w, h):
    """Detect placeholder/blank images that aren't real book covers.
    Returns True if the image is likely a placeholder (e.g. 'image not available',
    Goodreads 'g' logo, blank proof pages, panoramic strips)."""
    if not data:
        return True
    # Tiny files are always placeholders (e.g. 599-byte Goodreads 'g' logo)
    if len(data) < 2000:
        return True
    # Book covers are portrait — reject extreme aspect ratios
    # Real covers: w/h ratio 0.4–1.0. Strips like 575x92 (ratio 6.25) are not covers.
    if w > 0 and h > 0:
        ratio = w / h
        if ratio > 1.2 or ratio < 0.3:
            return True
    # Very low bytes-per-pixel means nearly blank content
    # Real covers: JPEG >= 0.04 bpp, PNG >= 0.05 bpp
    # Placeholders: 0.007 bpp (blank page), 0.021 bpp ("image not available")
    pixels = w * h
    if pixels > 0:
        bpp = len(data) / pixels
        if bpp < 0.03:
            return True
    return False


def _find_opf_path(zf):
    """Locate the OPF file path inside an EPUB ZIP via container.xml."""
    container = ET.fromstring(zf.read('META-INF/container.xml'))
    rootfile = container.find('.//container:rootfile[@media-type="application/oebps-package+xml"]', NS)
    if rootfile is None:
        # Try without namespace (some EPUBs are non-conformant)
        for rf in container.iter():
            if rf.tag.endswith('rootfile') and rf.get('media-type') == 'application/oebps-package+xml':
                return rf.get('full-path')
        return None
    return rootfile.get('full-path')


def _find_cover_item(opf_root, opf_dir):
    """Find the cover image manifest item from OPF. Returns (item_element, href_in_zip) or (None, None)."""
    metadata = opf_root.find('opf:metadata', NS)
    manifest = opf_root.find('opf:manifest', NS)
    if metadata is None or manifest is None:
        return None, None

    cover_id = None

    # Method 1: <meta name="cover" content="item-id"/>
    for meta in metadata.findall('opf:meta', NS):
        if meta.get('name') == 'cover':
            cover_id = meta.get('content')
            break

    # Method 2: manifest item with properties="cover-image" (EPUB3)
    if cover_id is None:
        for item in manifest.findall('opf:item', NS):
            if 'cover-image' in (item.get('properties') or ''):
                cover_id = item.get('id')
                break

    if cover_id is None:
        return None, None

    # Find the manifest item
    for item in manifest.findall('opf:item', NS):
        if item.get('id') == cover_id:
            href = item.get('href')
            # href is relative to OPF directory
            full_path = os.path.join(opf_dir, href).replace('\\', '/')
            # Normalize (remove ./ etc.)
            full_path = os.path.normpath(full_path).replace('\\', '/')
            return item, full_path

    return None, None


def get_epub_cover_info(epub_path):
    """
    Extract cover info from an EPUB.
    Returns dict with keys: opf_path, opf_dir, cover_item_id, cover_href,
    cover_data, cover_width, cover_height, cover_media_type, isbn, title, author
    Returns None if EPUB can't be read.
    """
    try:
        with zipfile.ZipFile(epub_path, 'r') as zf:
            opf_path = _find_opf_path(zf)
            if not opf_path:
                return None

            opf_dir = os.path.dirname(opf_path)
            opf_bytes = zf.read(opf_path)
            opf_root = ET.fromstring(opf_bytes)

            # Extract metadata
            metadata = opf_root.find('opf:metadata', NS)
            title = ''
            author = ''
            isbn = ''

            if metadata is not None:
                title_el = metadata.find('dc:title', NS)
                if title_el is not None and title_el.text:
                    title = title_el.text.strip()

                creator_el = metadata.find('dc:creator', NS)
                if creator_el is not None and creator_el.text:
                    author = creator_el.text.strip()

                # Find ISBN
                for ident in metadata.findall('dc:identifier', NS):
                    text = (ident.text or '').strip()
                    scheme = ident.get('{http://www.idpf.org/2007/opf}scheme', '').upper()
                    if scheme == 'ISBN' or re.search(r'97[89]\d{10}', text.replace('-', '')):
                        clean = re.sub(r'[^0-9X]', '', text.upper())
                        if len(clean) in (10, 13):
                            isbn = clean
                            break

            # Find cover image
            cover_item, cover_zip_path = _find_cover_item(opf_root, opf_dir)

            cover_data = None
            cover_w, cover_h = 0, 0
            cover_media_type = ''
            cover_item_id = ''

            if cover_item is not None and cover_zip_path:
                cover_item_id = cover_item.get('id', '')
                cover_media_type = cover_item.get('media-type', '')
                try:
                    cover_data = zf.read(cover_zip_path)
                    cover_w, cover_h = get_image_dimensions(cover_data)
                except KeyError:
                    # Cover entry in OPF but file missing from ZIP
                    cover_data = None

            return {
                'opf_path': opf_path,
                'opf_dir': opf_dir,
                'opf_bytes': opf_bytes,
                'cover_item_id': cover_item_id,
                'cover_href': cover_zip_path or '',
                'cover_data': cover_data,
                'cover_width': cover_w,
                'cover_height': cover_h,
                'cover_media_type': cover_media_type,
                'isbn': isbn,
                'title': title,
                'author': author,
            }
    except (zipfile.BadZipFile, KeyError, ET.ParseError) as e:
        print(f"  WARNING: Could not read {os.path.basename(epub_path)}: {e}")
        return None


def set_epub_cover(epub_path, image_data, media_type):
    """
    Set/replace the cover image in an EPUB. Uses atomic write (temp file + rename).
    Preserves all existing files byte-for-byte. Handles both EPUB2 and EPUB3 metadata.
    """
    ext_map = {'image/jpeg': '.jpeg', 'image/png': '.png', 'image/gif': '.gif'}
    ext = ext_map.get(media_type, '.jpeg')

    with zipfile.ZipFile(epub_path, 'r') as zf:
        opf_path = _find_opf_path(zf)
        if not opf_path:
            raise ValueError("Cannot find OPF in EPUB")

        opf_dir = os.path.dirname(opf_path)
        opf_str = zf.read(opf_path).decode('utf-8')
        opf_root = ET.fromstring(zf.read(opf_path))

        cover_item, cover_zip_path = _find_cover_item(opf_root, opf_dir)

        if cover_item is not None and cover_zip_path:
            # Replace existing cover image
            new_cover_path = cover_zip_path
            cover_item_id = cover_item.get('id', '')
            old_media_type = cover_item.get('media-type', '')
            # Update media-type if needed (targeted to the specific item by id)
            if old_media_type != media_type and cover_item_id:
                opf_str = re.sub(
                    r'(<item[^>]*id="%s"[^>]*media-type=")%s(")'
                    % (re.escape(cover_item_id), re.escape(old_media_type)),
                    r'\g<1>%s\2' % media_type,
                    opf_str
                )
            # Ensure EPUB2 meta tag exists (macOS needs it for thumbnails)
            if 'name="cover"' not in opf_str:
                opf_str = re.sub(
                    r'(\s*)(</metadata>)',
                    r'\1  <meta name="cover" content="%s"/>\n\1\2' % cover_item_id,
                    opf_str
                )
        else:
            # No cover exists — need to add one
            # Determine image path relative to OPF
            images_dir = os.path.join(opf_dir, 'Images').replace('\\', '/')
            new_cover_path = os.path.join(images_dir, 'cover' + ext).replace('\\', '/')
            cover_href_relative = os.path.relpath(new_cover_path, opf_dir).replace('\\', '/')

            # Add manifest item (match existing indentation)
            manifest_item = '<item href="%s" id="cover-image" media-type="%s"/>' % (
                cover_href_relative, media_type)
            opf_str = re.sub(
                r'(\s*)(</manifest>)',
                r'\1  %s\n\1\2' % manifest_item,
                opf_str
            )

            # Add EPUB2 metadata
            opf_str = re.sub(
                r'(\s*)(</metadata>)',
                r'\1  <meta name="cover" content="cover-image"/>\n\1\2',
                opf_str
            )

        # Rebuild EPUB atomically
        dir_name = os.path.dirname(epub_path)
        fd, tmp_path = tempfile.mkstemp(suffix='.epub', dir=dir_name)
        os.close(fd)

        try:
            with zipfile.ZipFile(tmp_path, 'w') as zf_out:
                for item in zf.infolist():
                    if item.filename == 'mimetype':
                        zf_out.writestr(item, zf.read(item.filename),
                                        compress_type=zipfile.ZIP_STORED)
                    elif item.filename == opf_path:
                        zf_out.writestr(item, opf_str.encode('utf-8'),
                                        compress_type=item.compress_type)
                    elif item.filename == new_cover_path:
                        # Replace existing cover image
                        zf_out.writestr(item, image_data,
                                        compress_type=item.compress_type)
                    else:
                        zf_out.writestr(item, zf.read(item.filename),
                                        compress_type=item.compress_type)

                # If adding a new cover (path didn't exist in original ZIP)
                if cover_item is None:
                    zf_out.writestr(new_cover_path, image_data,
                                    compress_type=zipfile.ZIP_DEFLATED)

            os.replace(tmp_path, epub_path)

        except Exception:
            if os.path.exists(tmp_path):
                os.remove(tmp_path)
            raise


# ---------------------------------------------------------------------------
# Phase B: API fetchers
# ---------------------------------------------------------------------------

def _make_ssl_context():
    """Create an SSL context that works on macOS."""
    return ssl.create_default_context()


def _url_fetch(url, timeout=15):
    """Fetch URL bytes. Returns bytes or None on failure."""
    try:
        ctx = _make_ssl_context()
        req = urllib.request.Request(url, headers={'User-Agent': 'EPUBCoverUpgrader/1.0'})
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            return resp.read()
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError):
        return None


def fetch_google_books_cover(isbn='', title='', author=''):
    """Fetch cover from Google Books API. Returns (image_bytes, media_type) or (None, None)."""
    # Build query
    if isbn:
        query = f'isbn:{isbn}'
    elif title and author:
        t = urllib.request.quote(title)
        a = urllib.request.quote(author)
        query = f'intitle:{t}+inauthor:{a}'
    elif title:
        query = f'intitle:{urllib.request.quote(title)}'
    else:
        return None, None

    url = f'https://www.googleapis.com/books/v1/volumes?q={query}&maxResults=1'
    data = _url_fetch(url)
    if not data:
        return None, None

    try:
        result = json.loads(data)
        items = result.get('items', [])
        if not items:
            return None, None

        image_links = items[0].get('volumeInfo', {}).get('imageLinks', {})
        thumb_url = image_links.get('thumbnail') or image_links.get('smallThumbnail')
        if not thumb_url:
            return None, None

        # Fetch original thumbnail (always the correct front cover)
        thumb_url = thumb_url.replace('http://', 'https://')
        thumb_data = _url_fetch(thumb_url)

        # Fetch zoom=0 (highest res, but sometimes returns wrong page e.g. praise page)
        zoom0_url = re.sub(r'zoom=\d+', 'zoom=0', thumb_url)
        img_data = _url_fetch(zoom0_url)

        # Validate zoom=0 against thumbnail: if zoom=0 shows a different page
        # (e.g. praise page), its bpp will be abnormally low vs the thumbnail.
        # Real covers: bpp_ratio > 0.14, praise pages: bpp_ratio < 0.08.
        if thumb_data and img_data and len(thumb_data) > 100 and len(img_data) > 100:
            tw, th = get_image_dimensions(thumb_data)
            zw, zh = get_image_dimensions(img_data)
            if tw > 0 and th > 0 and zw > 0 and zh > 0:
                t_bpp = len(thumb_data) / (tw * th)
                z_bpp = len(img_data) / (zw * zh)
                if t_bpp > 0 and z_bpp / t_bpp < 0.1:
                    # zoom=0 is likely a different page — fall back to thumbnail
                    img_data = thumb_data
        elif thumb_data and len(thumb_data) > 100:
            img_data = thumb_data

        if not img_data or len(img_data) < 100:
            return None, None

        # Detect media type from bytes
        if img_data[:8] == b'\x89PNG\r\n\x1a\n':
            return img_data, 'image/png'
        elif img_data[:2] == b'\xff\xd8':
            return img_data, 'image/jpeg'
        else:
            return img_data, 'image/jpeg'  # Assume JPEG

    except (json.JSONDecodeError, KeyError, IndexError):
        return None, None


def fetch_openlibrary_cover(isbn='', title='', author=''):
    """Fetch cover from Open Library. Returns (image_bytes, media_type) or (None, None)."""
    img_data = None

    # Try direct ISBN lookup first
    if isbn:
        url = f'https://covers.openlibrary.org/b/isbn/{isbn}-L.jpg?default=false'
        img_data = _url_fetch(url)

    # Fallback: search by title+author to get cover_i
    if not img_data and (title or author):
        params = []
        if title:
            params.append(f'title={urllib.request.quote(title)}')
        if author:
            params.append(f'author={urllib.request.quote(author)}')
        params.append('limit=1')
        search_url = f'https://openlibrary.org/search.json?{"&".join(params)}'

        search_data = _url_fetch(search_url)
        if search_data:
            try:
                result = json.loads(search_data)
                docs = result.get('docs', [])
                if docs and 'cover_i' in docs[0]:
                    cover_id = docs[0]['cover_i']
                    url = f'https://covers.openlibrary.org/b/id/{cover_id}-L.jpg?default=false'
                    img_data = _url_fetch(url)
            except (json.JSONDecodeError, KeyError, IndexError):
                pass

    if not img_data or len(img_data) < 100:
        return None, None

    # Detect media type
    if img_data[:8] == b'\x89PNG\r\n\x1a\n':
        return img_data, 'image/png'
    elif img_data[:2] == b'\xff\xd8':
        return img_data, 'image/jpeg'
    else:
        return None, None


def fetch_bookcover_api(isbn='', title='', author=''):
    """Fetch cover from Bookcover API (Goodreads). Returns (image_bytes, media_type) or (None, None)."""
    if isbn:
        url = 'https://bookcover.longitood.com/bookcover?isbn=%s&image_size=large' % isbn
    elif title:
        params = 'book_title=%s' % urllib.request.quote(title)
        if author:
            params += '&author_name=%s' % urllib.request.quote(author)
        params += '&image_size=large'
        url = 'https://bookcover.longitood.com/bookcover?%s' % params
    else:
        return None, None

    data = _url_fetch(url)
    if not data:
        return None, None

    try:
        result = json.loads(data)
        img_url = result.get('url', '')
        if not img_url:
            return None, None

        img_data = _url_fetch(img_url)
        if not img_data or len(img_data) < 100:
            return None, None

        if img_data[:8] == b'\x89PNG\r\n\x1a\n':
            return img_data, 'image/png'
        elif img_data[:2] == b'\xff\xd8':
            return img_data, 'image/jpeg'
        else:
            return None, None
    except (json.JSONDecodeError, KeyError, IndexError):
        return None, None


ASPECT_RATIO_TOLERANCE = 0.08  # 8% tolerance for matching covers


def _aspect_ratio(w, h):
    """Return width/height ratio."""
    return w / h if h > 0 else 0


def _ratios_match(w1, h1, w2, h2):
    """Check if two images have similar aspect ratios (likely same cover)."""
    r1 = _aspect_ratio(w1, h1)
    r2 = _aspect_ratio(w2, h2)
    if r1 == 0 or r2 == 0:
        return False
    return abs(r1 - r2) / max(r1, r2) < ASPECT_RATIO_TOLERANCE


def fetch_best_cover(isbn='', title='', author=''):
    """
    Correctness-first cover fetching:
    1. Fetch reference cover from Bookcover API (Goodreads) — source of truth
    2. Fetch from Google Books & Open Library — high-res candidates
    3. Only use high-res candidates if their aspect ratio matches the reference
    4. Pick the highest resolution match

    Returns (image_bytes, media_type, width, height, source_name) or (None, None, 0, 0, '').
    """
    # Step 1: Get the reference cover (source of truth for correctness)
    ref_img, ref_mt = fetch_bookcover_api(isbn, title, author)
    ref_w, ref_h = (0, 0)
    if ref_img:
        ref_w, ref_h = get_image_dimensions(ref_img)
        if _is_placeholder(ref_img, ref_w, ref_h):
            ref_img, ref_mt, ref_w, ref_h = None, None, 0, 0
    time.sleep(API_DELAY)

    # Step 2: Get high-res candidates
    candidates = []

    # Use reference as candidate if it's a real image
    if ref_img and ref_w > 0:
        candidates.append((ref_img, ref_mt, ref_w, ref_h, 'Goodreads'))

    # Aspect ratio validation only reliable when reference is large enough
    ref_reliable = ref_w > 0 and short_side(ref_w, ref_h) >= 200

    # Reference bpp — used to reject suspiciously sparse "upgrades"
    ref_bpp = len(ref_img) / (ref_w * ref_h) if ref_img and ref_w > 0 and ref_h > 0 else 0

    # Google Books
    gb_img, gb_mt = fetch_google_books_cover(isbn, title, author)
    if gb_img:
        gb_w, gb_h = get_image_dimensions(gb_img)
        if gb_w > 0 and gb_h > 0 and not _is_placeholder(gb_img, gb_w, gb_h):
            gb_bpp = len(gb_img) / (gb_w * gb_h)
            # Reject if bpp drops >50% vs reference (likely wrong image e.g. praise page)
            bpp_ok = ref_bpp == 0 or gb_bpp >= ref_bpp * 0.5
            if ref_reliable:
                if _ratios_match(gb_w, gb_h, ref_w, ref_h) and bpp_ok:
                    candidates.append((gb_img, gb_mt, gb_w, gb_h, 'Google Books (verified)'))
            elif bpp_ok:
                candidates.append((gb_img, gb_mt, gb_w, gb_h, 'Google Books (unverified)'))
    time.sleep(API_DELAY)

    # Open Library
    ol_img, ol_mt = fetch_openlibrary_cover(isbn, title, author)
    if ol_img:
        ol_w, ol_h = get_image_dimensions(ol_img)
        if ol_w > 0 and ol_h > 0 and not _is_placeholder(ol_img, ol_w, ol_h):
            ol_bpp = len(ol_img) / (ol_w * ol_h)
            bpp_ok = ref_bpp == 0 or ol_bpp >= ref_bpp * 0.5
            if ref_reliable:
                if _ratios_match(ol_w, ol_h, ref_w, ref_h) and bpp_ok:
                    candidates.append((ol_img, ol_mt, ol_w, ol_h, 'Open Library (verified)'))
            elif bpp_ok:
                candidates.append((ol_img, ol_mt, ol_w, ol_h, 'Open Library (unverified)'))

    if not candidates:
        return None, None, 0, 0, ''

    # Step 3: Pick highest resolution (by shorter side)
    best = max(candidates, key=lambda c: min(c[2], c[3]))
    return best


# ---------------------------------------------------------------------------
# Phase C: Scanner + reporter
# ---------------------------------------------------------------------------

def short_side(w, h):
    """Return the shorter dimension."""
    return min(w, h) if w > 0 and h > 0 else 0


def scan_collection(folder, use_cache=True, files_filter=None):
    """Scan all EPUBs in folder. Returns list of result dicts."""
    results = []
    cache = load_cache(folder) if use_cache else {'_version': CACHE_VERSION}
    epub_files = sorted([f for f in os.listdir(folder) if f.lower().endswith('.epub')
                         and not f.endswith('.backup.epub')])

    # Filter to specific files if requested
    if files_filter:
        epub_files = [f for f in epub_files if f in files_filter]

    print(f"\nScanning {len(epub_files)} EPUB(s) in {folder}\n")

    cached_count = 0
    for i, fname in enumerate(epub_files, 1):
        fpath = os.path.join(folder, fname)
        file_hash = _file_hash(fpath)

        # Check cache by content hash (survives renames)
        # Skip cache when --files is used (force re-scan)
        cache_hit = False
        if use_cache and not files_filter and file_hash in cache:
            cached = cache[file_hash]
            action = cached['action']
            if action in ('UPGRADE', 'ADD', 'REPLACE'):
                # Verify cached upgrade image still exists on disk
                img_rel = cached.get('upgrade_image', '')
                img_path = os.path.join(folder, img_rel) if img_rel else ''
                if img_rel and os.path.exists(img_path):
                    cache_hit = True
                # else: image missing, fall through to full re-scan
            else:
                cache_hit = True

        if cache_hit:
            cached = cache[file_hash]
            # Update filename if it changed (file was renamed)
            if cached.get('filename') != fname:
                cached['filename'] = fname
            action = cached['action']
            print(f"[{i}/{len(epub_files)}] {fname}  (cached: {action})")
            result = {
                'file': fname, 'path': fpath, 'file_hash': file_hash,
                'status': action, 'reason': cached['reason'],
                'current_w': cached.get('current_w', 0),
                'current_h': cached.get('current_h', 0),
                'online_w': cached.get('online_w', 0),
                'online_h': cached.get('online_h', 0),
                'online_source': cached.get('online_source', ''),
                'action': action,
                'image_data': None, 'media_type': '',
            }
            # Load cached upgrade image from disk
            if action in ('UPGRADE', 'ADD', 'REPLACE'):
                img_rel = cached.get('upgrade_image', '')
                img_path = os.path.join(folder, img_rel)
                with open(img_path, 'rb') as f:
                    result['image_data'] = f.read()
                result['media_type'] = cached.get('upgrade_media_type', 'image/jpeg')
            results.append(result)
            cached_count += 1
            continue

        print(f"[{i}/{len(epub_files)}] {fname}")

        info = get_epub_cover_info(fpath)
        if info is None:
            results.append({
                'file': fname,
                'path': fpath,
                'status': 'ERROR',
                'reason': 'Could not read EPUB',
                'current_w': 0, 'current_h': 0,
                'online_w': 0, 'online_h': 0,
                'online_source': '',
                'action': 'SKIP',
                'image_data': None,
                'media_type': '',
            })
            continue

        cur_w, cur_h = info['cover_width'], info['cover_height']
        cur_short = short_side(cur_w, cur_h)

        # Detect placeholder/blank covers (e.g. "image not available", blank proof pages)
        if info['cover_data'] is not None and _is_placeholder(info['cover_data'], cur_w, cur_h):
            print(f"  Title: {info['title']}  Author: {info['author']}  ISBN: {info['isbn'] or 'none'}")
            print(f"  Current cover: PLACEHOLDER ({cur_w}x{cur_h}, {len(info['cover_data'])} bytes)")
            # Treat as missing
            info['cover_data'] = None
            cur_w, cur_h = 0, 0
            cur_short = 0
        else:
            print(f"  Title: {info['title']}  Author: {info['author']}  ISBN: {info['isbn'] or 'none'}")
            if cur_w > 0:
                print(f"  Current cover: {cur_w}x{cur_h} (short side: {cur_short}px)")
            else:
                print(f"  Current cover: {'missing' if info['cover_data'] is None else 'unreadable'}")

        # Fetch best online cover (correctness-first)
        print(f"  Searching online...", end=' ', flush=True)
        img, mt, on_w, on_h, source = fetch_best_cover(info['isbn'], info['title'], info['author'])
        on_short = short_side(on_w, on_h)

        if img:
            print(f"found {on_w}x{on_h} from {source}")
        else:
            print("no cover found")

        # Check if current cover is correct by comparing ratio to reference
        current_looks_wrong = False
        if cur_w > 0 and cur_h > 0 and on_w > 0 and on_h > 0:
            if not _ratios_match(cur_w, cur_h, on_w, on_h):
                current_looks_wrong = True
                print(f"  WARNING: Current cover ratio ({_aspect_ratio(cur_w, cur_h):.3f}) "
                      f"doesn't match reference ({_aspect_ratio(on_w, on_h):.3f})")

        # Determine action
        action = 'SKIP'
        reason = ''

        if current_looks_wrong and img is not None:
            # Current cover is likely wrong — replace regardless of resolution
            action = 'REPLACE'
            reason = f'Wrong cover detected! -> {on_w}x{on_h} from {source}'
        elif info['cover_data'] is None and img is None:
            action = 'SKIP'
            reason = 'No cover exists and none found online'
        elif info['cover_data'] is None and img is not None:
            action = 'ADD'
            reason = f'No cover -> {on_w}x{on_h} from {source}'
        elif info['cover_data'] is not None and img is None:
            if cur_short >= MIN_SHORT_SIDE:
                action = 'OK'
                reason = f'Current cover is HQ ({cur_w}x{cur_h})'
            else:
                action = 'FLAG'
                reason = f'Current cover low-res ({cur_w}x{cur_h}), no online alternative'
        else:
            # Both exist, current is correct — compare resolution
            if cur_short >= MIN_SHORT_SIDE and cur_short >= on_short:
                action = 'OK'
                reason = f'Current cover is best ({cur_w}x{cur_h} >= {on_w}x{on_h})'
            elif on_short > cur_short and on_short >= MIN_SHORT_SIDE:
                action = 'UPGRADE'
                reason = f'{cur_w}x{cur_h} -> {on_w}x{on_h} from {source}'
            elif cur_short >= MIN_SHORT_SIDE:
                action = 'OK'
                reason = f'Current cover is HQ ({cur_w}x{cur_h})'
            else:
                action = 'FLAG'
                reason = f'Both low-res: current {cur_w}x{cur_h}, online {on_w}x{on_h}'

        print(f"  -> {action}: {reason}")

        result = {
            'file': fname,
            'path': fpath,
            'file_hash': file_hash,
            'status': action,
            'reason': reason,
            'current_w': cur_w, 'current_h': cur_h,
            'online_w': on_w, 'online_h': on_h,
            'online_source': source,
            'action': action,
            'image_data': img,
            'media_type': mt or '',
        }
        results.append(result)

        # Cache result (all action types, keyed by content hash)
        cache_entry = {
            'filename': fname,
            'action': action,
            'reason': reason,
            'current_w': cur_w, 'current_h': cur_h,
            'online_w': on_w, 'online_h': on_h,
            'online_source': source,
        }
        # Save upgrade images to disk so --apply can reuse them after renames
        if action in ('UPGRADE', 'ADD', 'REPLACE') and img is not None:
            upgrade_dir = os.path.join(folder, UPGRADE_DIR)
            os.makedirs(upgrade_dir, exist_ok=True)
            ext = '.png' if mt == 'image/png' else '.jpeg'
            img_rel = os.path.join(UPGRADE_DIR, file_hash + ext)
            with open(os.path.join(folder, img_rel), 'wb') as f:
                f.write(img)
            cache_entry['upgrade_image'] = img_rel
            cache_entry['upgrade_media_type'] = mt
        cache[file_hash] = cache_entry

        time.sleep(API_DELAY)

    if use_cache:
        save_cache(folder, cache)

    if cached_count:
        print(f"\n({cached_count} file(s) skipped via cache)")

    return results


def print_report(results):
    """Print a summary table of all results."""
    print("\n" + "=" * 80)
    print("COVER UPGRADE REPORT")
    print("=" * 80)

    actions = {'REPLACE': [], 'ADD': [], 'UPGRADE': [], 'FLAG': [], 'OK': [], 'SKIP': [], 'ERROR': []}
    for r in results:
        actions[r['action']].append(r)

    if actions['REPLACE']:
        print(f"\n  WRONG COVERS ({len(actions['REPLACE'])} files):")
        for r in actions['REPLACE']:
            print(f"    [REPLACE] {r['file']}")
            print(f"              {r['reason']}")

    if actions['ADD'] or actions['UPGRADE']:
        print(f"\n  UPGRADES AVAILABLE ({len(actions['ADD']) + len(actions['UPGRADE'])} files):")
        for r in actions['ADD'] + actions['UPGRADE']:
            print(f"    [{r['action']}] {r['file']}")
            print(f"           {r['reason']}")

    if actions['FLAG']:
        print(f"\n  FLAGGED ({len(actions['FLAG'])} files):")
        for r in actions['FLAG']:
            print(f"    [FLAG] {r['file']}")
            print(f"           {r['reason']}")

    if actions['ERROR']:
        print(f"\n  ERRORS ({len(actions['ERROR'])} files):")
        for r in actions['ERROR']:
            print(f"    [ERR]  {r['file']}: {r['reason']}")

    ok_count = len(actions['OK'])
    skip_count = len(actions['SKIP'])
    print(f"\n  OK: {ok_count}  |  SKIP: {skip_count}  |  ERRORS: {len(actions['ERROR'])}")
    print("=" * 80)

    return actions['REPLACE'] + actions['ADD'] + actions['UPGRADE']


def apply_upgrades(upgradeable):
    """Apply cover upgrades to EPUBs."""
    print(f"\nApplying {len(upgradeable)} upgrade(s)...\n")

    for r in upgradeable:
        fname = r['file']
        print(f"  Upgrading {fname}...", end=' ', flush=True)

        try:
            set_epub_cover(r['path'], r['image_data'], r['media_type'])

            # Verify
            with zipfile.ZipFile(r['path'], 'r') as zf:
                bad = zf.testzip()
                if bad:
                    print(f"WARNING: ZIP corruption detected in {bad}")
                else:
                    print("OK")
        except Exception as e:
            print(f"FAILED: {e}")


def main():
    folder = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith('-') else os.getcwd()
    apply_mode = '--apply' in sys.argv
    use_cache = '--no-cache' not in sys.argv

    # Parse --files flag (exact filenames to force re-scan)
    files_filter = None
    if '--files' in sys.argv:
        idx = sys.argv.index('--files')
        files_filter = []
        for arg in sys.argv[idx + 1:]:
            if arg.startswith('--'):
                break
            files_filter.append(arg)
        if not files_filter:
            print("Error: --files requires at least one filename")
            sys.exit(1)

    if not os.path.isdir(folder):
        print(f"Error: {folder} is not a directory")
        sys.exit(1)

    results = scan_collection(folder, use_cache=use_cache, files_filter=files_filter)
    upgradeable = print_report(results)

    if not upgradeable:
        print("\nNo upgrades needed.")
        return

    if not apply_mode:
        print(f"\nDry run complete. Run with --apply to apply {len(upgradeable)} upgrade(s).")
        print(f"  python3 {sys.argv[0]} {folder} --apply")
        return

    # Confirm before applying
    print(f"\nAbout to modify {len(upgradeable)} file(s). Continue? [y/N] ", end='', flush=True)
    answer = input().strip().lower()
    if answer != 'y':
        print("Aborted.")
        return

    apply_upgrades(upgradeable)

    # Update cache — remove old entries, add new ones with post-upgrade hashes
    cache = load_cache(folder)
    for r in upgradeable:
        old_hash = r.get('file_hash', '')
        # Remove old cache entry and its upgrade image
        if old_hash and old_hash in cache:
            old_entry = cache[old_hash]
            img_rel = old_entry.get('upgrade_image', '')
            if img_rel:
                img_path = os.path.join(folder, img_rel)
                if os.path.exists(img_path):
                    os.remove(img_path)
            del cache[old_hash]
        # Add new entry keyed by post-upgrade hash
        if os.path.exists(r['path']):
            new_hash = _file_hash(r['path'])
            cache[new_hash] = {
                'filename': r['file'],
                'action': 'OK',
                'reason': f'Upgraded from {r["online_source"]}',
                'current_w': r['online_w'], 'current_h': r['online_h'],
                'online_w': r['online_w'], 'online_h': r['online_h'],
                'online_source': r['online_source'],
            }
    # Clean up upgrade directory if empty
    upgrade_dir = os.path.join(folder, UPGRADE_DIR)
    if os.path.isdir(upgrade_dir) and not os.listdir(upgrade_dir):
        os.rmdir(upgrade_dir)
    save_cache(folder, cache)

    print("\nDone. Run Quick Look (Space) on modified files to verify covers.")


if __name__ == '__main__':
    main()
