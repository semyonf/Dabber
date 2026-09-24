# Dabber 3a: Virtual Mic Driver and Spikes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A signed `DabberMic.driver`, built with `clang` from a vendored, pinned BlackHole, that publishes a visible input-only **Dabber Mic** and a hidden output-only **Dabber Feed**. Install and uninstall scripts. Three spikes answered from real runs: (A) does `coreaudiod` load a driver signed with the self-signed "Dabber Dev" identity, (B) is the Feed -> Mic loopback clean over 60 s, (C) does a process tap exclude Safari by bundle ID, including helpers that start after the tap.

**Architecture:** BlackHole already supports this device pair through build-time defines, so the driver needs no new C code. Its "mirror device" (`kObjectID_Device2`) shares the ring buffer and clock with the main device, and each device's direction and hidden flag are separate defines. `Driver/BlackHole/` holds the upstream tree: one pristine commit, then one trim commit and one 3-line rename commit. `scripts/build-driver.sh` compiles `BlackHole.c` into `build/DabberMic.driver` with the Dabber defines and signs it. Spike tooling goes into the existing Swift package:
- a pure `ToneGenerator`;
- a `TonePlayer` that renders into an output IOProc buffer;
- `OutputIOProcRunner`, the output twin of `IOProcRunner`;
- bundle-ID exclusion in `GlobalTap`;
- headless `--play-tone`, `--list-audio-processes` and `--record ... --exclude-bundle <id>`.

**Tech Stack:** C (BlackHole 0.7.1, AudioServerPlugIn), Apple clang 21 (Command Line Tools, SDK MacOSX27.0), codesign, Swift 6.4 with SwiftPM and Swift Testing, CoreAudio (HAL IOProc, process taps with `bundleIDs`), ffmpeg/ffprobe, plutil.

Spec: `docs/superpowers/specs/2026-09-23-dabber-part3-virtual-mic-design.md`. Format model: `docs/superpowers/plans/2026-09-23-dabber-1a-foundation-and-spikes.md`.
Plan 3b (menu "Virtual mic" section, the mixing aggregate, settings, status model) is written after Task 10, from the three spike docs.

## Ground rules for implementers

- Repo root: the repository root. Branch `part3`. No remote. Never push.
- Commit messages: one line, `type: description`, no body, no trailers. `git add` by explicit path only; read `git diff --cached --stat` before every commit.
- Shell is zsh. Tests: `scripts/test.sh` only (bare `swift test` cannot find the Swift Testing macro plugin). Success means exit code 0 (`scripts/test.sh; echo "exit=$?"`), never grep for text. No Xcode, no `xcodebuild`. Never use `@State` or `@Bindable` (the SwiftUI macro plugin is not in the CLT toolchain; see Plan 1b).
- **The implementer never runs `sudo`.** `scripts/install-driver.sh` and `scripts/uninstall-driver.sh` are run by the user in their own Terminal (HUMAN steps). The implementer may run `scripts/build-driver.sh` (no sudo).
- Never touch `/Library/Audio/Plug-Ins/HAL/Dipper.driver` or any file of Dipper. Do not edit `/Library/Preferences/Audio/*`.
- In zsh, `log` is a shell builtin (`log show` fails with `too many arguments`). Always call `/usr/bin/log`.
- Hardware checks: `scripts/build-app.sh`, then `scripts/run-headless.sh <log> <args>`. The log's last line must end in ` EXIT 0`.
- Code: English, no comments unless the code cannot say it. KISS. Swift 6 language mode. Classes crossing into IOProc blocks are `final class ...: @unchecked Sendable`. The IO thread only writes their counters, and those are read after `stop()` (the pattern used by the removed Spike 0 `CAFRecorder`).
- Tasks marked **HUMAN** need the user (password, listening, Safari). Stop there, tell the user exactly what to do in at most five short lines, and wait.
- Facts below were checked on this machine on 2026-09-23 (macOS 26.6.2, `arm64`) in scratch directories outside the repo. Treat them as verified:
  - BlackHole latest tag `v0.7.1` = commit `e2b22aaaba4e507a097131704bf96dabc004d9cf` (2026-07-03).
  - `BlackHole.c` publishes two devices, `kObjectID_Device` and `kObjectID_Device2`, from one box (plug-in device list lines 1533-1557, box device list line 2012).
  - Each device has its own `#ifndef` defines: name (`kDevice_Name` line 176-178, `kDevice2_Name` line 180-182), direction (`kDevice_HasInput` line 213, `kDevice_HasOutput` line 217, `kDevice2_HasInput` line 222, `kDevice2_HasOutput` line 226), hidden flag (`kDevice_IsHidden` line 203, `kDevice2_IsHidden` line 207, default `true`).
  - Both devices share one ring buffer and one clock (`BlackHole_StartIO` lines 4333-4343, `GetZeroTimeStamp` lines 4402-4450). Reads come from the output write position by sample time (`DoIOOperation` lines 4551-4601).
  - The upstream README "Mirror Device" section describes exactly this use: an input-only visible device plus a hidden output-only device opened by UID.
  - With `kHas_Driver_Name_Format=false` the UIDs are `kDriver_Name "_UID"` and `kDriver_Name "_2_UID"` (lines 187-188). Dabber therefore gets **`Dabber_UID`** (Mic) and **`Dabber_2_UID`** (Feed).
  - Dipper, which is BlackHole-based, registers `Dipper_UID` and `Dipper_2_UID` in `/Library/Preferences/Audio/com.apple.audio.SystemSettings.plist`, so the Dabber UIDs do not collide with it.
  - The box name, model and manufacturer are hardcoded to BlackHole and Existential Audio (lines 781, 1913, 1920). Task 2 fixes this.
  - Box `FirmwareVersion` does `CFRetain` on the bundle's `CFBundleShortVersionString` without a NULL check (lines 1946-1947). The driver's `Info.plist` must have that key, and `CFBundleIdentifier` must equal `kPlugIn_BundleID`.
  - Device and stream latency and safety offset are `kLatency_Frame_Size` = 0 (lines 235, 2739, 3163).
  - The clang build in Task 3 was run in a scratch replay of Tasks 1-3: exit 0; `Mach-O 64-bit bundle arm64`; exported `_BlackHole_Create`; `minos 26.0`; `designated => identifier "local.dabber.DabberMic" and certificate leaf = H"<certificate hash>"`.
  - Without `-Wno-format-extra-args` the build prints 7 upstream warnings, all harmless. They come from a runtime `if(kHas_Driver_Name_Format)` branch (line 437) and from line 1511.
  - `clang -E` confirmed the object lists: Mic = input stream, input volume/mute, clock source; Feed = output stream, output volume/mute. `kDevice_SampleRates[] = { 48000 }`.
  - Headers: hidden devices are not in `kAudioHardwarePropertyDevices` and cannot be default. They are found only by UID (`AudioHardwareBase.h` lines 716-720).
  - coreaudiod logs `HALS_RemotePlugInRegistrar ... Attempting to load:  <Name>.driver` and `Creating remote driver service: ... <Name>.driver ..., pid: N`.
  - Each third-party driver runs in its own `com.apple.audio.Core-Audio-Driver-Service.helper` process, shown by `ps` as `Core Audio Driver (<Name>.driver)`.
  - `CATapDescription.bundleIDs` (`[String]`) and `isProcessRestoreEnabled` compile in Swift (`CATapDescription.h` lines 131-136 and 162-167, macOS 26).
  - A fresh `CATapDescription(stereoGlobalTapButExcludeProcesses:)` already has `isProcessRestoreEnabled == true`. A scratch test asserting the default was false failed.
  - Safari's audio process objects report bundle ID `com.apple.WebKit.GPU` (`kAudioProcessPropertyBundleID`), separate from `com.apple.Safari`.
  - The Swift code of Tasks 6, 7 and 9 was compiled in a scratch clone of this repo. `scripts/test.sh` ran 97 tests, exit 0 (85 before these tasks). `--list-audio-processes` and `--play-tone no-such-uid 1 0` ran through a scratch-signed bundle.
  - ffmpeg checks were calibrated on a 440 Hz, -12 dBFS tone encoded to 96 kbps AAC `.m4a` by the Apple encoder, like `AACWriter`:
    - `silencedetect` puts the onset at 3.000021 s for a tone starting at 3.000 s.
    - A 512-frame dropout shows up as `silence_start: 10 silence_end: 10.010562`.
    - Per-second peak after two 2 kHz high-pass filters: -61..-64 dB when clean, -18 dB for a phase jump or dropout. The last second of a file can read about -28 dB (end artifact), so it is ignored.
  - `plutil -extract <path> raw` reads `session.json` (arrays give their count).
  - SwiftPM ignores a top-level `Driver/` directory (`swift build` exit 0 with it present).

