# Dabber: session names from the calendar

Date: 2026-09-24. Status: design approved in chat.

## Behaviour

- On Record, Dabber looks for a calendar event in all calendars that is running now or starts within the next
  15 minutes; all-day events are ignored; among several, the one whose start is closest to now wins.
- Session name: `yyyy-MM-dd HH-mm <event title>` (recording start time), or `yyyy-MM-dd HH-mm` with no event.
  The folder and the mix file use this name: `<name>/<name>.m4a`; per-source tracks keep their current names
  (`mic - <device>.m4a`, `computer audio.m4a`), plus `marks.txt`, `session.json`.
- While recording, the menu shows a **Name** field prefilled with the event title (empty without an event); the
  date prefix is not editable and is always added. The edited title is saved to `session.json` at once.
- The rename is applied at finalize: files are written into the original folder during recording; after encoding,
  the mix is named after the final title and the folder is renamed. The title also goes into the m4a title tag
  (visible in players). Crash recovery applies the saved title the same way.
- Sanitizing: `/` and `:` replaced, leading dots and control characters removed, whitespace trimmed, length capped
  at about 80 characters. Name collisions get " 2", " 3", ... as today.
- Calendar access: requested once on the first Record (Info.plist `NSCalendarsFullAccessUsageDescription`). Denied
  or unavailable -> date-only names, no error.

## Out of scope

Choosing among several events in the UI, renaming after the recording has finished, per-track file renaming.
