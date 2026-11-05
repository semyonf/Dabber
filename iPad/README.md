# Dabber for iPad (experimental)

Records a call on an iPad: the sound of the call app, your microphone and the screen, through a screen broadcast
(ReplayKit). An iPad app cannot hear other apps any other way. After you stop the broadcast, the app finishes the
recording with the same code as the Mac: mix, microphone cleaning, transcript, slides video. Not tested on a device
yet: whether call apps let their sound into a broadcast is what
[the test plan](../docs/spikes/2026-11-04-spike-ipad-broadcast.md) finds out.

## Build and install

Needs a Mac with Xcode 16 or later, an Apple developer account and an iPad with iPadOS 18 or later.

1. `brew install xcodegen`
2. `iPad/make-project.sh TEAM_ID` (Team ID: developer.apple.com > Account > Membership details, 10 characters).
   An optional second argument sets the bundle ID (default `pro.vlads.dabber.ipad`; the extension is
   `<bundle ID>.broadcast`, the App Group `group.<bundle ID>`). The script writes `iPad/Local.xcconfig`, generates
   `iPad/DabberPad.xcodeproj` and opens it. Run it again after pulling changes that touch `iPad/project.yml`.
3. On the iPad turn on Settings > Privacy & Security > Developer Mode, connect it, choose it as the run destination
   and run the `DabberPad` scheme. Automatic signing registers both bundle IDs and the App Group. If Xcode complains
   about the App Group, add it under Signing & Capabilities > App Groups for both targets.

The project uses the Swift package at the repository root (`DabberCore`, `DabberSpeech`); on iOS only the parts
that do not touch Core Audio devices are built.

## Use

1. Tap the round button in Dabber, turn **Microphone** on at the bottom of the sheet, tap Start Broadcast. (Also from
   Control Center: long press Screen Recording, choose Dabber.)
2. Switch to the call. The red indicator at the top shows the broadcast is on.
3. Stop it from the red indicator or Control Center. A notification asks you to open Dabber: the recording is finished
   in the app, which must stay open meanwhile (a minute or a few per hour of recording, more on the first run while
   the speech and cleaning models download).
4. The files are in Dabber > Recordings and in the Files app under On My iPad > Dabber > Recordings, in the same
   layout as on the Mac: `computer audio.m4a` is the sound of other apps (the call), `mic - iPad microphone.m4a`
   your microphone, plus the mix, transcript and slides video.

Settings in the app: Record slides (a screenshot every 2 s while the screen changes), Transcribe, Clean up microphone,
Name recordings from the calendar, and **Save to**: Choose… opens the Files sheet to pick any folder (On My iPad,
iCloud Drive, an external drive, another provider in Files); Reset goes back to On My iPad › Dabber › Recordings.
Recordings are finished on the iPad and then copied there (checked against the original before it is removed). If
the folder cannot be reached at that moment (drive removed, offline), the recording is saved On My iPad › Dabber
instead and the app says so. The list in the app shows the recordings in the chosen folder.

## What does not exist on iPad

- The virtual microphone "Dabber Mic": iPadOS has no audio drivers.
- Marks, the ⌥⌥ hotkey and the menu bar: during a call the call app is in front.
- Choosing microphones, the backup microphone, choosing a window or an area for slides: the broadcast records the
  microphone the iPad uses and the whole screen.

## Limits to know

- Apps decide whether their sound may be broadcast. FaceTime and phone calls are believed to keep it out; for Zoom,
  Meet, Telegram and others it has to be tried. When no sound of other apps arrived, Dabber says so after finishing.
- The broadcast extension may use about 50 MB of memory; iPadOS stops it beyond that. What was written until then is
  finished as usual.
