# Spike A: does coreaudiod load the self-signed driver

Date: 2026-09-23. macOS 26.6.2, arm64. Driver built by `scripts/build-driver.sh` (BlackHole v0.7.1 fork).

## Result: loaded

- Designated requirement: `identifier "local.dabber.DabberMic" and certificate leaf = H"<certificate hash>"`
  (the self-signed "Dabber Dev" identity; no Developer ID, no ad-hoc fallback needed).
- coreaudiod log after `scripts/install-driver.sh`:
  - `HALS_RemotePlugInRegistrar.mm:237 Attempting to load:  DabberMic.driver`
  - `HALS_RemotePlugInRegistrar.mm:421 Creating remote driver service: ... "DabberMic.driver", pid: 32965`
  - `HALS_Device::Activate: activating device 104: Dabber_UID`
  - `HALS_Device::Activate: activating device 110: Dabber_2_UID`
- Helper process: `32965 Core Audio Driver (DabberMic.driver)`.
- `--list-inputs`: `Dabber_UID	Dabber Mic`.
- `system_profiler SPAudioDataType`: `Dabber Mic:` Input Channels 2, Manufacturer Dabber, Current SampleRate 48000,
  Transport Virtual. Dabber Feed (hidden) is not listed there or in `--list-inputs`.

## Uninstall round trip

`scripts/uninstall-driver.sh`, then:
- `HAL-SAME` (HAL folder listing equals the pre-install listing) and `DIPPER-SAME` (Dipper binary mtime/size unchanged).
- Helpers running: Dipper.driver and ParrotAudioPlugin.driver only; no Dabber Mic in the inputs.
- `/Library/Preferences/Audio/com.apple.audio.SystemSettings.plist` keeps 2 lines mentioning Dabber (per-device
  settings coreaudiod keeps for every device it has seen; expected, not removed by either uninstaller).

Reinstalled afterwards for Spikes B and C: `Dabber_UID	Dabber Mic` present again.
