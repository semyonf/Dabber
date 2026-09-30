# Dabber: backup microphone

Date: 2026-09-30. Status: feature approved in chat; the details below were chosen during implementation.

## Why

During a call the AirPods ran out of battery. The AirPods track waited for the device ("waiting for device") and the
voice was not recorded at all until the end of the call. When a recorded microphone disappears, Dabber should record
another microphone until it comes back.

## Decisions

| Topic | Decision |
|---|---|
| Setting | "Backup mic:" picker in the RECORDING section: None or one input device (not "Dabber Mic"); locked while recording |
| Default | On first launch the Mac's built-in microphone (CoreAudio transport type built-in), None if there is none. The default is not saved until the user picks something, so it is found again at every launch until then |
| Saved | UserDefaults key `backupMic`: the UID, or an empty string for None. Its name is kept with the source names, for the menu while the device is absent |
| Trigger | While recording, some recorded microphone (not Mac audio) is waiting for its device or has failed |
| Not a trigger | Mac audio in any state; a microphone that is restarting (a short, normal state) |
| Back to normal | Every recorded microphone runs again: the backup pauses. The next loss resumes it |
| Restarting or stopped (sleep) microphones | Keep the backup as it is: on stays on, off stays off |
| Track | `mic - <name> (backup).m4a`, one track for the whole session; pauses are silent gaps. It goes into the mix like any source |
| Session without a loss | No backup track: the backup joins `session.json` and the recording only at its first use |
| Already recorded | A backup that is also a recorded source (same UID) is ignored for that session, including the fallback to the default microphone at Record |
| Not connected when needed | Not started; the menu says "Backup mic &lt;name&gt; not connected". It starts as soon as it appears while still needed |
| Sleep | Sleep pauses every source; wake resumes the backup only if it is in use |
| Warnings | "&lt;mic&gt;: waiting for device — recording &lt;backup&gt; (backup)" (and the same after "failed (…)"); "Backup mic &lt;name&gt; not connected"; "Backup mic &lt;name&gt; failed (…)"; "&lt;backup&gt;: no signal for 10 s" as for any running microphone |
| Start | Unchanged: if no enabled microphone is connected at Record, the system default microphone is recorded, as before |

## Behaviour

- `BackupPolicy.active(_:was:)` is a pure function: given the statuses of the recorded microphones and whether the
  backup is on now, it says whether the backup should be on.
- `SessionRecorder.start(specs:backup:…)` remembers the backup spec. `status()`, which the app polls every 0.2 s,
  applies the policy under the recorder lock and decides: create the backup source (first use), resume it or pause
  it. The source is appended to `sources` and to the manifest together, under the lock, so its index for
  `segmentsChanged` is stable. The device calls (`start`, `pause`, `resume`) run on a private serial queue, not on
  the caller's thread, so the menu does not wait for CoreAudio. `stop()` first moves the phase to stopping (no new
  decisions after that), then drains this queue, then stops every source, so a backup that was just started is
  stopped too.
- A resume continues the same track: a new segment starts later, and the finalizer places it on the session timeline
  with silence in the pause, as for any restart. The resume is logged as a restart with the reason "backup".
- `RecorderStatus.backup` reports `.off`, `.recording`, `.missing` or `.failed(reason)`. The model turns it into the
  warnings above. The backup device's row shows its level while the backup is part of the session.

## Units

- `BackupPolicy` (Engine): pure. Tested.
- `SessionRecorder`: activation, pause, resume, naming, manifest, missing device, sleep and wake, stop. Tested with
  fake sources.
- `Finalizer`: a track that starts late and has a gap is placed on the timeline. Tested.
- `RecorderModel`: setting, first-launch default, persistence, lock, the spec passed to the engine, warnings. Tested
  with a fake engine.
- `InputDevice.builtIn` (transport type) and the picker in the menu: hardware check only.

## Out of scope

More than one backup, a backup for Mac audio, switching to the backup on silence (no signal) instead of on a lost
device, choosing the backup per recording.
