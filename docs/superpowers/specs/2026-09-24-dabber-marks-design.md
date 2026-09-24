# Dabber: marks and chapters

Date: 2026-09-24. Status: design approved in chat.

## Why

During a recording (a call, a session) the user wants to mark important moments with an optional short comment
and later jump to them in the player, like a table of contents.

## Decisions

| Topic | Decision |
|---|---|
| Players | QuickTime Player, IINA/VLC, iPhone (Files/other apps via iCloud) |
| Mark time | Exactly the moment the Mark button is pressed (no pre-roll); typing the comment afterwards does not move it |
| Input | Menu only (no global hotkey) |
| Comment | Optional; empty marks are titled "Mark N" |

## Behaviour

- While recording, the RECORDING section shows a **Mark** button. Pressing it captures the time immediately and
  shows a "Comment (optional)" field for that mark; Enter saves the text. Below, the list of this session's
  marks (elapsed time + text), each removable.
- Each mark is persisted into `session.json` at once (host time converted to the session timeline), so marks
  survive a crash and are used by crash recovery.
- On finalize, marks become chapters in every `.m4a` of the session (mix and tracks): a first chapter "Start" at
  0:00, then one chapter per mark in time order. Marks outside the recorded range are clamped.
- A `marks.txt` next to the files lists `HH:MM:SS  text` per mark, as a fallback for players that ignore chapters.

## Chapter format

Unknown which writing method is visible in all three players. A spike comes first: write test `.m4a` files with
chapters (a) with Apple frameworks only (e.g. AVMutableMovie / AVAssetWriter chapter-list track association),
(b) with ffmpeg (`-map_metadata` chapters), and check QuickTime Player, IINA/VLC and iPhone Files. Prefer (a)
if it works everywhere; ffmpeg is not bundled with Dabber.

## Out of scope

Global hotkey, editing mark times, marks in the virtual mic, pre-roll offset.
