# ebooks

ebooks is an intake pipeline for an ebook shelf. A book dropped in a synced folder gets
a proposed clean filename and a better cover, then is filed on approval.

# Capabilities

- A book dropped in the inbox is inspected the moment it arrives, from any device that
  syncs the folder.
- The file is checked for integrity: a valid zip, readable metadata, a sane size, a PDF
  that opens and is not locked.
- A draft name is built from the book's own metadata by plain rules: `Title - Author`,
  subtitles after a semicolon, authors in First Last order, joined with "and". The same
  book always gives the same draft. There is no model and no API key anywhere.
- Junk is stripped: stray semicolons, honorifics, translators listed as authors, trailing
  decoration such as `(Book Club Edition)`, and characters Windows and Android refuse.
- Anything the rules are not sure of is flagged and gets its own message.
- A book already on the shelf, as the same file or as the same title and author in the
  other format, is blocked. It gets no Accept button.
- For EPUBs, a higher-resolution cover is looked up from free public sources and shown in
  the notification. It is applied only on approval.
- The proposal arrives as a notification with Accept and Discard buttons. Nothing moves
  without a tap.
- Clean proposals are batched into one message. Anything doubtful gets its own.
- Staged books live outside the synced folder, so a book that has not been approved never
  appears on an e-reader.
- A staged book is nudged after a day and moved to the bin after a week. Accept still files
  it from the bin, and nothing is destroyed without a tap.