## Why `Driver/`

- The C code stays out of `Sources/`, so SwiftPM never tries to build it, and GPL-3.0 code is visibly separate from Dabber's own Swift code.
- `Driver/BlackHole/` mirrors the upstream repository layout. `diff -r` against an upstream checkout at the pinned commit, or `git diff <vendor commit> -- Driver/BlackHole`, shows every local change.
- Dabber's own driver files (`Driver/Info.plist`, `Driver/NOTICE`) sit next to it, not inside it.

## License

`Driver/BlackHole/LICENSE` (GPL-3.0 plus an Existential Audio preamble) is kept verbatim, and so is the copyright header of `BlackHole.c`. The preamble (LICENSE lines 7-9) reserves the BlackHole name, logo, artwork and branding for modified builds. That is why Task 2 removes the icon and images and renames the box strings. GPL-3.0 section 5a (LICENSE line 225) asks modified versions to carry prominent notices of the changes with a date: that is `Driver/NOTICE`. Personal use only. Distributing Dabber later requires publishing the driver source under GPL-3.0 (spec).

## File structure

```
Driver/BlackHole/                          upstream BlackHole v0.7.1, trimmed (BlackHole.c, LICENSE, README.md, CHANGELOG.md, VERSION, .gitignore)
Driver/NOTICE                              origin, pinned commit, dated list of local changes
Driver/Info.plist                          DabberMic.driver bundle plist, own factory UUID
scripts/build-driver.sh                    clang -> build/DabberMic.driver, signed "Dabber Dev"
scripts/install-driver.sh                  build, sudo copy to /Library/Audio/Plug-Ins/HAL, restart coreaudiod
scripts/uninstall-driver.sh                sudo remove DabberMic.driver only, restart coreaudiod
Sources/DabberCore/Model/ToneGenerator.swift          phase-continuous sine
Sources/DabberCore/Engine/TonePlayer.swift            renders silence then tone into an output buffer list
Sources/DabberCore/CoreAudio/OutputIOProcRunner.swift output IOProc start/stop
Sources/DabberCore/CoreAudio/GlobalTap.swift          (modify) exclusion by bundle ID
Sources/DabberCore/CoreAudio/Devices.swift            (modify) audioProcesses()
Sources/DabberCore/Engine/CaptureSource.swift         (modify) SourceSpec.excludedBundleIDs
Sources/DabberCore/Engine/ComputerAudioSource.swift   (modify) pass exclusions to GlobalTap
Sources/Dabber/Headless.swift                         (modify) --play-tone, --list-audio-processes, --record --exclude-bundle
Tests/DabberCoreTests/ToneGeneratorTests.swift
Tests/DabberCoreTests/TonePlayerTests.swift
Tests/DabberCoreTests/GlobalTapTests.swift
docs/spikes/2026-09-23-spikeA-driver-signature.md
docs/spikes/2026-09-23-spikeB-loopback.md
docs/spikes/2026-09-23-spikeC-exclusion.md
```

---

### Task 1: Vendor pristine BlackHole v0.7.1

**Files:**
- Create: `Driver/BlackHole/**` (upstream tree at `e2b22aaaba4e507a097131704bf96dabc004d9cf`, byte for byte)

- [ ] **Step 1: Export the pinned commit into `Driver/BlackHole`**

Run:
```zsh
cd dabber
T=$(mktemp -d)
git clone -q https://github.com/ExistentialAudio/BlackHole.git "$T/BlackHole"
git -C "$T/BlackHole" rev-parse 'v0.7.1^{commit}'
mkdir -p Driver
git -C "$T/BlackHole" archive --prefix=Driver/BlackHole/ e2b22aaaba4e507a097131704bf96dabc004d9cf | tar -x -C .
rm -rf "$T"
find Driver/BlackHole -type f | wc -l
```
Expected: `e2b22aaaba4e507a097131704bf96dabc004d9cf`, then `26`. If the tag resolves to a different commit, stop and report: upstream moved the tag.

- [ ] **Step 2: Commit the pristine tree**

```zsh
git add Driver/BlackHole
git diff --cached --stat | tail -1
git commit -m "chore: vendor BlackHole v0.7.1 driver source at e2b22aa"
```
Expected stat: `26 files changed, 7041 insertions(+)`.

---

### Task 2: Trim the vendored tree and rename the box strings

**Files:**
- Delete: `Driver/BlackHole/{.github,BlackHole.xcodeproj,BlackHoleTests,Images,Installer,Uninstaller}`, `Driver/BlackHole/BlackHole/BlackHole.icns`, `Driver/BlackHole/BlackHole/BlackHole.plist`
- Modify: `Driver/BlackHole/BlackHole/BlackHole.c` (3 lines)
- Create: `Driver/NOTICE`

The Xcode project, installer, uninstaller and tests are not built here. The icon and images are Existential Audio artwork, which the LICENSE preamble reserves. `BlackHole.plist` is replaced by `Driver/Info.plist` in Task 3.

- [ ] **Step 1: Remove what Dabber does not build or ship, and commit**

```zsh
git rm -rq Driver/BlackHole/.github Driver/BlackHole/BlackHole.xcodeproj Driver/BlackHole/BlackHoleTests \
  Driver/BlackHole/Images Driver/BlackHole/Installer Driver/BlackHole/Uninstaller \
  Driver/BlackHole/BlackHole/BlackHole.icns Driver/BlackHole/BlackHole/BlackHole.plist
git ls-files Driver
git diff --cached --stat | tail -1
git commit -m "chore: trim vendored BlackHole to the driver source and license"
```
Expected `git ls-files Driver`: exactly `Driver/BlackHole/.gitignore`, `Driver/BlackHole/BlackHole/BlackHole.c`, `Driver/BlackHole/CHANGELOG.md`, `Driver/BlackHole/LICENSE`, `Driver/BlackHole/README.md`, `Driver/BlackHole/VERSION`.

- [ ] **Step 2: Name the box after the build-time defines**

In `Driver/BlackHole/BlackHole/BlackHole.c` change exactly three lines. Upstream line numbers:

line 781:
```c
		gBox_Name = CFSTR("BlackHole Box");
```
to
```c
		gBox_Name = CFSTR(kDriver_Name " Box");
```

line 1913:
```c
			*((CFStringRef*)outData) = CFSTR("BlackHole");
```
to
```c
			*((CFStringRef*)outData) = CFSTR(kDriver_Name);
```

line 1920:
```c
			*((CFStringRef*)outData) = CFSTR("Existential Audio Inc.");
```
to
```c
			*((CFStringRef*)outData) = CFSTR(kManufacturer_Name);
```

Keep the tabs as they are. Leave the copyright header and every other line unchanged.

