# Spike: can an iPad record a call?

Date: 2026-11-04. Code: `iPad/` (Dabber for iPad: an app with a ReplayKit broadcast upload extension). The first
version was built before this test could be run; the results decide whether it stays.

On a Mac, Dabber records what the Mac plays through a Core Audio tap. iPadOS gives an app no such tap; the only way to
hear other apps is a system broadcast (Control Center > Screen Recording, long press, pick an app). The broadcast
extension then receives three streams: app audio (`audioApp`), the microphone (`audioMic`, only with the microphone
button on) and the screen. Whether call apps let their sound into that stream, and whether the microphone keeps working
while a call app uses it, decides if an iPad Dabber makes sense. That is what this spike finds out.

## What is tested

The iPad app itself (`iPad/`, see its README for building). It writes each broadcast like a Mac recording
(`computer audio.segNNN.caf` for the sound of other apps, `mic - iPad microphone.segNNN.caf`, `frames/`,
`session.json`) and finishes it in the app with the Mac's Finalizer. After finishing, the app warns when one of the
two streams never arrived ("no sound of other apps arrived", "no microphone"). `session.json` in the finished folder
lists every segment (a new one starts at each gap of more than 20 ms or format change) with its `sourceRate` and
`sourceChannels`, which is the format ReplayKit delivered.

## Each test

1. In Dabber tap the round button, turn **Microphone** on at the bottom of the sheet, Start Broadcast.
2. Switch to the call app and make a call of about a minute **through the iPad speaker**, then about a minute with
   headphones if possible. Talk during both; let the other side talk too.
3. Stop the broadcast (red indicator or Control Center) and open Dabber; it finishes the recording.
4. Note any warning Dabber shows, then listen to `computer audio.m4a` (the other side) and `mic - iPad
   microphone.m4a` (you) in the recording. Share `session.json` if something looks odd.

## Results

Fill in one row per test. "Other side in computer audio" / "My voice in mic": yes / no / partly (and when it stopped).

| App (version) | Route | Other side in computer audio | My voice in mic | Formats (app / mic) | Gaps | Notes |
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

- Other side and my voice recorded in the main call apps: keep the iPad app and polish it.
- Other side missing in most apps: an iPad Dabber can only record the microphone and slides; drop it or keep it
  for that alone.
