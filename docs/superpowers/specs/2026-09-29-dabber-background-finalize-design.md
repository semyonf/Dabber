# Dabber: finalize in the background

Date: 2026-09-29. Status: feature approved in chat; the details below were chosen during implementation.

## Why

Calls often follow each other. Today after Stop the Record button stays disabled ("Finalizing…") until the AAC
encode, the chapters, the slides video and the delivery are done, which takes minutes for a one-hour call. The next
call must be recordable right away.

## Decisions

| Topic | Decision |
|---|---|
| Stop | Stops the engine ("Stopping…", a second or two), queues the finalize, then the button is "● Record" again |
| Queue | Finalizes run one at a time, in the order the recordings stopped |
| Menu | One line under the Record row while finalizes are pending: "Finishing: &lt;folder name&gt;…" for one, "Finishing N recordings…" for several |
| Show last recording | Points to the recording that finished last |
| Priority | The finalize runs at `.utility`, and so do the dispatch queues it creates; the launch recovery too |
| Quit | Waits for a running stop and for all queued finalizes ("Finalizing before quit…"), as before |
| Crash | Unchanged: sessions without a finalize report are finished at the next launch |
| Warnings of a finished recording | Shown as before (not prefixed with the folder name) |
| Errors | A finalize error stays in the menu until the next Record; a successful finalize no longer clears the error line, so it cannot hide a start error or an earlier failure |

## Behaviour

- `SessionRecorder` is free again as soon as `stop()` returns, and session folders are unique, so a new session can
  start while older folders are being finalized in the same work folder. Delivery only touches folders whose manifest
  has a finalize report, so the live session is never moved.
- The model keeps a list of pending folders and the last queued finalize task. Each new finalize is a detached
  `.utility` task that first waits for the previous one, runs `finalize(dir, output)`, then reports back on the main
  actor. The model never awaits the finalize itself during normal use, so a user-initiated task does not raise its
  priority; only Quit (and tests) wait for it.
- A session that stopped itself (disk full, write error) is queued the same way.
- A second Stop, or Quit, during a stop waits for that stop instead of stopping twice.
- After a stop the model ticks at once, so a session that stopped itself just before Stop or Quit (and was not
  noticed yet) is queued too.

## Proof that the live recording does not lose audio

An experiment (not in the regular suite) finalizes a large synthetic session while three simulated live sources
push IOProc-sized buffers into `RingBuffer` + `TrackWriter` at real-time rate. It counts ring overruns (target 0),
compares the captured frame counts with the pushed ones, and measures how old a buffer is when it is drained.

Results on a Mac17,3 (10 cores), 3 live lanes (stereo + 2 mono, 512-frame buffers from a real-time thread):

| Finalize | Session | Finalize time | Overruns | Frames lost | Oldest buffer at drain |
|---|---|---|---|---|---|
| model path, `.utility` | 30 min × 3 tracks + 180 slides (1.4 GB) | 138 s | 0 | 0 | 53 ms |
| `.userInitiated` (for comparison) | same | 96 s | 0 | 0 | 53 ms |
| model path, `.utility`, 10 busy threads at default QoS | 5 min × 3 tracks + 30 slides | 642 s | 0 | 0 | 112 ms |

The ring holds 256 buffers (about 2.7 s at 512 frames, 48 kHz), so the drain has a wide margin. The price of
`.utility` is a slower finalize: about 40 % slower on an idle Mac, and much slower while other apps keep every core
busy.

## Out of scope

Cancelling a queued finalize, parallel finalizes, showing progress in percent.