- [ ] **Step 3: Write `Driver/NOTICE`**

```
Driver/BlackHole is BlackHole by Existential Audio Inc., licensed under GPL-3.0 (see Driver/BlackHole/LICENSE).
It is not an official BlackHole build and does not use the BlackHole name, logo or artwork for the devices it creates.

Upstream: https://github.com/ExistentialAudio/BlackHole
Tag v0.7.1, commit e2b22aaaba4e507a097131704bf96dabc004d9cf.

Local changes (git log -- Driver/BlackHole shows each one):
- 2026-09-23: removed the Xcode project, installer, uninstaller, tests, images, icon and bundle plist.
- 2026-09-23: the box name, model and manufacturer come from kDriver_Name and kManufacturer_Name
  instead of fixed BlackHole and Existential Audio strings.

Dabber builds BlackHole.c with scripts/build-driver.sh into DabberMic.driver. That build publishes an
input-only device "Dabber Mic" and a hidden output-only device "Dabber Feed" through upstream's documented
build-time defines.
```

- [ ] **Step 4: Check the upstream diff is exactly three lines and commit**

```zsh
git diff --numstat -- Driver/BlackHole
git add Driver/BlackHole/BlackHole/BlackHole.c Driver/NOTICE
git diff --cached --stat
git commit -m "feat: name the vendored driver box after the build-time driver name"
```
Expected numstat: `3	3	Driver/BlackHole/BlackHole/BlackHole.c`.

---

### Task 3: Driver bundle built with clang and signed

**Files:**
- Create: `Driver/Info.plist`, `scripts/build-driver.sh`

- [ ] **Step 1: Write `Driver/Info.plist`**

