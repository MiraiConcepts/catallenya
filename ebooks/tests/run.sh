#!/usr/bin/env bash
# Regression tests for the ebooks intake pipeline.
#
# Offline and free: there is no model in this pipeline, and the one network call (the cover
# lookup) is switched off by EBOOKS_COVER_OFFLINE. Every case that RUNS a script runs it
# against a scratch tree — SHELF and STATE_DIR are redirected — so nothing here can touch
# the real shelf, and NTFY_DISABLE=1 keeps every notification off the real phone.
#
# THE CASES THAT MATTER MOST are the drain invariants. Both .path units re-fire while their
# glob matches, so a branch that leaves a book in the inbox (triage) or a marker in
# approvals/ (apply) spins systemd. Every failure branch is asserted to drain.
#
#   bash ebooks/tests/run.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "${SELF_DIR}/../scripts" && pwd)"
INSPECT="${SCRIPT_DIR}/ebooks.inspect.py"

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$3" "$2"; }
has()  { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "contains $3" "$2"; }
hasnt(){ [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "must not contain $3" "$2"; }

TMP="$(mktemp -d)"
cleanup() { chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

export SHELF="${TMP}/stories" STATE_DIR="${TMP}/state"
export NTFY_DISABLE=1 SKIP_SYNCTHING_GATE=1 EBOOKS_COVER_OFFLINE=1
export INBOX="${SHELF}/inbox"
# shellcheck source=../scripts/ebooks.lib.sh
source "${SCRIPT_DIR}/ebooks.lib.sh"

fresh() {
    chmod -R u+rwx "$TMP" 2>/dev/null
    rm -rf "$SHELF" "$STATE_DIR"
    mkdir -p "$INBOX" "$STATE_DIR"/{proposals,approvals,staging,bin,covers,work}
}

# mk_epub <path> <title> [creator|creator@role ...]   — a minimal, valid, >5KB EPUB
mk_epub() {
    local path="$1" title="$2"; shift 2
    python3 -I - "$path" "$title" "$@" <<'PY'
import sys, zipfile, os
path, title, *creators = sys.argv[1:]
cre = ''
for c in creators:
    name, _, role = c.partition('@')
    attr = f' opf:role="{role}"' if role else ''
    cre += f'<dc:creator{attr}>{name}</dc:creator>'
opf = ('<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0" '
       'unique-identifier="id"><metadata xmlns:opf="http://www.idpf.org/2007/opf" '
       'xmlns:dc="http://purl.org/dc/elements/1.1/">'
       f'<dc:title>{title}</dc:title>{cre}<dc:identifier id="id">x</dc:identifier></metadata>'
       '<manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest>'
       '<spine><itemref idref="c"/></spine></package>')
with zipfile.ZipFile(path, 'w') as z:
    z.writestr('mimetype', 'application/epub+zip')
    z.writestr('META-INF/container.xml',
        '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        '<rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
    z.writestr('content.opf', opf)
    z.writestr('c.xhtml', '<html><body>' + ('lorem ipsum ' * 800) + os.path.basename(path) + '</body></html>')
PY
}

draft() { python3 -I "$INSPECT" inspect "$1" "${2:-$SHELF}" | jq -r '.draft'; }
field() { python3 -I "$INSPECT" inspect "$1" "${3:-$SHELF}" | jq -rc ".$2"; }

# ------------------------------------------------------------------- name rules
echo "name rules"
fresh
mk_epub "$TMP/a.epub" "Earthlings" "Sayaka Murata;@aut"
is "trailing ; on the author is dropped"        "$(draft "$TMP/a.epub")" "Earthlings - Sayaka Murata.epub"
mk_epub "$TMP/a.epub" "Black Holes: The Key to Understanding" "Cox, Brian@aut" "Forshaw, Jeff@aut"
is "colon becomes semicolon, Last/First flips, authors joined with and" \
   "$(draft "$TMP/a.epub")" "Black Holes; The Key to Understanding - Brian Cox and Jeff Forshaw.epub"
mk_epub "$TMP/a.epub" "A Discourse on Inequality" "Jean-Jacques Rousseau, Maurice Cranston (translator)"
is "a translator inside the author string is removed, the author kept" \
   "$(draft "$TMP/a.epub")" "A Discourse on Inequality - Jean-Jacques Rousseau.epub"
mk_epub "$TMP/a.epub" "The Castle" "Franz Kafka@aut" "Mark Harman@trl"
is "a role-tagged translator is not an author"  "$(draft "$TMP/a.epub")" "The Castle - Franz Kafka.epub"
mk_epub "$TMP/a.epub" "Small Things Like These (Oprah's Book Club)" "Claire Keegan"
is "trailing parenthetical decoration is stripped" "$(draft "$TMP/a.epub")" "Small Things Like These - Claire Keegan.epub"
mk_epub "$TMP/a.epub" "Sum" "Zweig, Stefan; Stone, Will"
is "two people in one string are split"         "$(draft "$TMP/a.epub")" "Sum - Stefan Zweig and Will Stone.epub"
mk_epub "$TMP/a.epub" "Anna Karenina" "graf Leo Tolstoy"
is "an honorific prefix is dropped"             "$(draft "$TMP/a.epub")" "Anna Karenina - Leo Tolstoy.epub"
mk_epub "$TMP/a.epub" "The Boy’s Fox" "Charlie Mackesy"
is "a smart quote becomes ASCII"                "$(draft "$TMP/a.epub")" "The Boy's Fox - Charlie Mackesy.epub"
mk_epub "$TMP/a.epub" 'Why? Who*Cares|Not' "Some Author"
is "characters Windows refuses are dropped"     "$(draft "$TMP/a.epub")" "Why WhoCaresNot - Some Author.epub"
mk_epub "$TMP/a.epub" "Marcus Aurelius_Meditations" "KTHTK"
is "an underscore title is FLAGGED, not guessed" "$(field "$TMP/a.epub" flags)" '["NAME_UNCLEAR"]'
mk_epub "$TMP/a.epub" "Untitled Thing"
has "no author is flagged" "$(field "$TMP/a.epub" flags)" "NO_AUTHOR"
mk_epub "$TMP/a.epub" "$(printf 'X%.0s' $(seq 1 400))" "Au Thor"
(( $(draft "$TMP/a.epub" | wc -c) <= 200 )) && ok "an over-long name is bounded" || bad "an over-long name is bounded" "<=200" "longer"

# ------------------------------------------------------------------ integrity
echo "integrity"
head -c 100 /dev/urandom > "$TMP/tiny.epub"
is "a tiny file is refused"          "$(field "$TMP/tiny.epub" problem)" "FILE_TOO_SMALL"
head -c 20000 /dev/urandom > "$TMP/junk.epub"
is "a non-zip is refused"            "$(field "$TMP/junk.epub" problem)" "EPUB_CORRUPT"
: > "$TMP/empty.epub"
is "an empty file is refused"        "$(field "$TMP/empty.epub" problem)" "FILE_EMPTY"
echo hello > "$TMP/x.mobi"
is "an unsupported type is refused"  "$(field "$TMP/x.mobi" problem)" "UNSUPPORTED_TYPE"
echo "%PDF-1.4 garbage" > "$TMP/bad.pdf"
is "a broken PDF is refused"         "$(field "$TMP/bad.pdf" problem)" "PDF_UNREADABLE"

# ----------------------------------------------------------------- duplicates
echo "duplicates"
fresh
mk_epub "$SHELF/Gift from the Sea - Anne Morrow Lindbergh.epub" "Gift from the Sea" "Anne Morrow Lindbergh"
mk_epub "$TMP/d.epub" "Gift From The Sea" "Anne Morrow Lindbergh"
is "same title+author, different casing, is a duplicate" \
   "$(field "$TMP/d.epub" duplicate_of)" "Gift from the Sea - Anne Morrow Lindbergh.epub"
mk_epub "$TMP/d.epub" "Gift from the Sea: A Reflection" "Anne Morrow Lindbergh"
has "a subtitle does not hide a duplicate" "$(field "$TMP/d.epub" duplicate_of)" "Gift from the Sea"
mk_epub "$TMP/d.epub" "Something Else Entirely" "Anne Morrow Lindbergh"
is "a different title is not" "$(field "$TMP/d.epub" duplicate_of)" ""
cp "$SHELF/Gift from the Sea - Anne Morrow Lindbergh.epub" "$TMP/renamed.epub"
has "byte-identical under another name is a duplicate" "$(field "$TMP/renamed.epub" duplicate_of)" "Gift from the Sea"

# ---------------------------------------------------------------- path safety
echo "path safety"
for good in "Earthlings - Sayaka Murata.epub" "a.pdf" "Sum; Forty Tales - X Y.epub"; do
    valid_book_name "$good" && ok "accepts ${good}" || bad "accepts ${good}" ok reject
done
for badn in "../x.epub" "a/b.epub" ".hidden.epub" "x..y.epub" "noext" "x.exe" "" "$(printf 'a%.0s' $(seq 1 250)).epub"; do
    valid_book_name "$badn" && bad "refuses ${badn:0:30}" reject accepted || ok "refuses ${badn:0:30}"
done
fresh
under_shelf "${SHELF}/ok.epub"            && ok "a direct child of the shelf is allowed"  || bad "direct child" ok refused
under_shelf "${SHELF}/inbox/x.epub"       && bad "inbox is refused" refused allowed || ok "a path into inbox/ is refused (would re-trigger forever)"
under_shelf "${SHELF}/../etc/x.epub"      && bad "traversal refused" refused allowed || ok "traversal out of the shelf is refused"
under_staging "${STAGING_DIR}/ok.epub"    && ok "a direct child of staging is allowed" || bad "staging child" ok refused
under_staging "${STAGING_DIR}/../x.epub"  && bad "staging traversal" refused allowed || ok "traversal out of staging is refused"

# -------------------------------------------------------------------- triage
echo "triage"
fresh
mk_epub "$INBOX/clean.epub"    "Convenience Store Woman" "Sayaka Murata"
mk_epub "$INBOX/flagged.epub"  "Marcus Aurelius_Meditations" "KTHTK"
mk_epub "$SHELF/Anna Karenina - Leo Tolstoy.epub" "Anna Karenina" "Leo Tolstoy"
mk_epub "$INBOX/dupe.epub"     "Anna Karenina" "Leo Tolstoy"
head -c 20000 /dev/urandom > "$INBOX/broken.epub"
echo x > "$INBOX/odd.mobi"
echo hidden > "$INBOX/.dotfile"
bash "${SCRIPT_DIR}/ebooks.triage.sh" >"$TMP/triage.out" 2>&1; rc=$?
is "triage exits 0" "$rc" "0"
is "THE INVARIANT: every non-dot file left the inbox" "$(find "$INBOX" -maxdepth 1 -type f ! -name '.*' | wc -l)" "0"
ok "the dotfile is left alone: $( [[ -f "$INBOX/.dotfile" ]] && echo yes )"
[[ -f "${STAGING_DIR}/Convenience Store Woman - Sayaka Murata.epub" ]] && ok "a clean book is staged under its proposed name" || bad "clean staged" present absent
is "five books were staged in total" "$(find "$STAGING_DIR" -type f | wc -l)" "5"
is "the clean book is in a batch"    "$(for f in "$PROPOSALS_DIR"/*.json; do [[ "$(staged_class "$f")" == clean ]] && echo c; done | wc -l)" "1"
is "the flagged book is flagged"     "$(for f in "$PROPOSALS_DIR"/*.json; do [[ "$(staged_class "$f")" == flagged ]] && echo c; done | wc -l)" "1"
is "three are blocked (dupe, broken, .mobi)" "$(for f in "$PROPOSALS_DIR"/*.json; do [[ "$(staged_class "$f")" == blocked ]] && echo c; done | wc -l)" "3"
is "a blocked book keeps its ORIGINAL name" "$( [[ -f "$STAGING_DIR/dupe.epub" ]] && echo yes )" "yes"
is "the duplicate record names what it matched" \
   "$(jq -rs '.[] | select(.blocked=="DUPLICATE") | .duplicate_of' "$PROPOSALS_DIR"/*.json)" "Anna Karenina - Leo Tolstoy.epub"
is "the shelf was not touched" "$(find "$SHELF" -maxdepth 1 -type f | wc -l)" "1"

# triage must drain even when staging fails
fresh
mk_epub "$INBOX/x.epub" "Some Book" "An Author"
chmod 500 "$STAGING_DIR"
bash "${SCRIPT_DIR}/ebooks.triage.sh" >"$TMP/triage2.out" 2>&1; rc=$?
chmod 700 "$STAGING_DIR"
is "an unstageable book fails the unit (so OnFailure fires)" "$( ((rc != 0)) && echo yes )" "yes"
is "...and the book is still in the inbox, not lost" "$( [[ -f "$INBOX/x.epub" ]] && echo yes )" "yes"

# empty inbox
fresh
bash "${SCRIPT_DIR}/ebooks.triage.sh" >"$TMP/triage3.out" 2>&1
has "an empty inbox is a quiet no-op" "$(cat "$TMP/triage3.out")" "nothing in the inbox"

# --------------------------------------------------------------------- apply
echo "apply"
stage_one() { # -> prints the record id
    fresh
    mk_epub "$INBOX/one.epub" "Convenience Store Woman" "Sayaka Murata"
    bash "${SCRIPT_DIR}/ebooks.triage.sh" >/dev/null 2>&1
    for f in "$PROPOSALS_DIR"/*.json; do [[ "$(jq -r '.kind // ""' "$f")" == batch ]] || { basename "$f" .json; return; }; done
}
marker() { printf '{"action":"%s","at":"x"}' "$2" > "${APPROVALS_DIR}/$1.json"; }
run_apply() { bash "${SCRIPT_DIR}/ebooks.apply.sh" >"$TMP/apply.out" 2>&1; }

id="$(stage_one)"
marker "$id" accept; run_apply
is "accept files the book on the shelf" "$( [[ -f "$SHELF/Convenience Store Woman - Sayaka Murata.epub" ]] && echo yes )" "yes"
is "...and the staged copy is gone" "$(find "$STAGING_DIR" -type f | wc -l)" "0"
is "...and the marker was consumed" "$(find "$APPROVALS_DIR" -name '*.json' | wc -l)" "0"
is "...and the record says filed" "$(jq -r .state "$PROPOSALS_DIR/$id.json")" "filed"
is "...and the shelf holds the book and inbox/ and NOTHING else (no cache files)" \
   "$(ls -A "$SHELF" | sort | tr '\n' '|')" "Convenience Store Woman - Sayaka Murata.epub|inbox|"

id="$(stage_one)"
marker "$id" discard; run_apply
is "discard moves it to bin/" "$(find "$BIN_DIR" -type f | wc -l)" "1"
is "...and the shelf stays empty of it" "$(find "$SHELF" -maxdepth 1 -type f | wc -l)" "0"

id="$(stage_one)"
marker "$id" delete; run_apply
is "delete is REFUSED for a book that is only staged" "$( [[ -f "$STAGING_DIR/Convenience Store Woman - Sayaka Murata.epub" ]] && echo yes )" "yes"
has "...and says so" "$(cat "$TMP/apply.out")" "Only a book in bin/ can be deleted"
marker "$id" discard; run_apply
marker "$id" delete; run_apply
is "delete from bin/ removes it for good" "$(find "$BIN_DIR" -type f | wc -l)" "0"

id="$(stage_one)"
echo tamper >> "$STAGING_DIR/Convenience Store Woman - Sayaka Murata.epub"
marker "$id" accept; run_apply
has "a book changed after proposal is refused" "$(cat "$TMP/apply.out")" "changed after it was proposed"
is "...and not filed" "$(find "$SHELF" -maxdepth 1 -type f | wc -l)" "0"
is "...and the marker was still consumed (no spin)" "$(find "$APPROVALS_DIR" -name '*.json' | wc -l)" "0"

id="$(stage_one)"
cp "$STAGING_DIR/Convenience Store Woman - Sayaka Murata.epub" "$SHELF/Convenience Store Woman - Sayaka Murata.epub"
marker "$id" accept; run_apply
has "a taken destination is refused" "$(cat "$TMP/apply.out")" "already at"

id="$(stage_one)"
marker "$id" explode; run_apply
has "an unknown action is refused" "$(cat "$TMP/apply.out")" "Unknown action"
marker "00000000-0000-0000-0000-000000000000" accept; run_apply
has "an unknown id is refused" "$(cat "$TMP/apply.out")" "No such proposal"
printf 'not json' > "${APPROVALS_DIR}/garbage.json"; run_apply
is "a garbage marker is dropped, not kept" "$(find "$APPROVALS_DIR" -name '*.json' | wc -l)" "0"

# batch tap
fresh
mk_epub "$INBOX/a.epub" "First Book" "Au One"
mk_epub "$INBOX/b.epub" "Second Book" "Au Two"
bash "${SCRIPT_DIR}/ebooks.triage.sh" >/dev/null 2>&1
bid="$(for f in "$PROPOSALS_DIR"/*.json; do [[ "$(jq -r '.kind // ""' "$f")" == batch ]] && basename "$f" .json; done)"
marker "$bid" accept; run_apply
is "one batch tap files both books" "$(find "$SHELF" -maxdepth 1 -name '*.epub' | wc -l)" "2"
marker "$bid" accept; run_apply
has "a tap on a finished batch is refused, not re-run" "$(cat "$TMP/apply.out")" "replaced by a newer one"

# a path-shaped record can never write outside the shelf
fresh
mk_epub "$INBOX/e.epub" "Escape" "Au Thor"
bash "${SCRIPT_DIR}/ebooks.triage.sh" >/dev/null 2>&1
eid="$(for f in "$PROPOSALS_DIR"/*.json; do [[ "$(jq -r '.kind // ""' "$f")" == batch ]] || { basename "$f" .json; }; done | head -1)"
jq -c '.dest_name="../escaped.epub"' "$PROPOSALS_DIR/$eid.json" > "$TMP/r.json" && mv "$TMP/r.json" "$PROPOSALS_DIR/$eid.json"
marker "$eid" accept; run_apply
is "a tampered dest_name cannot leave the shelf" "$( [[ -e "$TMP/escaped.epub" || -e "$SHELF/../escaped.epub" ]] && echo escaped || echo safe )" "safe"
has "...and is refused" "$(cat "$TMP/apply.out")" "leaves the shelf"

# cover swap on accept
echo "cover on accept"
fresh
mk_epub "$INBOX/c.epub" "Covered Book" "Au Thor"
bash "${SCRIPT_DIR}/ebooks.triage.sh" >/dev/null 2>&1
cid="$(for f in "$PROPOSALS_DIR"/*.json; do [[ "$(jq -r '.kind // ""' "$f")" == batch ]] || { basename "$f" .json; }; done | head -1)"
python3 -I - "$COVERS_DIR/new.png" <<'PY'
import struct, sys, zlib
w, h = 700, 1000
def chunk(t, d): c = struct.pack('>I', len(d)) + t + d; return c + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
raw = b''.join(b'\x00' + b'\xff\x00\x00' * w for _ in range(h))
open(sys.argv[1], 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))
PY
jq -c --arg i "$COVERS_DIR/new.png" '.cover={action:"ADD",reason:"test",current_w:0,current_h:0,online_w:700,online_h:1000,source:"test",image:$i,media_type:"image/png"}' \
   "$PROPOSALS_DIR/$cid.json" > "$TMP/r.json" && mv "$TMP/r.json" "$PROPOSALS_DIR/$cid.json"
marker "$cid" accept; run_apply
final="$SHELF/Covered Book - Au Thor.epub"
is "the book is filed" "$( [[ -f "$final" ]] && echo yes )" "yes"
is "the cover inside it is now the new image" "$(python3 -I - "$final" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
print('yes' if any(n.lower().endswith('.png') and z.getinfo(n).file_size > 100 for n in z.namelist()) else 'no')
PY
)" "yes"
is "the zip is still sound" "$(python3 -I -c "import zipfile,sys;print(zipfile.ZipFile(sys.argv[1]).testzip())" "$final")" "None"
is "the staged original was removed once the new file was verified" "$(find "$STAGING_DIR" -type f | wc -l)" "0"

# REPLACE is a guess, never applied
fresh
mk_epub "$INBOX/r.epub" "Guessed Book" "Au Thor"
bash "${SCRIPT_DIR}/ebooks.triage.sh" >/dev/null 2>&1
rid="$(for f in "$PROPOSALS_DIR"/*.json; do [[ "$(jq -r '.kind // ""' "$f")" == batch ]] || { basename "$f" .json; }; done | head -1)"
cp "$COVERS_DIR/new.png" "$COVERS_DIR/r.png" 2>/dev/null || cp "$TMP/../x" "$COVERS_DIR/r.png" 2>/dev/null || echo png > "$COVERS_DIR/r.png"
jq -c --arg i "$COVERS_DIR/r.png" '.cover={action:"REPLACE",current_w:600,current_h:800,online_w:331,online_h:500,source:"Open Library (unverified)",image:$i,media_type:"image/png"}' \
   "$PROPOSALS_DIR/$rid.json" > "$TMP/r.json" && mv "$TMP/r.json" "$PROPOSALS_DIR/$rid.json"
has "a REPLACE cover is described as a guess, not as a change" "$(batch_list "$PROPOSALS_DIR/$rid.json")" "may be wrong"
hasnt "...and never as a size change" "$(batch_list "$PROPOSALS_DIR/$rid.json")" "331x500"
before="$(sha256_of "$STAGING_DIR/Guessed Book - Au Thor.epub")"
marker "$rid" accept; run_apply
is "a REPLACE cover leaves the book's bytes untouched" "$(sha256_of "$SHELF/Guessed Book - Au Thor.epub")" "$before"

# a failed swap must not lose the book
fresh
mk_epub "$INBOX/c.epub" "Covered Book" "Au Thor"
bash "${SCRIPT_DIR}/ebooks.triage.sh" >/dev/null 2>&1
cid="$(for f in "$PROPOSALS_DIR"/*.json; do [[ "$(jq -r '.kind // ""' "$f")" == batch ]] || { basename "$f" .json; }; done | head -1)"
echo "not an image" > "$COVERS_DIR/bad.png"
jq -c --arg i "$COVERS_DIR/bad.png" '.cover={action:"ADD",online_w:1,online_h:1,source:"test",image:$i,media_type:"image/png"}' \
   "$PROPOSALS_DIR/$cid.json" > "$TMP/r.json" && mv "$TMP/r.json" "$PROPOSALS_DIR/$cid.json"
marker "$cid" accept; run_apply
is "a cover that will not apply still files the book" "$( [[ -f "$SHELF/Covered Book - Au Thor.epub" ]] && echo yes )" "yes"

# ---------------------------------------------------------------------- sweep
echo "sweep"
age() { touch -d "$2 hours ago" "$PROPOSALS_DIR/$1.json"; }
run_sweep() { bash "${SCRIPT_DIR}/ebooks.sweep.sh" "$@" >"$TMP/sweep.out" 2>&1; }

id="$(stage_one)"
age "$id" 30
run_sweep
has "a 30h-old staged book is nudged" "$(cat "$TMP/sweep.out")" "re-notified"
is "...exactly once" "$(jq -r '.renotified_at != null' "$PROPOSALS_DIR/$id.json")" "true"
run_sweep
hasnt "...and not again the next night" "$(cat "$TMP/sweep.out")" "re-notified"

age "$id" 200
run_sweep; rc=$?
is "a 200h-old staged book is binned" "$(find "$BIN_DIR" -type f | wc -l)" "1"
is "...never deleted" "$(jq -r .state "$PROPOSALS_DIR/$id.json")" "binned"
is "...and the sweep exits 0" "$rc" "0"

id="$(stage_one)"
age "$id" 200
chmod 500 "$BIN_DIR"
run_sweep; rc=$?
chmod 700 "$BIN_DIR"
is "a bin that fails FAILS THE UNIT (a bad night must not look like a good one)" "$( ((rc != 0)) && echo yes )" "yes"
is "...and the book is still staged" "$(find "$STAGING_DIR" -type f | wc -l)" "1"

id="$(stage_one)"
age "$id" 200
run_sweep --dry-run
is "--dry-run moves nothing" "$(find "$STAGING_DIR" -type f | wc -l)" "1"

# ------------------------------------------------------------------- hygiene
echo "hygiene"
for s in triage apply sweep lib; do
    [[ -x "${SCRIPT_DIR}/ebooks.${s}.sh" ]] && ok "ebooks.${s}.sh is executable" || bad "ebooks.${s}.sh is executable" "+x" "not executable"
done
hasnt "no script reaches the model API"   "$(cat "$SCRIPT_DIR"/*.sh "$INSPECT")" "api.anthropic.com"
hasnt "no script sources the AI layer"    "$(cat "$SCRIPT_DIR"/*.sh)" "ai.lib.sh"
hasnt "no unit loads a secret"            "$(grep -h "^EnvironmentFile" "$SELF_DIR"/../systemd/* )" "EnvironmentFile"
has   "the marker is deleted before it is acted on" "$(grep -n 'rm -f "\$mk"' "$SCRIPT_DIR/ebooks.apply.sh")" "rm -f"

echo
echo "${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
