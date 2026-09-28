# Dabber: mark hotkey

Date: 2026-09-28. Status: design approved in chat.

## Why

During a call, opening the menu to press **Mark** is awkward, especially while sharing the screen. A hotkey that
does not clash with any app is needed.

## Decisions

| Topic | Decision |
|---|---|
| Gesture | Double-tap the left Option key (⌥⌥), not configurable |
| When | Only while recording; a no-op otherwise |
| Result | Same as the Mark button: a mark at the moment of the second tap; its comment can be typed in the menu |
| Feedback | A short system sound when the mark is made |
| Permission | Input Monitoring (a listen-only `CGEventTap`), asked at the first recording |
| Without permission | Everything works as before; the menu says how to allow it |

## Behaviour

- A tap is a press and release of the left Option key alone: no other modifier held, no key pressed in between, and
  released within 0.4 s. Two taps whose releases are less than 0.4 s apart make a mark. Any other key or modifier
  in between cancels, so typing ⌥+letter never makes a mark.
- The keyboard listener exists only while a recording runs. It only observes events and never changes or blocks them.
- If the system disables the listener (timeout), it is enabled again.
- While recording, under the Mark button the menu shows "Double-tap left ⌥ to mark", or "Allow Input Monitoring
  for the ⌥⌥ hotkey" when the permission is missing.

## Units

- `DoubleTap` (DabberCore, Model): pure detector fed with (key, time). Tested.
- `MarkHotkey` protocol + `RecorderModel` wiring: start with the recording, stop with it, hint text. Tested with a
  fake.
- `LiveMarkHotkey` (Dabber app): the `CGEventTap`. Hardware check only.

## Out of scope

Other gestures or keys, a setting to change the key, hotkeys for Record or Stop.
