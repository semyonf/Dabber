# Dabber: choosing where recordings go

Date: 2026-09-24. Status: design approved in chat.

## Behaviour

- Recording always writes into a local work folder: `~/Library/Application Support/Dabber/Sessions/<session>/`
  (not synced by iCloud). Intermediate CAFs (~2 GB/h) never touch the chosen output folder.
- After finalize (chapters, title tag, rename), the finished files (`<name>.m4a`, per-source m4a, `marks.txt`,
  `session.json`) are moved into the chosen output folder as `<output>/<name>/`. Name collisions get " 2", ...
  Moving across volumes (e.g. iCloud Drive, external disk) is a copy + verify + delete of the source.
- Output folder: default `~/Recordings/Dabber` (existing sessions stay there). Menu RECORDING section shows
  `Folder: <display name>` and a **Change…** button opening an NSOpenPanel (directories only, create allowed).
  The choice persists in UserDefaults (path; app is not sandboxed).
- If the output folder is unavailable or the move fails, the finished session stays in the work folder, the menu
  warns (`Saved in the local folder: <reason>`), and the move is retried on the next launch and after the next
  finalize. Nothing is deleted from the work folder until the copy is verified.
- Crash recovery scans the work folder (and, once, the old `~/Recordings/Dabber` for unfinished sessions left by
  earlier versions), finalizes, then moves as above.
- "Show last recording" reveals the session where it finally is.
- Disk-space check applies to the work folder's volume (where CAFs grow).

## Out of scope

Per-session folder choice, moving already finished sessions between folders, cleaning up old sessions.
