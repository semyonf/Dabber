# Dabber: screen snapshots and slideshow video

Date: 2026-09-28. Status: design approved in chat.

## Why

Work calls often show a screen (slides, demos, code). An audio-only recording loses that context. Recording real
video is not wanted. Instead, when the user turns on "Record slides", Dabber takes a screenshot every 2 seconds during the recording
and builds a video where the mix audio plays and each changed screen stays until the next change.

## Decisions

| Topic | Decision |
|---|---|
| Switch | Checkbox **Record slides** in the RECORDING section, off by default, saved in `UserDefaults`, locked while recording like the sources |
| When to capture | With the checkbox on: automatically, every 2 s, during the recording. No button, no hotkey |
| What to capture | The whole display under the mouse cursor (`ScreenCaptureKit`), without the cursor |
| Unchanged screen | Frame not stored |
| Temporary frames | HEIC via `ImageIO`, quality 0.8, scaled down to at most 1920 wide |
| Output | `<name>.mp4` (HEVC + the mix audio) next to `<name>.m4a`; the `.m4a` files are unchanged |
| Separate images | Not kept: temporary frames are deleted after the video is built |
| Checkbox off, or no frames stored | No `.mp4`, no capture, no Screen Recording prompt; everything as before |

## Behaviour

### Capture

- Runs only when **Record slides** was on at Record. Starts with the recording, stops with it. A timer fires every 2 s and captures the display that contains the
  mouse cursor at that moment.
- The frame is scaled to at most 1920 wide (even dimensions). Then it is compared with the last stored frame on a
  small grayscale thumbnail; if the difference is below a small threshold, the frame is dropped. The threshold
  is chosen so a blinking text caret or a changing clock does not count as a change. A display switch (cursor moved
  to another monitor) always counts as a change.
- A changed frame is written at once as HEIC into `frames/` in the session folder, named by elapsed nanoseconds.
  Its time and file name are added to `session.json` at once, like marks, so crash recovery also builds the video.
- A capture that takes longer than 2 s does not queue up: the next tick is skipped while one is still running.
- With the checkbox on, the menu shows one status line under it: "Screen: on" while it works, "Screen: no permission" or
  "Screen: error" otherwise. Capture problems never stop or affect the audio recording.

### Video (on finalize)

- Runs after the mix `.m4a` is written and has its chapters, only if the manifest lists frames whose files exist.
- Built with `AVAssetWriter` into `mix.mp4`, renamed to `<name>.mp4` together with the mix in `Finalizer.rename`.
- Audio: the AAC samples of the mix `.m4a` are copied without re-encoding (passthrough).
- Video: HEVC, tagged `hvc1` so QuickTime Player and iPhone play it. One video sample per stored frame at its capture time. Each sample lasts until the next frame; the
  last one lasts until the end of the audio. A black frame covers 0:00 up to the first frame.
- Frame size: the first frame's size. Frames of another size (another monitor) are scaled to fit with black bars.
- Chapters and the title tag: the same as the mix `.m4a` (reuse `ChapterWriter`).
- After a successful build `frames/` is deleted. If the build fails, the `.m4a` files are still delivered, `frames/`
  is kept, and the error is written to `session.json` and shown in the menu.

## Disk use

While recording, only changed frames are stored: roughly 100 KB each. Worst case (screen changes all the time):
1800 frames per hour, about 180 MB per hour, next to about 1.4 GB per hour for Mac audio. The existing free-space
estimate adds this worst case. The finished `.mp4` is about the size of the mix plus the frames.

## Units

- `FrameDiff` (DabberCore, Model): thumbnail comparison, "changed or not". Tested with synthetic images.
- `FrameStore` (DabberCore): HEIC encoding, file naming, manifest records. Tested.
- `SlideshowWriter` (DabberCore, Finalize): audio file + list of (time, image) → `.mp4`. Tested with synthetic
  images and audio: duration, number of video samples and their times, audio sample count unchanged.
- `ScreenSampler` (Dabber app): the 2 s timer and `ScreenCaptureKit` capture of the display under the cursor.
  Hardware check only.

## Privacy

With **Record slides** on, everything on the chosen display goes into the video: notifications, chats, passwords
shown on screen. The README states this next to the checkbox description.

## Open checks

- Screen Recording permission: expected to be a new prompt, separate from System Audio Recording. Check on the first
  recording; update the README permission table.
- HEIC frame size and encode time at quality 0.8 on real screenshots.
- Diff threshold on real screens (caret, clock, video playing in a call).
- HEVC `.mp4` playback in QuickTime Player, VLC, iPhone Files and Telegram. If a target that matters cannot play
  it, fall back to H.264 (the frames are few, so the size difference is small).
- A frame that stays on screen for many minutes: check playback and seeking in QuickTime Player and VLC. If either
  misbehaves, repeat the current frame every few seconds (identical frames cost almost nothing).

## Out of scope

Manual capture, hotkeys, window capture, choosing the display, keeping frames as separate images,
frames in the per-source track files.
