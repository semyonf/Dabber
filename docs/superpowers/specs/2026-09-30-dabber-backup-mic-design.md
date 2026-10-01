# Dabber: backup microphone

Date: 2026-09-30. Status: feature approved in chat; the details below were chosen during implementation.

## Why

During a call the AirPods ran out of battery. The AirPods track waited for the device ("waiting for device") and the
voice was not recorded at all until the end of the call. When a recorded microphone disappears, Dabber should record
another microphone until it comes back.

## Decisions

| Topic | Decision |
|---|---|
| Setting | "Backup mic:" picker in the RECORDING section: None or one input device (not "Dabber Mic"). It also works while recording (see "Change while recording"). Enabled (recorded) microphones carry a "(recorded)" suffix, since such a choice disables the backup for that session; while recording, so does the default microphone recorded as the fallback |
| Default | On first launch the Mac's built-in microphone (CoreAudio transport type built-in), None if there is none. The default is not saved until the user picks something, so it is found again at every launch until then |
| Saved | UserDefaults key `backupMic`: the UID, or an empty string for None. Its name is kept with the source names, for the menu while the device is absent |
| Trigger | While recording, some recorded microphone (not Mac audio) is waiting for its device or has failed, and it has run in this session (was running at a status poll or has a segment). A microphone absent at Record, including the case with the fallback to the default microphone, does not trigger the backup until it has run |
| Not a trigger | Mac audio in any state; a microphone that is restarting (a short, normal state) |
| Back to normal | Every recorded microphone has been running continuously for 2.5 s (`BackupPolicy.settleSeconds`, measured with the `now` passed to `status(at:)`): the backup pauses. The next loss resumes it |
| Restarting or stopped (sleep) microphones | Keep the backup as it is: on stays on, off stays off |
| Track | `mic - <name> (backup).m4a`, one track per backup device for the whole session; pauses are silent gaps. It is marked `"backup": true` in `session.json` (absent in older manifests) |
| Change while recording | `RecorderModel.setBackup` saves the choice as before and passes the spec to `RecordingEngine.setBackup` (nil for None or a microphone recorded in this session), then polls at once. If the backup is off, the engine only replaces the spec, used at the next loss. If it is on, it stays on: the engine queues a pause of the old source and then the start of the new device on the backup queue, so the new device starts in its own track at once, also while the lost microphone is restarting. During sleep only the pause is queued; the first poll after wake starts the new device. The old source stays in the session with its segments, paused. A device that already has a backup source in this session reuses it (resume with the reason "backup"), so there is never a second track for the same UID. None, or a device recorded as a normal source, turns the backup off until another device is chosen. A choice made while Record is starting is applied right after the start: the model computes the spec again and passes it to the engine if it changed |
| Several backup tracks | Status, warnings and retries follow the current backup only. Every backup source is excluded from sleep and wake of the normal sources: wake resumes only the current backup and only if it is on, so former backups stay paused. `stop()` stops every source, backups included; a backup source without segments is still dropped from `session.json`. All backup tracks are left out of the 1/N mix gain. `SourceSnapshot.backup` marks every backup source, and the model shows no lost-microphone warning for them |
| Mix | The backup goes into the mix at the same gain as the other tracks but is not counted in the 1/N gain: it replaces a lost microphone, so using it does not make the whole mix quieter |
| Session without a loss | No backup track: the backup joins `session.json` and the recording only at its first use. A backup that joined but never recorded a segment (for example every start failed) is removed from `session.json` at stop, so no silent full-length track appears |
| Already recorded | A backup that is also a recorded source (same UID) is ignored for that session, including the fallback to the default microphone at Record |
| Not connected when needed | Not started; the menu says "Backup mic &lt;name&gt; not connected". The presence check runs on the backup queue, at most every 2 s (`BackupPolicy.retrySeconds`), and the backup starts once it appears while still needed |
| Start failed | Reported as "Backup mic &lt;name&gt; failed (…)". While the backup is needed, a start that failed (or a source that failed later) is retried on the backup queue at most every 2 s. A backup that never started is never reported as recording. After a failure, a restarting backup is reported with that failure, not as recording, until it runs again |
| Sleep | Sleep pauses every source; wake resumes the backup only if it is in use. The backup's pause and resume go through the backup queue, after any queued start, and no new backup work is queued while asleep |
| Warnings | "&lt;mic&gt;: waiting for device — recording &lt;backup&gt; (backup)" (and the same after "failed (…)"); "Backup mic &lt;name&gt; not connected"; "Backup mic &lt;name&gt; failed (…)"; "&lt;backup&gt;: no signal for 10 s" as for any running microphone; "Recording &lt;backup&gt; (backup)" when the backup records and no lost-microphone warning names it (for example while the microphones settle) |
| Absent at Record | "&lt;mic&gt; not connected" stays until the microphone runs or restarts; a microphone stopped by sleep still counts as absent |
| Start | Unchanged: if no enabled microphone is connected at Record, the system default microphone is recorded, as before |

## Behaviour

- `BackupPolicy.active(_:was:)` is a pure function: given the statuses of the recorded microphones and whether the
  backup is on now, it says whether the backup should be on.
- `BackupPolicy.active(_:was:calmFor:)` also takes how long every microphone has been running, for the 2.5 s settle
  time.
- `SessionRecorder.start(specs:backup:…)` remembers the backup spec. `status(at:)`, which the app polls every 0.2 s,
  applies the policy under the recorder lock and only decides: turn the backup on or off. Everything slow runs on a
  private serial backup queue, not on the caller's thread, so the menu does not wait for CoreAudio: the presence
  check, creating the source, saving the manifest, and the device calls (`start`, `pause`, `resume`). The source is
  appended to `sources` and to the manifest together, under the lock, so its index for `segmentsChanged` is stable.
  While an operation is queued, the backup is reported as recording; once it is done, the source status decides. A
  resume on this queue (also after wake) waits until the source has handled it, so a poll never sees the source still
  stopped with nothing queued.
  `stop()` first moves the phase to stopping (no new decisions after that), then drains this queue, then stops every
  source, so a backup that was just started is stopped too.
- A resume continues the same track: a new segment starts later, and the finalizer places it on the session timeline
  with silence in the pause, as for any restart. The resume is logged as a restart with the reason "backup".
- `RecorderStatus.backup` reports `.off`, `.recording`, `.missing` or `.failed(reason)`. The model turns it into the
  warnings above. The backup device's row shows its level while the backup is part of the session.

## Units

- `BackupPolicy` (Engine): pure. Tested.
- `SessionRecorder`: activation, settle time, absent-at-start microphones, pause, resume, naming, manifest, missing
  device, slow presence check, sleep and wake (also during a start), stop, a backup that never recorded, a change of
  the backup while it is off, while it records, during its start, back to a former backup, to None and to a recorded
  microphone, stop and wake with two backup sources. Tested with
  fake sources; the pause and resume path and the retry of a failed start are also tested through `CaptureSource`
  with fake device hooks.
- `Finalizer`: a track that starts late and has a gap is placed on the timeline; one or two backup tracks do not lower
  the mix level. Tested.
- `RecorderModel`: setting, first-launch default, persistence, the change while recording, the "(recorded)" marks, the spec passed to the
  engine, warnings (also for a microphone that was absent at Record, came back and was lost again). Tested with a
  fake engine.
- `InputDevice.builtIn` (transport type) and the picker in the menu: hardware check only.

## Out of scope

More than one backup at a time, a backup for Mac audio, switching to the backup on silence (no signal) instead of on a lost
device, choosing the backup per recording.