The factory UUID `EC05E976-5D22-4576-AB66-B9E114263212` was generated for Dabber with `uuidgen`. Upstream's installer also replaces the default factory UUID per build, and Dipper uses its own. The type UUID `443ABAB8-E7B3-491A-B985-BEB9187030DB` is Apple's AudioServerPlugIn driver type (from upstream's plist). `BlackHole_Create` is the factory symbol in `BlackHole.c`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>English</string>
  <key>CFBundleExecutable</key><string>DabberMic</string>
  <key>CFBundleIdentifier</key><string>local.dabber.DabberMic</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>DabberMic</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>0.7.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFPlugInFactories</key>
  <dict>
    <key>EC05E976-5D22-4576-AB66-B9E114263212</key><string>BlackHole_Create</string>
  </dict>
  <key>CFPlugInTypes</key>
  <dict>
    <key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key>
    <array><string>EC05E976-5D22-4576-AB66-B9E114263212</string></array>
  </dict>
</dict>
</plist>
```

`CFBundleShortVersionString` must stay: the box firmware-version getter retains it without a NULL check.

- [ ] **Step 2: Write `scripts/build-driver.sh`**

The defines are the whole device design; everything else is upstream default.
- `-Wno-format-extra-args` silences 7 harmless upstream warnings (see ground rules).
- `kPlugIn_Icon` stays at its default and the icon file is gone, so `kAudioDevicePropertyIcon` returns an error. Apps then show a generic icon (not verified; cosmetic).

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/DabberMic.driver
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
cp Driver/Info.plist "$OUT/Contents/Info.plist"
defines=(
  -DkDriver_Name='"Dabber"'
  -DkHas_Driver_Name_Format=false
  -DkPlugIn_BundleID='"local.dabber.DabberMic"'
  -DkManufacturer_Name='"Dabber"'
  -DkDevice_Name='"Dabber Mic"'
  -DkDevice_HasInput=true
  -DkDevice_HasOutput=false
  -DkDevice_IsHidden=false
  -DkDevice2_Name='"Dabber Feed"'
  -DkDevice2_HasInput=false
  -DkDevice2_HasOutput=true
  -DkDevice2_IsHidden=true
  -DkNumber_Of_Channels=2
  -DkSampleRates=48000
)
clang -arch arm64 -mmacosx-version-min=26.0 -Os -Wno-format-extra-args -bundle \
  "${defines[@]}" \
  -framework CoreAudio -framework CoreFoundation -framework Accelerate \
  -o "$OUT/Contents/MacOS/DabberMic" Driver/BlackHole/BlackHole/BlackHole.c
codesign --force --sign "Dabber Dev" "$OUT"
codesign --verify --strict "$OUT"
codesign -d -r- "$OUT" 2>&1 | grep designated
```

- [ ] **Step 3: Build**

Run: `chmod +x scripts/build-driver.sh; scripts/build-driver.sh; echo "exit=$?"`
Expected, and nothing else:
```
build/DabberMic.driver: replacing existing signature
designated => identifier "local.dabber.DabberMic" and certificate leaf = H"<certificate hash>"
exit=0
```
(The linker ad-hoc signs arm64 output, so codesign reports it replaced that signature.)

- [ ] **Step 4: Inspect the bundle**

Run:
```zsh
B=build/DabberMic.driver
find $B -type f | sort
file $B/Contents/MacOS/DabberMic
nm -gU $B/Contents/MacOS/DabberMic
plutil -lint $B/Contents/Info.plist
strings $B/Contents/MacOS/DabberMic | grep -E 'Dabber|Existential'
```
Expected:
- files: `Contents/Info.plist`, `Contents/MacOS/DabberMic`, `Contents/_CodeSignature/CodeResources`
- `Mach-O 64-bit bundle arm64`
- `T _BlackHole_Create`
- `OK`
- strings include `Dabber Box`, `Dabber_UID`, `Dabber_2_UID`, `Dabber Mic`, `Dabber Feed`, `local.dabber.DabberMic`, and no `Existential Audio Inc.`

- [ ] **Step 5: Commit**

```zsh
git add Driver/Info.plist scripts/build-driver.sh
git diff --cached --stat
git commit -m "build: add clang build of the dabber mic driver bundle"
```

---

### Task 4: Install and uninstall scripts

**Files:**
- Create: `scripts/install-driver.sh`, `scripts/uninstall-driver.sh`

Both scripts touch only `/Library/Audio/Plug-Ins/HAL/DabberMic.driver`. Before replacing or removing it they check its bundle ID, so a foreign bundle at that path is never deleted. Upstream's own uninstaller also uses `killall coreaudiod`, and launchd restarts coreaudiod.

- [ ] **Step 1: Write `scripts/install-driver.sh`**

It must run without `sudo`: codesign needs the login keychain. The script calls `sudo` itself.

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEST=/Library/Audio/Plug-Ins/HAL/DabberMic.driver
ID=local.dabber.DabberMic
if [ "$(id -u)" -eq 0 ]; then
  echo "run without sudo: signing needs your login keychain; the script asks for the password itself"
  exit 1
fi
if [ -e "$DEST" ] && [ "$(plutil -extract CFBundleIdentifier raw "$DEST/Contents/Info.plist" 2>/dev/null)" != "$ID" ]; then
  echo "refusing: $DEST exists and is not $ID"
  exit 1
fi
scripts/build-driver.sh
echo "installing $DEST: sudo asks for your password, then all sound stops for a few seconds"
sudo rm -rf "$DEST"
sudo cp -R build/DabberMic.driver "$DEST"
sudo chown -R root:wheel "$DEST"
codesign --verify --strict "$DEST"
sudo killall coreaudiod
for _ in {1..20}; do pgrep -x coreaudiod >/dev/null && break; sleep 0.5; done
sleep 2
echo "installed"
```

- [ ] **Step 2: Write `scripts/uninstall-driver.sh`**

```bash
#!/bin/bash
set -euo pipefail
DEST=/Library/Audio/Plug-Ins/HAL/DabberMic.driver
ID=local.dabber.DabberMic
if [ ! -e "$DEST" ]; then
  echo "not installed: $DEST"
  exit 0
fi
if [ "$(plutil -extract CFBundleIdentifier raw "$DEST/Contents/Info.plist" 2>/dev/null)" != "$ID" ]; then
  echo "refusing: $DEST is not $ID"
  exit 1
fi
echo "removing $DEST: sudo asks for your password, then all sound stops for a few seconds"
sudo rm -rf "$DEST"
sudo killall coreaudiod
for _ in {1..20}; do pgrep -x coreaudiod >/dev/null && break; sleep 0.5; done
echo "removed"
```

- [ ] **Step 3: Syntax check, and run the no-sudo path**

Run:
```zsh
chmod +x scripts/install-driver.sh scripts/uninstall-driver.sh
bash -n scripts/install-driver.sh && bash -n scripts/uninstall-driver.sh && echo syntax-ok
scripts/uninstall-driver.sh; echo "exit=$?"
```
Expected: `syntax-ok`, `not installed: /Library/Audio/Plug-Ins/HAL/DabberMic.driver`, `exit=0`. No password prompt: this path never reaches `sudo`.

- [ ] **Step 4: Commit**

```zsh
git add scripts/install-driver.sh scripts/uninstall-driver.sh
git diff --cached --stat
git commit -m "build: add dabber mic driver install and uninstall scripts"
```

---

### Task 5: Spike A, does coreaudiod load the self-signed driver (HUMAN: password twice)

**Files:**
- Create: `docs/spikes/2026-09-23-spikeA-driver-signature.md`

- [ ] **Step 1: Record the state before install**

Run:
```zsh
mkdir -p build
ls -1 /Library/Audio/Plug-Ins/HAL > build/hal-before.txt
stat -f '%m %z %N' /Library/Audio/Plug-Ins/HAL/Dipper.driver/Contents/MacOS/* > build/dipper-before.txt
cat build/hal-before.txt build/dipper-before.txt
plutil -p /Library/Preferences/Audio/com.apple.audio.SystemSettings.plist | grep -c Dabber
pgrep -lf 'Core Audio Driver'
scripts/build-app.sh
scripts/run-headless.sh "$PWD/build/inputs-before.log" --list-inputs
```
Expected: `Dipper.driver` and `ParrotAudioPlugin.driver` listed, one stat line for Dipper's binary, count `0`, helper processes for `Dipper.driver` and `ParrotAudioPlugin.driver`, no `Dabber` in the inputs, `EXIT 0`.

- [ ] **Step 2: Install (HUMAN)**

Tell the user:
> In Terminal: `cd dabber && scripts/install-driver.sh`
> Type your password when asked. Sound stops for a few seconds, then comes back.
> Tell me when it prints `installed` (or paste the error).

- [ ] **Step 3: Check that Dabber Mic appeared**

Run:
```zsh
scripts/run-headless.sh "$PWD/build/inputs-after.log" --list-inputs
pgrep -lf 'DabberMic.driver'
/usr/bin/log show --last 5m --style compact \
  --predicate 'process == "coreaudiod" OR process == "com.apple.audio.Core-Audio-Driver-Service.helper"' | grep -i dabber
codesign -d -r- /Library/Audio/Plug-Ins/HAL/DabberMic.driver 2>&1 | grep designated
system_profiler SPAudioDataType | grep -A6 -i dabber
```
Expected on success:
- `inputs-after.log` has a line `Dabber_UID	Dabber Mic`
- `pgrep` prints `<pid> Core Audio Driver (DabberMic.driver)`
- the log shows `Attempting to load:  DabberMic.driver` and `Creating remote driver service: ... DabberMic.driver ..., pid: <same pid>`
- the designated requirement matches Task 3
- `system_profiler` lists `Dabber Mic:` with 2 input channels at 48000, and no `Dabber Feed` (a hidden device should not be listed there; if it is, record that).

- [ ] **Step 4: If Dabber Mic is absent: stop**

Failure means no `Dabber_UID` line in `inputs-after.log`. Then run:
```zsh
/usr/bin/log show --last 10m --style compact --predicate 'eventMessage CONTAINS[c] "DabberMic"'
```
Write the spike doc (Step 7) with the outputs of Steps 3 and 4, commit it, and **stop the plan**. Report to the user. These are decisions for the user; do not do them yourself:
1. Ad-hoc signature: in `scripts/build-driver.sh` change `--sign "Dabber Dev"` to `--sign -`, then reinstall. Assumption, not verified: coreaudiod loads ad-hoc signed third-party drivers on arm64. Locally built BlackHole is commonly run that way.
2. Trust the "Dabber Dev" certificate system-wide (System keychain, `sudo security add-trusted-cert -d ...`). This changes system trust settings, so it is more invasive than option 1.

If the log shows `Attempting to load` followed by an error that is not about signatures (plist, factory, symbol), record it verbatim and stop as well.

- [ ] **Step 5: Uninstall round trip (HUMAN), to prove the uninstall restores the previous state**

Tell the user:
> In Terminal: `scripts/uninstall-driver.sh`, type your password; sound drops again briefly.
> Tell me when it prints `removed`.

Then run:
```zsh
ls -1 /Library/Audio/Plug-Ins/HAL | diff build/hal-before.txt - && echo HAL-SAME
stat -f '%m %z %N' /Library/Audio/Plug-Ins/HAL/Dipper.driver/Contents/MacOS/* | diff build/dipper-before.txt - && echo DIPPER-SAME
pgrep -lf 'Core Audio Driver'
scripts/run-headless.sh "$PWD/build/inputs-removed.log" --list-inputs
plutil -p /Library/Preferences/Audio/com.apple.audio.SystemSettings.plist | grep Dabber
```
Expected:
- `HAL-SAME` and `DIPPER-SAME`
- the Dipper and Parrot helpers are running again and there is no DabberMic helper
- no `Dabber` line in the inputs.

The last command is expected to still show `Dabber_UID`-keyed entries. coreaudiod keeps per-device settings for every device it has seen, Dipper's included, and neither upstream's uninstaller nor ours edits that file. Record it; it is not a failure.

- [ ] **Step 6: Reinstall for Spikes B and C (HUMAN)**

Tell the user: `scripts/install-driver.sh` once more, password, brief sound drop. Then rerun Step 3's `--list-inputs` and expect `Dabber_UID	Dabber Mic`.

- [ ] **Step 7: Write `docs/spikes/2026-09-23-spikeA-driver-signature.md`**

Record:
- macOS version (`sw_vers -productVersion`);
- the designated requirement;
- the exact coreaudiod log lines and the helper pid;
- the `--list-inputs` line;
- the `system_profiler` block;
- whether Dabber Feed was listed anywhere;
- the uninstall round-trip results (`HAL-SAME`, `DIPPER-SAME`, residual settings entries);
- any deviation from this plan.

On failure, record the outputs of Steps 3 and 4 and the two options.

- [ ] **Step 8: Commit**

```zsh
git add docs/spikes/2026-09-23-spikeA-driver-signature.md
git commit -m "docs: record spike a driver signature results"
```

---

### Task 6: Tone generator (pure, TDD)

**Files:**
- Create: `Sources/DabberCore/Model/ToneGenerator.swift`, `Tests/DabberCoreTests/ToneGeneratorTests.swift`

A sine whose phase carries across calls. Any click in Spike B then comes from the loopback, not from the buffer boundaries of the generator.

- [ ] **Step 1: Write the failing tests `Tests/DabberCoreTests/ToneGeneratorTests.swift`**

```swift
import Testing
@testable import DabberCore

private func render(_ tone: inout ToneGenerator, frames: Int, channels: Int) -> [Float] {
    var out = [Float](repeating: 9, count: frames * channels)
    out.withUnsafeMutableBufferPointer { tone.fill($0, channels: channels) }
    return out
}

@Test func toneStartsAtZero() {
    var tone = ToneGenerator(frequency: 440, amplitude: 0.25)
    #expect(render(&tone, frames: 1, channels: 1) == [0])
}

@Test func toneIsContinuousAcrossCalls() {
    var whole = ToneGenerator(frequency: 440, amplitude: 0.25)
    var split = ToneGenerator(frequency: 440, amplitude: 0.25)
    let a = render(&whole, frames: 480, channels: 1)
    let b = render(&split, frames: 100, channels: 1) + render(&split, frames: 380, channels: 1)
    #expect(a == b)
}

@Test func everyChannelGetsTheSameSample() {
    var tone = ToneGenerator(frequency: 440, amplitude: 0.25)
    let out = render(&tone, frames: 64, channels: 2)
    #expect(stride(from: 0, to: out.count, by: 2).allSatisfy { out[$0] == out[$0 + 1] })
}

@Test func tonePeakIsTheAmplitude() {
    var tone = ToneGenerator(frequency: 1000, amplitude: 0.25)
    let peak = render(&tone, frames: 48_000, channels: 1).map(abs).max() ?? 0
    #expect(abs(peak - 0.25) < 0.001)
}

@Test func toneHasTheRequestedFrequency() {
    var tone = ToneGenerator(frequency: 440, amplitude: 0.25)
    let out = render(&tone, frames: 48_000, channels: 1)
    let rising = (1..<out.count).filter { out[$0 - 1] < 0 && out[$0] >= 0 }.count
    #expect(abs(rising - 440) <= 1)
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `cannot find 'ToneGenerator' in scope`, non-zero exit.

- [ ] **Step 3: Write `Sources/DabberCore/Model/ToneGenerator.swift`**

```swift
import Foundation

public struct ToneGenerator: Sendable {
    public let frequency: Double
    public let amplitude: Float
    private let step: Double
    private var phase = 0.0

    public init(frequency: Double, amplitude: Float, rate: Double = Double(Timeline.rate)) {
        self.frequency = frequency
        self.amplitude = amplitude
        step = 2 * Double.pi * frequency / rate
    }

    public mutating func fill(_ out: UnsafeMutableBufferPointer<Float>, channels: Int) {
        for frame in 0..<(out.count / channels) {
            let sample = amplitude * Float(sin(phase))
            for c in 0..<channels { out[frame * channels + c] = sample }
            phase += step
            if phase >= 2 * Double.pi { phase -= 2 * Double.pi }
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `Test run with 90 tests ... passed`, `exit=0`.

- [ ] **Step 5: Commit**

```zsh
git add Sources/DabberCore/Model/ToneGenerator.swift Tests/DabberCoreTests/ToneGeneratorTests.swift
git commit -m "feat: add phase-continuous tone generator"
```

---

### Task 7: Output IOProc, tone player and `--play-tone`

**Files:**
- Create: `Sources/DabberCore/CoreAudio/OutputIOProcRunner.swift`, `Sources/DabberCore/Engine/TonePlayer.swift`, `Tests/DabberCoreTests/TonePlayerTests.swift`
- Modify: `Sources/Dabber/Headless.swift`

`IOProcRunner` passes only the input side to its handler. `OutputIOProcRunner` is its output twin; `IOProcRunner` stays unchanged.
- `TonePlayer.render` runs on the IO thread. It writes silence until the first buffer whose output host time is at or after `startNanos`, and from then on the tone from frame 0 of each buffer. So `toneStartNanos` is the exact host time of the first tone frame.
- It counts output sample-time jumps (`discontinuities`) to tell player-side gaps from driver-side ones.
- It expects one interleaved buffer: BlackHole's stream format is interleaved float32 (`BlackHole.c` line 3178, flags 9). Anything else is zeroed and counted.

- [ ] **Step 1: Write the failing tests `Tests/DabberCoreTests/TonePlayerTests.swift`**

```swift
import CoreAudio
import Testing
@testable import DabberCore

private func play(_ player: TonePlayer, frames: Int, sampleTime: Double, hostNanos: UInt64) -> [Float] {
    var samples = [Float](repeating: 9, count: frames * 2)
    samples.withUnsafeMutableBytes { raw in
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
        var ts = AudioTimeStamp()
        ts.mSampleTime = sampleTime
        ts.mHostTime = AudioConvertNanosToHostTime(hostNanos)
        ts.mFlags = [.sampleTimeValid, .hostTimeValid]
        withUnsafeMutablePointer(to: &list) { l in withUnsafePointer(to: &ts) { t in player.render(l, t) } }
    }
    return samples
}

private func makePlayer() -> TonePlayer {
    TonePlayer(tone: ToneGenerator(frequency: 440, amplitude: 0.25), startNanos: 1_000_000_000)
}

@Test func playerIsSilentBeforeStart() {
    let player = makePlayer()
    let out = play(player, frames: 512, sampleTime: 0, hostNanos: 500_000_000)
    #expect(out.allSatisfy { $0 == 0 })
    #expect(player.toneStartNanos == 0)
}

@Test func toneBeginsWithTheFirstBufferAtOrAfterStart() {
    let player = makePlayer()
    _ = play(player, frames: 512, sampleTime: 0, hostNanos: 990_000_000)
    let out = play(player, frames: 512, sampleTime: 512, hostNanos: 1_000_666_000)
    #expect(out[0] == 0 && out[1] == 0)
    #expect(out.contains { $0 != 0 })
    #expect(player.toneStartNanos > 1_000_665_000 && player.toneStartNanos < 1_000_667_000)
}

@Test func sampleTimeJumpCountsADiscontinuity() {
    let player = makePlayer()
    _ = play(player, frames: 512, sampleTime: 0, hostNanos: 0)
    _ = play(player, frames: 512, sampleTime: 512, hostNanos: 0)
    #expect(player.discontinuities == 0)
    _ = play(player, frames: 512, sampleTime: 2048, hostNanos: 0)
    #expect(player.discontinuities == 1)
    #expect(player.framesRendered == 1536)
}

@Test func unexpectedBufferLayoutIsZeroedAndCounted() {
    let player = makePlayer()
    var samples = [Float](repeating: 9, count: 8)
    samples.withUnsafeMutableBytes { raw in
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
        var ts = AudioTimeStamp()
        withUnsafeMutablePointer(to: &list) { l in withUnsafePointer(to: &ts) { t in player.render(l, t) } }
    }
    #expect(samples.allSatisfy { $0 == 0 })
    #expect(player.unexpectedLayouts == 1)
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `cannot find 'TonePlayer' in scope`, non-zero exit.

- [ ] **Step 3: Write `Sources/DabberCore/Engine/TonePlayer.swift`**

```swift
import CoreAudio
import Foundation

public final class TonePlayer: @unchecked Sendable {
    private var tone: ToneGenerator
    private let startNanos: UInt64
    private var nextSampleTime = -1.0
    public private(set) var toneStartNanos: UInt64 = 0
    public private(set) var framesRendered = 0
    public private(set) var discontinuities = 0
    public private(set) var unexpectedLayouts = 0

    public init(tone: ToneGenerator, startNanos: UInt64) {
        self.tone = tone
        self.startNanos = startNanos
    }

    public func render(_ list: UnsafeMutablePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard buffers.count == 1, let data = buffers[0].mData, buffers[0].mNumberChannels > 0 else {
            for b in buffers { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            unexpectedLayouts += 1
            return
        }
        let channels = Int(buffers[0].mNumberChannels)
        let count = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
        let frames = count / channels
        let t = time.pointee
        if nextSampleTime >= 0, t.mSampleTime != nextSampleTime { discontinuities += 1 }
        nextSampleTime = t.mSampleTime + Double(frames)
        framesRendered += frames
        let out = UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
        let nanos = HostClock.nanos(hostTime: t.mHostTime)
        if toneStartNanos == 0, nanos >= startNanos { toneStartNanos = nanos }
        if toneStartNanos == 0 {
            out.update(repeating: 0)
        } else {
            tone.fill(out, channels: channels)
        }
    }
}
```

- [ ] **Step 4: Write `Sources/DabberCore/CoreAudio/OutputIOProcRunner.swift`**

```swift
import CoreAudio
import Foundation

public final class OutputIOProcRunner: @unchecked Sendable {
    public typealias Handler = @Sendable (UnsafeMutablePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>) -> Void

    private let device: AudioObjectID
    private var procID: AudioDeviceIOProcID?

    public init(device: AudioObjectID, handler: @escaping Handler) throws {
        self.device = device
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, _, _, output, outputTime in
                handler(output, outputTime)
            }, "create output ioproc")
        try check(AudioDeviceStart(device, procID), "start device")
    }

    public func stop() {
        guard let procID else { return }
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        self.procID = nil
    }
}
```

- [ ] **Step 5: Run tests**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `Test run with 94 tests ... passed`, `exit=0`.

- [ ] **Step 6: Add `--play-tone <uid> <seconds> <delaySeconds>` to `Headless.dispatch`**

It opens the device by UID, so it works for the hidden Dabber Feed. It plays silence for `delaySeconds`, then a 440 Hz tone at -12 dBFS until `seconds` have passed. Insert this case directly after the `--list-inputs` case:

```swift
        case "--play-tone":
            guard args.count == 4, let seconds = Double(args[2]), let delay = Double(args[3]) else { return 64 }
            let device = try deviceID(uid: args[1])
            guard device != kAudioObjectUnknown else {
                log.line("no device with uid \(args[1])")
                return 2
            }
            let streams = try getArray(
                device, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput),
                filler: AudioObjectID(0))
            guard let stream = streams.first else {
                log.line("device has no output stream")
                return 2
            }
            let f = try getValue(stream, address(kAudioStreamPropertyVirtualFormat), default: AudioStreamBasicDescription())
            log.line("output format: \(f.mSampleRate) Hz \(f.mChannelsPerFrame) ch flags \(f.mFormatFlags)")
            let bufferFrames = try getValue(device, address(kAudioDevicePropertyBufferFrameSize), default: UInt32(0))
            log.line("buffer frames: \(bufferFrames)")
            let player = TonePlayer(
                tone: ToneGenerator(frequency: 440, amplitude: 0.25),
                startNanos: HostClock.nowNanos() + UInt64(delay * 1e9))
            let runner = try OutputIOProcRunner(device: device) { list, time in player.render(list, time) }
            Thread.sleep(forTimeInterval: seconds)
            runner.stop()
            log.line("TONE_START_NANOS \(player.toneStartNanos)")
            log.line(
                "rendered frames=\(player.framesRendered) discontinuities=\(player.discontinuities) "
                    + "unexpectedLayouts=\(player.unexpectedLayouts)")
            return 0
```

- [ ] **Step 7: Build and check the missing-device path**

Run:
```zsh
scripts/build-app.sh
scripts/run-headless.sh "$PWD/build/tone-missing.log" --play-tone no-such-uid 1 0; echo "exit=$?"
```
Expected: log `no device with uid no-such-uid`, `EXIT 2`, `exit=1` (the script exits 1 because the log does not end in `EXIT 0`). The existing `Property.swift:43` warning and the two `ld: warning: search path` lines are expected in the build output.

- [ ] **Step 8: Commit**

```zsh
git add Sources/DabberCore/CoreAudio/OutputIOProcRunner.swift Sources/DabberCore/Engine/TonePlayer.swift \
  Tests/DabberCoreTests/TonePlayerTests.swift Sources/Dabber/Headless.swift
git diff --cached --stat
git commit -m "feat: add output ioproc tone player and headless play-tone command"
```

---

### Task 8: Spike B, loopback quality over 60 s (HUMAN: one listening check)

**Files:**
- Create: `docs/spikes/2026-09-23-spikeB-loopback.md`

The recorder records Dabber Mic as a mono track. Its converter uses `downmix = true`, which averages the channels (Plan 1b), so the identical L/R tone stays at -12 dBFS peak, about -15 dB RMS.

- [ ] **Step 1: Dabber Feed is reachable by UID and accepts output**

Run: `scripts/run-headless.sh "$PWD/build/feed-check.log" --play-tone Dabber_2_UID 2 0`
Expected:
- `output format: 48000.0 Hz 2 ch flags 9`
- `buffer frames: <n>` (record n)
- `TONE_START_NANOS` non-zero
- `rendered frames=` about 96000, `discontinuities=0 unexpectedLayouts=0`
- `EXIT 0`

`no device with uid Dabber_2_UID` means the hidden device is missing. Record it and stop.

- [ ] **Step 2: Play into the Feed while recording the Mic**

The tone command starts first and plays 5 s of silence, then the tone for 70 s. The recording starts about 1-2 s after it and lasts 60 s, so the tone begins about 3 s into the recording and runs past its end.

Run:
```zsh
rm -rf build/loopB
scripts/run-headless.sh "$PWD/build/feedB.log" --play-tone Dabber_2_UID 75 5 > /dev/null &
FEED=$!
sleep 1
scripts/run-headless.sh "$PWD/build/loopB.log" --record --mic Dabber_UID --seconds 60 --out "$PWD/build/loopB"
wait $FEED; echo "feed exit=$?"
cat build/feedB.log
```
Expected:
- `loopB.log`: per-second lines with `Dabber Mic: running` at about -15 dB after the onset, then `FINALIZED total=... gaps=1 resampled=0` and `EXIT 0`
- `feed exit=0`
- `feedB.log`: `rendered frames=` about 3,600,000 with `discontinuities=0 unexpectedLayouts=0`

- [ ] **Step 3: Checks on the recording**

Run:
```zsh
S=$(ls -d build/loopB/*/ | tail -1); M="$S/mic - Dabber Mic.m4a"
plutil -extract finalize.totalFrames raw "$S/session.json"
plutil -extract sources.0.segments raw "$S/session.json"
plutil -extract sources.0.overruns raw "$S/session.json"
ffmpeg -hide_banner -nostats -i "$M" -af silencedetect=n=-50dB:d=0.005 -f null - 2>&1 | grep -oE 'silence_(start|end): [0-9.]+'
ONSET=$(ffmpeg -hide_banner -nostats -i "$M" -af silencedetect=n=-50dB:d=0.005 -f null - 2>&1 | grep -m1 -oE 'silence_end: [0-9.]+' | awk '{print $2}')
START=$(plutil -extract sessionStartNanos raw "$S/session.json")
TONE=$(awk '/TONE_START_NANOS/ {print $3}' build/feedB.log)
awk -v s=$START -v o=$ONSET -v t=$TONE 'BEGIN { printf "onset %.4f s, timestamp delay %.3f ms\n", o, (s + o * 1e9 - t) / 1e6 }'
ffmpeg -hide_banner -nostats -ss $(( ONSET + 1 )) -t 50 -i "$M" -af astats=metadata=0:measure_perchannel=0:measure_overall=Peak_level+RMS_level -f null - 2>&1 | grep -oE '(Peak|RMS) level dB: .*'
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$M")
ffmpeg -hide_banner -nostats -i "$M" -af "highpass=f=2000,highpass=f=2000,asetnsamples=48000,astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.Peak_level:file=-" -f null - 2>/dev/null \
  | paste - - | awk -v o=$ONSET -v d=$DUR '{sub("pts_time:","",$3); sub(".*=","",$4); if ($4 != "-inf" && $3+0 >= o+1 && $3+0 < d-2 && $4+0 > -30) print "click second", $3, "peak", $4}'
