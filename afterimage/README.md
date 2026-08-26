# afterimage

afterimage is an event inference pipeline for generating calendar entries from images.

# Capabilities

afterimage reads a screenshot, proposes the calendar events it describes, and
writes the approved ones to a private calendar server.

- A screenshot uploaded from a laptop hotkey or a phone is triaged the moment it
  lands. Nothing is scheduled and nothing is polled.
- A vision model extracts the event details: title, date, time, location, and any
  alternative occasions the image offers.
- One image can describe several events. Each becomes its own proposal with its
  own notification and its own decision, sharing the original screenshot.
- Proposals arrive as a notification with Add and Discard buttons. Nothing
  reaches the calendar without a tap.
- Events that have already passed are detected in code rather than by the model,
  and collapsed into a single note.
- A proposal left untouched is re-notified the following day and archived after a
  week. Notifications are withdrawn once their decision is made, so an
  outstanding message always means an outstanding decision.
- A transient model failure parks the record and retries it on a daily sweep
  rather than discarding the capture.
- Screenshots are pruned after a week. Each archived record carries its own
  decision, so no ledger is needed.
- Both common screenshot formats are accepted, and a file's real type is
  determined by inspection rather than by its name.
