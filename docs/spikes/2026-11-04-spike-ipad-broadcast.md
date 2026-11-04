# Spike: can an iPad record a call?

Date: 2026-11-04. Code: `iPad/BroadcastSpike` (an iPad app with a ReplayKit broadcast upload extension).

On a Mac, Dabber records what the Mac plays through a Core Audio tap. iPadOS gives an app no such tap; the only way to
hear other apps is a system broadcast (Control Center > Screen Recording, long press, pick an app). The broadcast
extension then receives three streams: app audio (`audioApp`), the microphone (`audioMic`, only with the microphone
button on) and the screen. Whether call apps let their sound into that stream, and whether the microphone keeps working
while a call app uses it, decides if an iPad Dabber makes sense. That is what this spike finds out.

## What the spike records

Per broadcast, a folder in the App Group container with:
- `app-1.caf`, `mic-1.caf`: each stream exactly as ReplayKit delivers it; a new file (`-2`, `-3`) whenever its format
  changes, for example when a call starts;
- `frames/`: a half-size JPEG of the screen every 2 s;
- `summary.json`: per track the formats, buffers, length, timestamp gaps over 50 ms, and the RMS level of every second
  of the broadcast (`-120` = nothing arrived in that second); screen frames received and saved; events;
- `log.txt`: the events as they happened.

The app lists the broadcasts and, for each, shows the summary with a one-character-per-second loudness line
(`·` = below -60 dBFS), plays the files, and exports audio + summary + log through the share sheet.

## Build and install

1. On the Mac: Xcode 16 or later, `brew install xcodegen`.
2. `iPad/BroadcastSpike/make-project.sh TEAM_ID` (Team ID: developer.apple.com > Account > Membership details).
   An optional second argument changes the bundle ID prefix (default `pro.vlads.dabber`). The script writes
   `Local.xcconfig`, generates `DabberSpike.xcodeproj` and opens it.
3. Connect the iPad (Developer Mode on: Settings > Privacy & Security > Developer Mode), pick it as the run
   destination, run the `DabberSpike` scheme. Automatic signing registers both bundle IDs and the App Group
   `group.<prefix>.spike`. If Xcode complains about the App Group, add it under Signing & Capabilities > App Groups
   for both targets.

## Each test

1. In Dabber Spike tap the round button, turn **Microphone** on at the bottom of the sheet, Start Broadcast.
2. Switch to the call app and make a call of about a minute **through the iPad speaker**, then about a minute with
   headphones if possible. Talk during both; let the other side talk too.
3. Stop the broadcast (red status bar or Control Center), open Dabber Spike, open the newest recording.
4. Note for both tracks: formats, silent seconds, and listen: is the other side in `app`, is your voice in `mic`.
   Export the folder if something looks odd.

## Results

Fill in one row per test. "Other side in app" / "My voice in mic": yes / no / partly (and when it stopped).

| App (version) | Route | Other side in app | My voice in mic | Formats (app / mic) | Gaps | Notes |
|---|---|---|---|---|---|---|
| YouTube or Music (control) | speaker | | | | | |
| Zoom | speaker | | | | | |
| Zoom | headphones | | | | | |
| Google Meet (app) | speaker | | | | | |
| Google Meet (Safari) | speaker | | | | | |
| Telegram | speaker | | | | | |
| FaceTime | speaker | | | | | |
| Phone call over iPhone (Continuity) | speaker | | | | | |

Also note: did the broadcast stop by itself (extension memory limit), and does the call app show any warning.

## Decision

- Other side and my voice recorded in the main call apps: an iPad Dabber is worth building (estimate in the chat:
  1–2 weeks for a first version).
- Other side missing in most apps: an iPad Dabber could only record the microphone and slides; not worth it.