```
Expected:
- totalFrames between 2,880,000 and 2,952,000 (60-61.5 s; the `--record` loop can overrun by up to a second)
- segments `1`, overruns `0`
- silencedetect prints only `silence_start: 0` and one `silence_end` of about 3: no silence after the onset means no dropouts
- `timestamp delay` within ±2 ms (see below)
- Peak about -12 dB, RMS about -15 dB
- **no** `click second` lines

Why the timestamp delay should be about 0: the Mic and Feed share one sample-time/host-time mapping, and the input reads the ring at the sample time the output wrote (ground rules). This number checks that no extra offset exists; it is not the wall-clock latency. The wall-clock latency is estimated from the code, not measured: Feed buffer plus Mic buffer, about 2 × `buffer frames` / 48000 s (both safety offsets are 0). Any delay value is recorded. Only a value above 50 ms, a dropout or a click line is a finding to report.

- [ ] **Step 4: Listening check (HUMAN)**

Tell the user:
> Run `afplay -t 20 "<M path>"` (I paste the full path).
> You should hear about 3 s of silence, then a steady beep.
> Tell me: any clicks, crackle or gaps? yes/no.

- [ ] **Step 5: Write `docs/spikes/2026-09-23-spikeB-loopback.md`**

Record:
- the Feed format and `buffer frames`;
- TONE_START_NANOS, sessionStartNanos, onset and the timestamp delay;
- the wall-clock latency estimate, marked as derived from code;
- totalFrames, segments and overruns;
- the full silencedetect output, the click-locator output (or "none") and the peak/RMS;
- the feed `rendered` line;
- The user's verdict;
- anything that differed from this plan.

- [ ] **Step 6: Commit**

```zsh
git add docs/spikes/2026-09-23-spikeB-loopback.md
git commit -m "docs: record spike b loopback results"
```

---

### Task 9: Tap exclusion by bundle ID and audio process listing (TDD)

**Files:**
- Create: `Tests/DabberCoreTests/GlobalTapTests.swift`
- Modify: `Sources/DabberCore/CoreAudio/GlobalTap.swift`, `Sources/DabberCore/CoreAudio/Devices.swift`, `Sources/DabberCore/Engine/CaptureSource.swift`, `Sources/DabberCore/Engine/ComputerAudioSource.swift`, `Sources/Dabber/Headless.swift`

Recording itself keeps no exclusions: `SourceSpec.excludedBundleIDs` defaults to empty, and only headless `--exclude-bundle` sets it for the spike. Plan 3b reuses `GlobalTap.description(excludingProcesses:bundleIDs:)` for the virtual-mic tap.

`isProcessRestoreEnabled` is set explicitly even though it already defaults to `true`, so a change of that default cannot silently change behaviour.

- [ ] **Step 1: Write the failing tests `Tests/DabberCoreTests/GlobalTapTests.swift`**

```swift
import CoreAudio
import Testing
@testable import DabberCore

