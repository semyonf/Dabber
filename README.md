# Dabber

[Русская версия](README.ru.md)

Dabber is a small macOS menu bar app that records what your Mac plays and what your microphones hear.

- Mac audio and every chosen microphone are recorded as **separate tracks**, plus a stereo **mix** of all of them.
- A microphone that disconnects during a recording (for example AirPods taken out of your ears or put in the case)
  does not stop the recording: Dabber waits for the device and continues when it comes back.
- **Backup microphone**: while a recorded microphone is lost, Dabber records a backup microphone (by default the
  Mac's built-in one) into its own track, so your voice is not lost when AirPods run out of battery.
- If an enabled microphone stays silent for 10 seconds while the Mac is playing sound, the menu bar icon shows a
  warning, so a lost microphone is noticed during the recording, not after it.
- **Marks**: press Mark at an important moment and optionally type a comment. Marks become chapters in the
  recorded files and are also saved to `marks.txt`.
- **Slides** (optional): with "Record slides" on, Dabber takes a screenshot every 2 seconds and, after Stop, makes a
  video: the mix plays, and each change of the screen stays in the picture until the next change. No screen video
  is recorded. The screenshot can be the whole screen, one window (kept while you switch desktops) or an area.
- **Clean microphones** (on by default): after Stop, the microphone tracks lose the call audio that the mic heard from
  the Mac's speakers (echo), background noise and the room's reverb, with a small neural model on your Mac.
- **Transcript** (on your Mac): text and subtitles for every recording, with «Я» and «Собеседники».
- **Names from the calendar**: a recording is named after the calendar event that is on (or starts within 15 minutes).
  You can change the name while recording.
- You choose the folder where finished recordings go.
- **Virtual microphone "Dabber Mic"** (optional): call apps, OBS or screen recorders can pick "Dabber Mic" as their
  microphone and receive your Mac audio mixed with your real microphone. Chosen apps (Safari by default) are left
  out of it so the other side of a call does not hear itself.

Why it exists: other recorders sometimes lost the microphone track, for example when AirPods switched into call
mode in the middle of a recording, and this became visible only after the call. Dabber records each source
independently and warns while recording.

Dabber is built from source on your Mac. There is no prebuilt download.

## Requirements

- **macOS 26 or later** (`LSMinimumSystemVersion` 26.0).
- **A Mac with Apple Silicon.** The virtual microphone driver is built for `arm64` only. The app has not been tried
  on Intel Macs.
- **Command Line Tools for Xcode.** Install them in Terminal with `xcode-select --install`. The full Xcode app is
  not needed.
- **Disk space:** about 1.5 GB for the Command Line Tools and up to about 1 GB for the build folders inside the
  repository. While recording, Dabber keeps uncompressed audio in a temporary folder: about 1.4 GB per hour for Mac
  audio and about 0.7 GB per hour per microphone, plus up to about 500 MB per hour for slides. A recording does not
  start with less than 2 GB free, and the menu warns when less than about 20 minutes of recording space is left.
  Finished files are much smaller (compressed AAC). The speech model takes about 470 MB. While a recording is
  transcribed, temporary files take about 0.5 GB per hour of stereo audio. If Dabber crashes during a transcription,
  it removes these files at a later launch, once they are more than an hour old.

### Permissions the app asks for

| Permission | When it is asked | Why |
| --- | --- | --- |
| Microphone | First recording (or virtual mic use) with a microphone | To record your microphones |
| System Audio Recording | First recording (or virtual mic use) with Mac audio | To record sound played by other apps |
| Input Monitoring | First recording | To notice a double tap of the left Option key (the Mark hotkey). Dabber only listens and only while recording. If you decline, use the Mark button |
| Screen Recording | First recording with Record slides on | To take the screenshots for the slides video |
| Calendars (full access) | First recording | To read the title of the current event and name the recording after it. Dabber only reads events. If you decline, recordings are named by date and time |

## Install

Open Terminal and run the commands below one by one.

1. Get the code and go into its folder:

   ```sh
   git clone https://github.com/semyonf/Dabber.git dabber
   cd dabber
   ```

2. Create the signing certificate (once per Mac):

   ```sh
   scripts/make-cert.sh
   ```

   This creates a self-signed code signing certificate named "Dabber Dev" in your login keychain and marks it as
   trusted for code signing. macOS asks for your password to change the trust settings. Nothing is sent anywhere.

   Why it is needed: macOS remembers the Microphone and System Audio permissions per signed app. With a stable
   certificate the permissions you grant survive every rebuild and update. Without it you would be asked again
   after each build. If the certificate already exists the script says so and does nothing.

3. Build and install the app:

   ```sh
   scripts/install-app.sh
   ```

   This builds Dabber, signs it with "Dabber Dev" and copies it to
   `/Applications/Dabber.app`. If Dabber is running, the script quits it first and waits until it has finished its
   recordings, at most 10 minutes; if Dabber is still running then, the script stops without replacing it. It refuses
   to overwrite a different app with the same name.

4. Start Dabber from Applications or Spotlight. It has no Dock icon and no window: look for the waveform icon in the
   menu bar and click it.

5. Press **● Record** once to trigger the permission prompts and allow them. You can check them later in System
   Settings > Privacy & Security.

### Optional: the virtual microphone

```sh
scripts/install-driver.sh
```

Run it **without** `sudo`: the script builds and signs the driver with your certificate, then asks for your
password itself to copy `DabberMic.driver` into `/Library/Audio/Plug-Ins/HAL/`. After that it restarts the macOS audio
service, so **all sound stops for a few seconds**.

To check: open System Settings > Sound > Input. "Dabber Mic" should be in the list. In the Dabber menu the
VIRTUAL MIC section no longer says "Driver not installed". If it still does, quit Dabber (Quit in its menu) and start
it again.

## Usage

### Recording

1. Click the menu bar icon. The RECORDING section lists **Mac audio** and every microphone. On first launch Mac audio
   and the system default microphone are switched on. Switch sources on or off with their checkboxes (not possible
   while recording). A device that is enabled but absent is shown as "(not connected)".
2. Press **● Record**. The menu bar icon changes to a record symbol and a timer runs. Each source shows a level bar.
3. Press **■ Stop**. The button shows "Stopping…" for a second or two, then "● Record" again: the next recording can
   start right away. Dabber encodes the files in the background and then moves the recording to the output folder.
   Meanwhile the menu shows "Finishing: <folder name>…" under the button, or "Finishing N recordings…" when several
   are waiting. They are finished one at a time, in the order they were stopped. **Show last recording** opens the
   one finished last in Finder.

If you quit Dabber during a recording or while recordings are still finishing, it finishes all of them first
("Finalizing before quit…"). This includes recordings that Dabber finishes at launch after it was closed unexpectedly;
for those it may first wait up to a minute for the speech model to load. Finishing includes the transcript: once the
speech model is loaded, it takes about 15 seconds per hour of audio for each track.

Each recording is a folder named `YYYY-MM-DD HH-MM <name>` (only the date and time if there is no name). If a folder
with that name already exists, a number is added. Inside:

```
2026-09-24 14-00 Weekly sync/
  2026-09-24 14-00 Weekly sync.m4a   the mix of all sources (stereo)
  computer audio.m4a                 Mac audio (stereo)
  mic - AirPods.m4a                  one file per microphone (mono)
  mic - MacBook Air Microphone (backup).m4a
                                     only if the backup microphone was used (mono)
  2026-09-24 14-00 Weekly sync.mp4   only with Record slides: the mix with the screen as slides
  marks.txt                          only if you made marks
  transcript.txt                     the text with times, speakers and marks, if transcription worked
  transcript.srt                     the same text as subtitles for any player
  session.json                       technical details: sources, gaps, restarts
```

If none of the microphones you enabled is connected when you press Record, Dabber records the system default
microphone instead and says so, for example "AirPods not connected — recording MacBook Air Microphone". If some
enabled microphones are connected and others are not, it records the connected ones and names the missing ones.

### Backup microphone

**Backup mic:** under the sources chooses a microphone that takes over while a recorded microphone is lost, or None.
On first launch it is the Mac's built-in microphone (None if the Mac has none). Microphones you record are marked
"(recorded)" in this list: a recorded microphone does not serve as the backup.

When a recorded microphone disappears during a recording (for example AirPods run out of battery) or fails, Dabber
starts recording the backup microphone into its own track `mic - <name> (backup).m4a`. The menu says so, for example
"AirPods: waiting for device — recording MacBook Air Microphone (backup)". When every recorded microphone has worked
again for a few seconds, the backup pauses; if a microphone is lost again, the backup continues in the same track. The
pauses are silence in that track. The backup track is also part of the mix, at the level of the microphone it
replaces, so the mix does not get quieter. Losing Mac audio does not start the backup.

A microphone that was not connected when you pressed Record starts the backup only if it connects, records and is
lost again. A recording in which the backup never recorded has no backup track. If the backup microphone is itself
one of the recorded microphones, it is not used as a backup in that recording. If the backup cannot start, the menu
says "Backup mic <name> failed (…)" and Dabber tries again every few seconds. If it is needed but not connected, the
menu says "Backup mic <name> not connected", and Dabber starts it as soon as it appears.

You can change the backup microphone while recording. If the backup is not recording at that moment, the new choice is
used at the next loss. If it is recording, the old backup pauses and the new microphone takes over at once in its own
track, for example `mic - USB (backup).m4a`. Switching back to a microphone that already has a backup track in this
recording continues that track. Choosing None or a recorded microphone turns the backup off for the rest of the
recording, until you choose another microphone. Every backup track that recorded something stays in the recording and in
the mix.

### Marks

While recording, press **Mark**. A comment field appears; type a short note and press Return, or leave it empty.
Marks without a comment are called "Mark 1", "Mark 2" and so on. The list under the button shows the time of each
mark; the minus button removes one.

**Hotkey:** double-tap the left Option key (⌥⌥) to make a mark without opening the menu. A short sound confirms
it; type the comment later in the menu if you want one. It works only while recording, and only a quick double tap
of the left Option key alone counts (Option with a letter never makes a mark). It needs the Input Monitoring
permission; without it the menu says "Allow Input Monitoring for the ⌥⌥ hotkey" (System Settings > Privacy &
Security > Input Monitoring, then quit and start Dabber again).

After Stop, marks become chapters (plus a first chapter "Start" at 0:00) in the mix and in the track files.
Chapters were checked in QuickTime Player, Preview and VLC (IINA and iPhone apps were not checked). The same
marks are written to `marks.txt` as `HH:MM:SS  comment` lines.

### Slides

Turn on **Record slides** under the sources before you press Record (it cannot be changed while recording). While
recording, Dabber takes a screenshot of the display with the mouse pointer every 2 seconds. A screenshot is kept only
when the screen has changed; a blinking text cursor or the menu bar clock does not count. The pointer itself is not
in the picture.

**Show:** under the switch chooses what the screenshots show. It can be changed while recording; the next screenshot
uses it.
- **Whole screen** (default): the display with the mouse pointer.
- **A window** from the list (windows of all desktops): only that window, even when other windows cover it or you
  swipe to another desktop (Space). A minimized window is not captured. Some apps, browsers among them, stop
  redrawing a window nobody sees, so it may stay frozen until you come back to it. If the window is closed, the menu
  says "Screen: the chosen … window is closed" and no screenshots are taken until you choose something else.
- **Area…**: the screen dims; drag a rectangle on any display (Esc cancels). With **Area follows when you switch
  desktops** on (default), it is that part of whatever the display shows, so it goes along when you swipe to another
  desktop. Off, it keeps showing the desktop where you chose it while you work on another one: Dabber captures each
  window of that desktop by itself and puts them together, over a dark background instead of the wallpaper. macOS
  does not tell apps which desktop a window is on, so Dabber takes the windows that were on screen when you chose the
  area, and updates the list whenever you are back on that desktop.

After Stop, Dabber makes `<name>.mp4` next to the mix: the same sound, HEVC video at the screen's own resolution (3456 pixels wide at most), the same
chapters. Each kept screenshot is shown until the next one; the first one is shown from 0:00. The screenshots
are deleted after the video is made. If the video could not be made, the menu says "Slides video failed: …", the
audio files are complete as usual, and the screenshots stay in the `frames` folder of the recording (HEIC files named
by nanoseconds since the start).

Everything in the chosen screen, window or area goes into the video: notifications, chats, passwords shown on
screen. Turn Record slides
off for recordings where this matters.

### Clean up microphones

Without headphones the microphone also hears the call from the Mac's speakers, so the other side is recorded twice:
clean in the Mac audio track and late, with the room's echo, in the microphone track. With **Clean up microphones** on
(under the sources, on by default), Dabber removes this from every microphone track after Stop, before the files are
encoded, mixed and transcribed:

- **Echo of Mac audio.** Dabber measures how late the microphone hears Mac audio and gives both to
  [LocalVQE](https://github.com/localai-org/LocalVQE), a neural model for echo cancellation, noise suppression and
  dereverberation. While only the other side speaks, the microphone track goes quiet. When you speak at the same time,
  your voice stays. A microphone that does not hear Mac audio (headphones) gets only the noise and reverb removal.
- **Noise and room**: fans, hum, keyboard, traffic, and the echo of the room in your own voice.

The model works on 16 kHz sound, that is up to 8 kHz. What a good microphone records above that is kept from the
original track wherever the model kept your voice, and removed with the rest everywhere else. The model (about 19 MB)
is downloaded from Hugging Face in the background when the app starts with the switch on, or when you turn it on, and
is kept in `~/Library/Application Support/FluidAudio/Models/`. A recording stopped before it is loaded (the first one
after installing, or one made offline) is cleaned by the older built-in filter instead: an adaptive echo filter and
steady noise reduction, which leave some echo and a "bubbly" trace of it. Cleaning takes about a minute or two per hour
of each microphone on an Apple Silicon Mac.

`session.json` lists the cleaned tracks (`cleanedMics`), the measured delay (`echoDelayMillis`) and what cleaned them
(`micCleaner`: `LocalVQE`, or `MicCleaner` with the reason the model was not used). If the model fails part way,
the rest of that track is left as recorded and `micCleanerError` says so. The switch is read when a recording is finished, so it applies to recordings stopped after the
change. Turn it off to keep the microphone tracks exactly as recorded: the cleaning cannot be undone in the finished files.

### Transcript and subtitles

After Stop, Dabber transcribes the recording on your Mac with the Parakeet speech model. Nothing leaves the Mac.
Each source is transcribed on its own: microphones (the backup microphone too) are labelled «Я», Mac audio
«Собеседники». Stereo Mac audio is mixed down to mono first. Lines the model is unsure about (mean word confidence
below 0.6) are left out; this removes phrases the model invents from near-silence on a quiet microphone.

When you use speakers instead of headphones, the microphone also hears Mac audio: words that repeat Mac audio are left
out of «Я». A lone word, or Mac speech the model heard differently through the microphone, may still slip through.

**Live transcript** (a switch under Transcribe, off by default): while recording, the menu shows the last eight lines,
so you can read what you just missed. A line appears about 8 seconds after it was said (each track is transcribed
in 6-second windows). The lines are only shown, not saved: the transcript written after Stop is made again from the
whole recording and is more accurate. Live lines of «Я» may repeat the other side when you use speakers. It uses the
same speech model; until the model is downloaded the menu says so. It can be turned on or off during a recording.

- `transcript.txt`: the text with times, speakers and your marks.
- `transcript.srt`: subtitles for any player. Both files are written next to the recording.
- In the slides video, a Russian subtitle track. It is off when the video opens: turn it on in QuickTime Player
  with View > Subtitles. If the subtitle track cannot be written, the video is kept without it and the menu says
  "Subtitles left out of the video: …".

If Transcribe is on, the model (about 470 MB) is downloaded and compiled in the background when Dabber starts. The
first time this takes about 2-5 minutes and needs the internet. The model is stored in
`~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml`. While the model loads, a line under the
Transcribe switch shows what is happening: "Downloading speech model… 37%" while the files download, then "Preparing
speech model…" while they are compiled for the Mac (the first time this can take several minutes). Once the model is
ready, the line says "Speech model ready". If a load fails, the line says "Speech model failed: …" with the reason,
and after the last allowed attempt it adds "Dabber will try again at the next launch." A recording that finishes
before the model is ready is delivered without a transcript, and the menu says "Transcript failed: the speech model is not
ready yet". If the model fails to load, the next recording also goes out without a transcript, and Dabber starts
loading the model again in the background. After three failed loads Dabber stops trying until it is restarted.
Network problems do not count toward the three: no connection, a stalled or rate-limited download, a server error.
They have a limit of their own: after ten of them Dabber also stops trying until it is restarted. A model file that
is missing on the server or in the cache counts toward the three. Recordings shorter than one second are not
transcribed. If the transcription of a recording was interrupted twice (a crash, a forced quit or a power loss),
Dabber does not try a third time: the recording is delivered without a transcript, and the menu says "Transcript
failed: not attempted: transcription did not finish twice".

The **Transcribe** switch under the sources turns transcription on and off. It is on by default. When it is off,
recordings are delivered without a transcript, and the menu shows no error about it. Dabber also does not load the
model at launch. Turning the switch on starts loading the model. Unlike Record slides, the switch can be changed
during a recording. Dabber reads it when it starts finishing a recording after Stop. Turning it off does not stop a
transcription that is already running.

If Dabber crashes while transcribing, the recording is not lost: after two unfinished attempts Dabber delivers it
without a transcript, as described above. If transcription crashes Dabber on every recording, turn Transcribe off.
If Dabber stops while the model is loading (a crash, a forced quit or a power loss), it turns Transcribe off at the
next launch, and the menu says "Transcribe turned off: the speech model stopped Dabber while loading. Turn it on to
try again." Recordings left unfinished from before are then delivered without a transcript. A normal Quit while the
model is loading does not turn Transcribe off.

For checks there is a headless command: `Dabber --transcribe <audio file>` prints the timed lines of one file.

### Recording names

When you press Record, Dabber looks at your calendars for an event that is going on or starts within the next 15
minutes (all-day events are ignored) and uses its title. The **Name** field shows the name during the recording;
you can type a different one or clear it. The name is applied when the recording is finished. The full recording
name is also written as the title tag of the mix file. The characters `/` and `:` in the name are replaced with `-`.

### Output folder

The **Folder** line shows where finished recordings go (default `~/Recordings/Dabber`). **Change…** picks another
folder, for example in iCloud Drive or on an external disk.

Dabber always records into `~/Library/Application Support/Dabber/Sessions` first and moves the finished recording to
the chosen folder only after it is complete. To another disk it copies, checks and then deletes the local copy. If
the folder is not available (for example the disk is ejected), the recording stays in the local folder, the menu
shows "Saved in the local folder: …", and Dabber tries again after the next recording and at the next launch.

### Virtual microphone

Requires the driver (see Install).

1. In the VIRTUAL MIC section turn the switch on.
2. **Mac audio**: send the sound your Mac plays. Under "except:" are the apps whose sound is left out. The default is
   Safari: if you take a call in Safari, the call's own sound (the other people's voices) would otherwise go back to
   them through Dabber Mic and they would hear themselves (echo). Add your call app with **+ app** if you use another
   one, remove an app with its minus button. Recordings are not affected by this list.
3. **Microphone**: choose the microphone to mix in, or None.
4. In Zoom, Google Meet, OBS, a screen recorder or any other app, choose **Dabber Mic** as the microphone.

The status line shows "Waiting for an app to use Dabber Mic" until an app opens it, then "Sending" with a level bar.
Dabber only opens your real microphone while some app is using Dabber Mic. The virtual microphone works with or
without a recording running.

## Updating

```sh
cd dabber
git pull
scripts/install-app.sh
```

Permissions stay as long as the "Dabber Dev" certificate is kept. If `git pull` changed anything under `Driver/`,
run `scripts/install-driver.sh` again.

## Uninstalling

1. Quit Dabber and delete `/Applications/Dabber.app`.
2. Virtual microphone driver: `scripts/uninstall-driver.sh` (asks for your password; sound stops for a few seconds).
3. Certificate: `security delete-identity -c "Dabber Dev" -t`, or delete "Dabber Dev" in Keychain Access (login
   keychain, My Certificates).
4. Temporary recording folder and settings: delete `~/Library/Application Support/Dabber` (check that it holds no
   unfinished recordings you want), then `defaults delete local.dabber.Dabber`.
5. Optionally remove the permissions: `tccutil reset All local.dabber.Dabber`.

Your recordings in the output folder are not touched.

## Troubleshooting

- **The Mac audio track is silent.** Check System Settings > Privacy & Security > Screen & System Audio Recording and
  allow Dabber there. Without this permission Dabber cannot capture the Mac audio.
- **Warning "Screen: no permission".** Record slides is on, but Dabber is not allowed to take screenshots. Open System Settings
  > Privacy & Security > Screen & System Audio Recording, allow Dabber in the upper list (not "System Audio Recording
  Only"), then quit and start Dabber again. The sound is recorded either way.
- **Warning "… not connected — recording …" or "…: no signal for 10 s".** The first means an enabled microphone
  was absent when you started and another one is being recorded. The second means a microphone has been silent for
  10 seconds while the Mac was playing sound: check that the right microphone is enabled, not muted, and that Dabber
  is allowed in Privacy & Security > Microphone.
- **Warning "… waiting for device — recording … (backup)" or "Backup mic … not connected".** A recorded microphone
  was lost. The first means the backup microphone records in its place. The second means the backup microphone is
  absent too: whatever only the lost microphone picked up is not recorded until one of them comes back, while the
  other recorded microphones keep recording. Choose a microphone that is always there (usually the built-in one)
  under **Backup mic:**.
- **Music or call audio sounds worse in AirPods while recording.** When any app uses the AirPods microphone, AirPods
  switch to a Bluetooth call mode with lower playback quality. This is how Bluetooth headsets work, not a Dabber
  setting. Use another microphone (for example the Mac's built-in one) if playback quality matters.
- **"Dabber Mic" is not in the list of microphones.** The driver is not installed: run `scripts/install-driver.sh`.
  The Dabber menu says "Driver not installed" in this case.
- **Dabber asks for permissions again after an update.** The app was signed with a different certificate, usually
  because "Dabber Dev" was deleted and created again. Allow the permissions once more; they then stay for future
  builds with this certificate.
- **Warning "Could not read: …".** A piece of a track was damaged, usually by a power loss or a crash. Dabber
  finished the recording without that piece (silence in its place) and left the damaged `.caf` file in the recording
  folder.
- **"Finishing…" takes a long time.** After Stop Dabber encodes every track and the mix in the background, at low
  priority so that a new recording is not disturbed. This takes longer for long recordings and more sources, longer
  again if the output folder is on another disk, and longer while other apps keep the processor busy. The transcript
  adds about 15 seconds per hour of audio for each track once the speech model is loaded, and Clean up microphones
  reads the recording once more and processes every microphone track. You can record meanwhile; if
  you quit, Dabber waits for it. If Dabber was closed unexpectedly, unfinished recordings are finished at the next
  launch.

## For developers

- `Sources/DabberCore`: engine, finalizer, models (tested). `Sources/Dabber`: the menu bar app and a headless mode used
  for hardware checks. `Sources/DabberSpeech`: speech-to-text with the Parakeet model through FluidAudio, a separate
  target so that `DabberCore` does not depend on FluidAudio. `Driver/`: the virtual microphone, a BlackHole fork (see
  `Driver/NOTICE`). `scripts/`: build, install and test scripts.
- Run tests with `scripts/test.sh`. With only the Command Line Tools installed, plain `swift test` cannot find the
  Swift Testing macro plugin; the script passes its path.
- `scripts/build-app.sh` builds `build/Dabber.app` without installing it.
- `scripts/make-echo-tests.py` builds test recordings for microphone cleaning in `build/echo-tests`: a call without
  headphones in three simulated rooms, with the Mac audio track, the microphone track and what a perfect cleaner would
  leave of it. Needs Python with `numpy scipy soundfile pyarrow`; downloads 9 MB of LibriSpeech speech on first run.
- `iPad/`: Dabber for iPad (experimental), an Xcode project generated with XcodeGen; see `iPad/README.md`. It records
  through a screen broadcast and finishes recordings with the same `DabberCore`; on iOS the package builds only the
  parts that do not touch Core Audio devices (`#if os(macOS)` around the rest).
- `docs/` holds the design specs, implementation plans and the results of hardware experiments ("spikes") made
  while building Dabber.

## License and credits

Copyright (C) 2026 the Dabber authors. Dabber is free software under the GNU General Public License v3.0; see
[LICENSE](LICENSE).

The virtual microphone driver is built from [BlackHole](https://github.com/ExistentialAudio/BlackHole) by Existential
Audio Inc., licensed under GPL-3.0. Its source, license and the list of local changes are in `Driver/BlackHole` and
`Driver/NOTICE`. Dabber is not an official BlackHole build and is not affiliated with Existential Audio. The name
"Dabber" is not affiliated with any other product of a similar name.

Speech recognition uses [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0) and the NVIDIA
[Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) model (CC-BY-4.0), converted to CoreML by
FluidInference. Microphone cleaning uses the [LocalVQE](https://github.com/localai-org/LocalVQE) model (Apache-2.0) by
the LocalAI team, converted to CoreML by FluidInference.
