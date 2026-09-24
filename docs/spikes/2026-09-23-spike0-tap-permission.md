# Spike 0: global process tap and TCC permission

Date: 2026-09-23. macOS 26.6.2, Swift 6.4 CLT. Build signed with the self-signed "Dabber Dev" identity.

## Results

- Signing: `codesign -d -r-` gives `designated => identifier "local.dabber.Dabber" and certificate leaf = H"<certificate hash>"`,
  no `cdhash`.
- Tap format: `48000.0 Hz, 2 ch, flags 9` (float, packed, interleaved). AirPods were the default output at 48 kHz.
- Permission: after the first `--spike-tap` run the grant exists (whether a dialog was shown and clicked was not
  confirmed by the user). TCC row:
  `kTCCServiceAudioCapture|local.dabber.Dabber|2` in `~/Library/Application Support/com.apple.TCC/TCC.db`.
- 8 s run with two `Submarine.aiff` plays: `duration=8.000000`, peak -3.2 dB.
- Two rebuilds (`touch main.swift`, `build-app.sh`), 3 s run each with `Ping.aiff`: both `EXIT 0`, peaks -5.5 dB and
  -6.6 dB: both runs completed unattended and captured signal, so the grant survives rebuilds with the
  certificate-leaf requirement.
- 60 s run: `duration=59.989333` (expected 60 +/- 0.1). Music was playing the whole time: RMS about -16 dB in every
  5 s window after the first, no silence stretches found (`silencedetect n=-60dB d=3` reported none). The first
  sampled window reads -inf; not investigated.
- The aggregate device with only a tap (no main sub-device, no tap auto-start) starts and delivers buffers.
- API spelling: the plan's Swift compiled as written except a missing `import CoreAudio` in `Headless.swift`.

## Side observation

Per the user: Dipper, while running, kept the AirPods mic open and the AirPods sat in the call profile until the user quit
it. Measured before quitting (system_profiler): AirPods input and output both at 24000 Hz. After quitting: AirPods output 48 kHz, input nominal rate still reported as 24000 Hz.
