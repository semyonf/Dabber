# Spike D: one aggregate with the hidden Feed, a mic and a tap

Date: 2026-09-23. macOS 26.6.2, MacBook Air `Mac17,3`, driver from Plan 3a installed.

`FeedAggregate`: private aggregate, main sub-device Dabber Feed (`Dabber_2_UID`, hidden), optional mic sub-device
and a global tap (excluding only Dabber), both drift-compensated. `--feed-probe <micUID|none> <seconds>` runs one
`DuplexIOProcRunner` that writes silence to the output and measures each input buffer's level.

## No mic (`--feed-probe none 2`, build/probeD-none.log)

```
aggregate rate=48000.0 buffer=512
aggregate inputs: 48000.0Hz/2ch/flags9
aggregate outputs: 48000.0Hz/2ch/flags9
first cycle: in 2ch/4096B | out 2ch/4096B
cycles=188 input dB: -160.0
EXIT 0
```

The tap input is -160 dB because nothing was playing.

## Built-in mic (`--feed-probe BuiltInMicrophoneDevice 3`, build/probeD-mic.log)

```
aggregate rate=48000.0 buffer=512
aggregate inputs: 48000.0Hz/1ch/flags9 48000.0Hz/2ch/flags9
aggregate outputs: 48000.0Hz/2ch/flags9
first cycle: in 1ch/2048B 2ch/4096B | out 2ch/4096B
cycles=281 input dB: -55.4 -160.0
mic rate before=48000.0 after=48000.0
EXIT 0
```

Mic first, then the tap. Mic at -55.4 dB (room noise); the aggregate did not change the mic's rate.

## AirPods in call profile (HUMAN)

AirPods run: pending (HUMAN). Not recorded yet: the AirPods input UID, the aggregate's input format for the mic
stream, its level while counting, and `mic rate before=... after=...` (whether the aggregate changes the 24 kHz
call-profile rate).
