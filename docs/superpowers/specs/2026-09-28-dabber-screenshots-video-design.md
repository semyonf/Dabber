# Dabber: screenshots and slideshow video

Date: 2026-09-28. Status: design approved in chat.

## Why

Work calls often show a screen (slides, demos, code). An audio-only recording loses that context. Recording real
video is not wanted. Instead the user takes screenshots by hand during the recording, and Dabber builds a video
where the mix audio plays and each screenshot stays on screen until the next one.

## Decisions

| Topic | Decision |
|---|---|
| When to capture | Manual only: a Screenshot button in the menu and a global hotkey |
| Hotkey | Configurable in the menu, default `⌃⇧S`; own code (Carbon `RegisterEventHotKey` + `NSEvent`), no dependencies |
| What to capture | The whole display under the mouse cursor (`ScreenCaptureKit`) |
| Output | `<name>.mp4` next to `<name>.m4a`; the `.m4a` files are unchanged |
| Separate images | Kept as PNG in `screenshots/` inside the recording folder |
| No screenshots | No `.mp4`; everything as before |

## Behaviour

### Capture

- While recording, the RECORDING section shows a **Screenshot** button next to **Mark**, and a counter
  "Screenshots: N" once there is at least one.
- The global hotkey does the same. It is registered only while a recording runs, so it does not take the key
  combination away from other apps the rest of the time.
- The capture time is the moment of the button or hotkey press. A short system sound confirms the capture.
- The PNG is written at once into the session folder as `screenshots/HH-MM-SS.png` (elapsed recording time; if two
  land in the same second, `HH-MM-SS 2.png`). Its time and file name are added to `session.json` at once, like
  marks, so crash recovery also builds the video.
- Failure (no Screen Recording permission, capture error): the menu shows a message, the recording continues.

### Hotkey setting

- The menu shows a line **Hotkey: ⌃⇧S  Change…**, styled like the Folder line. It can be changed only when not
  recording.
- **Change…** waits for the next key combination. `Esc` cancels. The combination must include `⌘`, `⌃` or `⌥`, or
  be a single F-key; otherwise it is ignored and the line keeps waiting.
- The choice is saved in `UserDefaults`. If registration fails at Record (combination taken by another app), the
  menu says so; the Screenshot button still works.

### Video (on finalize)

- Runs after the mix `.m4a` is written and has its chapters, only if the manifest lists screenshots whose files
  exist.
- Built with `AVAssetWriter` into `mix.mp4`, renamed to `<name>.mp4` together with the mix in
  `Finalizer.rename`.
- Audio: the AAC samples of the mix `.m4a` are copied without re-encoding (passthrough).
- Video: H.264. One frame per screenshot at its capture time. Each frame lasts until the next screenshot; the last
  one lasts until the end of the audio. A black frame covers 0:00 up to the first screenshot.
- Frame size: the first screenshot's size, scaled down to at most 1920 wide (even dimensions). Other screenshots are
  scaled to fit with black bars.
- Chapters and the title tag: the same as the mix `.m4a` (reuse `ChapterWriter`).
- If building the video fails, the `.m4a` files are still delivered; the error is written to `session.json` and
  shown in the menu.

## Units

- `ScreenshotStore` (DabberCore): file naming, manifest records. Tested.
- `SlideshowWriter` (DabberCore, Finalize): audio file + list of (time, image) → `.mp4`. Tested with synthetic PNGs
  and audio: duration, number of video samples and their times, audio sample count unchanged.
- `ScreenGrabber` (Dabber app): `ScreenCaptureKit` capture of the display under the cursor. Hardware check only.
- `HotkeyCenter` + hotkey recorder row (Dabber app): registration and the Change… flow. Hardware check only.

## Open checks

- Screen Recording permission: expected to be a new prompt, separate from System Audio Recording. Check on first
  capture; update the README permission table.
- Carbon `RegisterEventHotKey` is expected to work without the Accessibility permission. Check on the real Mac.
- A frame that stays on screen for many minutes: check playback and seeking in QuickTime Player and VLC. If either
  misbehaves, repeat the current frame every few seconds (identical frames cost almost nothing).

## Out of scope

Automatic or timed capture, window capture, choosing the display, screenshots in the per-source track files,
editing or deleting screenshots from the menu.