@Test func tapWithoutBundleIDsExcludesOnlyProcesses() {
    let d = GlobalTap.description(excludingProcesses: [42], bundleIDs: [])
    #expect(d.isExclusive)
    #expect(d.processes == [42])
    #expect(d.bundleIDs.isEmpty)
}

@Test func tapExcludesBundleIDsWithProcessRestore() {
    let d = GlobalTap.description(excludingProcesses: [42], bundleIDs: ["com.apple.Safari", "com.apple.WebKit.GPU"])
    #expect(d.isExclusive)
    #expect(d.processes == [42])
    #expect(d.bundleIDs == ["com.apple.Safari", "com.apple.WebKit.GPU"])
    #expect(d.isProcessRestoreEnabled)
}

@Test func audioProcessesIncludeThisProcess() throws {
    #expect(try audioProcesses().contains { $0.pid == getpid() })
}
```

- [ ] **Step 2: Run, expect compile failure**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `type 'GlobalTap' has no member 'description'` and `cannot find 'audioProcesses' in scope`, non-zero exit.

- [ ] **Step 3: Change `GlobalTap` in `Sources/DabberCore/CoreAudio/GlobalTap.swift`**

Replace the start of `init`:
```swift
    public init() throws {
        let me = try processObject(pid: getpid())
        let excluded: [AudioObjectID] = me == kAudioObjectUnknown ? [] : [me]
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
```
with
```swift
    public init(excludingBundleIDs bundleIDs: [String] = []) throws {
        let me = try processObject(pid: getpid())
        let description = Self.description(
            excludingProcesses: me == kAudioObjectUnknown ? [] : [me], bundleIDs: bundleIDs)
```
and add, directly before `public func destroy()`:
```swift
    static func description(excludingProcesses processes: [AudioObjectID], bundleIDs: [String]) -> CATapDescription {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        if !bundleIDs.isEmpty {
            description.bundleIDs = bundleIDs
            description.isProcessRestoreEnabled = true
        }
        return description
    }

```

- [ ] **Step 4: Append to `Sources/DabberCore/CoreAudio/Devices.swift`**

```swift

public struct AudioProcess: Sendable, Equatable {
    public let pid: pid_t
    public let bundleID: String
    public let isRunningOutput: Bool
}

public func audioProcesses() throws -> [AudioProcess] {
    let ids = try getArray(systemObject, address(kAudioHardwarePropertyProcessObjectList), filler: AudioObjectID(0))
    return ids.compactMap { id in
        guard let pid = try? getValue(id, address(kAudioProcessPropertyPID), default: pid_t(-1)) else { return nil }
        let running = (try? getValue(id, address(kAudioProcessPropertyIsRunningOutput), default: UInt32(0))) ?? 0
        return AudioProcess(
            pid: pid,
            bundleID: (try? getString(id, address(kAudioProcessPropertyBundleID))) ?? "",
            isRunningOutput: running != 0)
    }
}
```

- [ ] **Step 5: Carry exclusions through `SourceSpec` and `ComputerAudioSource`**

In `Sources/DabberCore/Engine/CaptureSource.swift` replace
```swift
    public let name: String

    public init(kind: SourceKind, uid: String?, name: String) {
        self.kind = kind
        self.uid = uid
        self.name = name
    }
```
with
```swift
    public let name: String
    public let excludedBundleIDs: [String]

    public init(kind: SourceKind, uid: String?, name: String, excludedBundleIDs: [String] = []) {
        self.kind = kind
        self.uid = uid
        self.name = name
        self.excludedBundleIDs = excludedBundleIDs
    }
```

In `Sources/DabberCore/Engine/ComputerAudioSource.swift` replace `let tap = try GlobalTap()` with
```swift
        let tap = try GlobalTap(excludingBundleIDs: spec.excludedBundleIDs)
```

- [ ] **Step 6: Run tests**

Run: `scripts/test.sh; echo "exit=$?"`
Expected: `Test run with 97 tests ... passed`, `exit=0`.

- [ ] **Step 7: Headless: `--list-audio-processes` and `--record ... --exclude-bundle <id>`**

In `Sources/Dabber/Headless.swift`, insert after the `--list-inputs` case:
```swift
        case "--list-audio-processes":
            for p in try audioProcesses() {
                log.line("\(p.pid)\t\(p.isRunningOutput ? "OUT" : "-")\t\(p.bundleID)")
            }
            return 0
```
In the `--record` case, after `var specs: [SourceSpec] = []` add:
```swift
            var excluded: [String] = []
```
In its option switch, before `case "--seconds":` add:
```swift
                case "--exclude-bundle":
                    i += 1
                    guard i < args.count else { return 64 }
                    excluded.append(args[i])
```
Directly after `guard !specs.isEmpty, seconds > 0 else { return 64 }` add:
```swift
            specs = specs.map { s in
                s.kind == .computer
                    ? SourceSpec(kind: s.kind, uid: s.uid, name: s.name, excludedBundleIDs: excluded) : s
            }
```

- [ ] **Step 8: Build and run the process list**

Run:
```zsh
scripts/build-app.sh
scripts/run-headless.sh "$PWD/build/procs.log" --list-audio-processes
```
Expected: one line per audio process (`pid`, `OUT` or `-`, bundle ID), including `local.dabber.Dabber` and, if Safari is open, `com.apple.Safari` and one or more `com.apple.WebKit.GPU` lines; `EXIT 0`.

- [ ] **Step 9: Commit**

```zsh
git add Tests/DabberCoreTests/GlobalTapTests.swift Sources/DabberCore/CoreAudio/GlobalTap.swift \
  Sources/DabberCore/CoreAudio/Devices.swift Sources/DabberCore/Engine/CaptureSource.swift \
  Sources/DabberCore/Engine/ComputerAudioSource.swift Sources/Dabber/Headless.swift
git diff --cached --stat
git commit -m "feat: exclude apps from the computer audio tap by bundle id and list audio processes"
```

---

### Task 10: Spike C, exclusion by bundle ID (HUMAN: Safari)

**Files:**
- Create: `docs/spikes/2026-09-23-spikeC-exclusion.md`

Four 40-60 s recordings of computer audio only:
- **C1**: no exclusion (control: the clip is captured at all).
- **C2**: exclude `com.apple.Safari` only (does Safari's ID cover its WebKit helpers?).
- **C3**: exclude `com.apple.Safari` and `com.apple.WebKit.GPU`.
- **C4**: same as C3, but Safari is started after the tap exists (process restore).

`afplay` plays `Submarine.aiff` (1.5 s) at fixed times as the "other app" sound. Check: `silencedetect n=-50dB d=1` on `computer audio.m4a`. The clip shows up as non-silence; an excluded clip leaves silence except the afplay sounds.

- [ ] **Step 1: Start the clip (HUMAN)**

Tell the user:
> Open Safari, play a YouTube video with continuous sound (music is best).
> Keep it playing at normal volume, sound not muted. Tell me when it plays.

Then run `scripts/run-headless.sh "$PWD/build/procsC.log" --list-audio-processes` and expect a `com.apple.WebKit.GPU` line marked `OUT`.

- [ ] **Step 2: C1, C2, C3 (clip keeps playing)**

Run:
```zsh
SUB=/System/Library/Sounds/Submarine.aiff
for run in C1 C2 C3; do
  case $run in
    C1) ex=() ;;
    C2) ex=(--exclude-bundle com.apple.Safari) ;;
    C3) ex=(--exclude-bundle com.apple.Safari --exclude-bundle com.apple.WebKit.GPU) ;;
  esac
  rm -rf build/excl$run
  ( sleep 10; afplay $SUB; sleep 13; afplay $SUB ) &
  scripts/run-headless.sh "$PWD/build/excl$run.log" --record --computer-audio "${ex[@]}" --seconds 40 --out "$PWD/build/excl$run"
  wait
done
```
Expected: each log ends with `FINALIZED ...` and `EXIT 0`. If a run logs `ERROR` with `create process tap`, record the error: the OS rejected the description, which answers the spike.

- [ ] **Step 3: C4, Safari starts after the tap (HUMAN runs it)**

Tell the user:
> Quit Safari completely (Cmd-Q) and tell me.

Run `scripts/run-headless.sh "$PWD/build/procsC4-before.log" --list-audio-processes` (expect no `com.apple.Safari` line). Then tell the user:
> Paste this in Terminal. Right after Enter, open Safari and start the same video within 30 s.
> Keep it playing. You will hear two submarine sounds near the end.
> Tell me when the command finishes.

```zsh
cd dabber
rm -rf build/exclC4
( sleep 40; afplay /System/Library/Sounds/Submarine.aiff; sleep 8; afplay /System/Library/Sounds/Submarine.aiff ) &
scripts/run-headless.sh "$PWD/build/exclC4.log" --record --computer-audio --exclude-bundle com.apple.Safari --exclude-bundle com.apple.WebKit.GPU --seconds 60 --out "$PWD/build/exclC4"; wait
```
Then, while the clip still plays, run `scripts/run-headless.sh "$PWD/build/procsC4-after.log" --list-audio-processes`. Expect a `com.apple.WebKit.GPU` `OUT` line whose pid is not in `procsC.log`: a new helper process started after the tap was created.

- [ ] **Step 4: Analyse**

Run:
```zsh
for run in C1 C2 C3 C4; do
  S=$(ls -d build/excl$run/*/ | tail -1)
  echo "== $run"
  ffmpeg -hide_banner -nostats -i "$S/computer audio.m4a" -af silencedetect=n=-50dB:d=1 -f null - 2>&1 | grep -oE 'silence_(start|end): [0-9.]+' | paste - -
done
grep -E 'WebKit|Safari' build/procsC.log build/procsC4-before.log build/procsC4-after.log
```
Expected:
- **C1**: no silence lines (the clip is present throughout). If C1 shows long silence, the clip was not playing or the tap missed it. Redo Step 1 before trusting C2-C4.
- **C3**: silence from 0 to about 9 s, from about 10.5 to about 23.5 s, and from about 25 s to the end. That means the clip is absent and the afplay sounds are present. Times can shift by about 1 s with app launch.
- **C4**: silence everywhere except about 39-41 s and 47-50 s.
- **C2**: a fact, not pass/fail. C3-like output means excluding `com.apple.Safari` alone covers its helpers; C1-like output means `com.apple.WebKit.GPU` must be in the list.

Only if an automatic result is ambiguous (for example short non-silent bits in C3 outside the afplay times): ask the user to listen with `afplay "<file>"` and say whether they hear music.

- [ ] **Step 5: Write `docs/spikes/2026-09-23-spikeC-exclusion.md`**

Record:
- the four silencedetect outputs;
- the process lines (pids, bundle IDs, OUT flags) before and after C4;
- the answers to three questions:
  1. Does `com.apple.Safari` alone exclude its WebKit audio?
  2. Do `com.apple.Safari` plus `com.apple.WebKit.GPU` exclude it?
  3. Is a WebKit helper that starts after the tap excluded?
- that `processRestoreEnabled` already defaults to `true`;
- that excluding `com.apple.WebKit.GPU` also excludes every other WebKit-based app's audio (Mail, in-app web views). That follows from the bundle ID; it was not tested.

Also record whether `processes` (Dabber's own process) still applies when `bundleIDs` is set. It was not testable here because Dabber plays nothing during the runs; say so. End with the bundle ID set recommended for "Safari" in Plan 3b, derived only from these runs.

- [ ] **Step 6: Commit**

```zsh
git add docs/spikes/2026-09-23-spikeC-exclusion.md
git commit -m "docs: record spike c exclusion results"
```

---

## After this plan

Plan 3b is written from `docs/spikes/2026-09-23-spikeA-*.md`, `spikeB-*.md` and `spikeC-*.md`. It covers:
- the private aggregate per virtual-mic session: main device Dabber Feed, sub-device the chosen mic, the tap with the bundle ID set from Spike C, drift compensation;
- one IOProc that mixes with the existing `Mixer` rules and writes the Feed, reusing `OutputIOProcRunner` patterns;
- restart on the recording trigger set;
- the "Virtual mic" menu section and settings in UserDefaults;
- the status model, including "driver not installed" when `deviceID(uid: "Dabber_UID")` is unknown;
- unit tests for exclusion list to bundle ID set, settings persistence and status.

Keep `--play-tone Dabber_2_UID 2 0` as the post-install driver self-test.
