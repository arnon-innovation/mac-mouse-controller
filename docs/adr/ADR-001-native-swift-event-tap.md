# ADR-001: Native Swift CGEventTap instead of Hammerspoon

- Status: **Accepted**
- Date: 2026-11-21

## Context

We need the GOOJODOQ M21's two side buttons to switch macOS Spaces. The solution has to be free, light, and start at login. BetterTouchTool is excluded because it is paid.

What we found when we inspected the environment on 2026-11-21:
- macOS 27.2.1 on arm64.
- Swift 6.4.2 and Xcode are installed.
- Hammerspoon is **not** installed.
- A valid "Apple Development" code-signing identity is present.
- The M21 connects over BLE as `M21-Mouse`, VID 0x32C2, PID 0x6621. Its report descriptor declares 8 mouse buttons plus a Consumer Control array (report ID 3).

## Options

| | Hammerspoon + Lua | Native Swift (chosen) |
|---|---|---|
| New dependencies | Hammerspoon.app (~20 MB) running all the time | none (system frameworks only) |
| Mechanism | `hs.eventtap`, which is itself a CGEventTap | CGEventTap directly |
| Footprint | full Lua runtime, menu-bar app | single ~200 KB binary |
| Raw HID diagnostics | not available | IOHIDManager |
| Unit testing | hard (needs the Hammerspoon runtime) | XCTest on a pure Core module |
| Permission identity | Hammerspoon.app, shared with every other script | its own signed bundle |

## Decision

We chose native Swift, built with SwiftPM and split into two modules:
- `MouseControllerCore`: pure logic (config, validation, trigger engine, debounce, key table). It has no OS dependencies and is unit-tested.
- `mouse-controller` (CLI): the macOS integration. Commands are `diagnose`, `calibrate`, `run`, `send`, `check-permissions`, `validate` and `current-space`.

The binary ships as a signed `MouseController.app` (LSUIElement) and is started by a per-user LaunchAgent.

The Spaces switch uses the user's existing **Mission Control keyboard shortcuts** (Ctrl+← / Ctrl+→ by default; symbolic hotkeys 79/81). There is no public API for switching Spaces. The private SkyLight `CGSGetActiveSpace` is used **only** to read the active Space ID in diagnostics and tests, never to switch.

## Consequences

- Accessibility permission is required for the active tap and for posting keystrokes.
- If the user changes the Mission Control shortcuts, they must change `action` in the config to match.
- The bundle must be signed with a certificate. Otherwise TCC grants reset on every rebuild (ISSUE-004).
- Left and right clicks are never part of the tap mask, so this design cannot structurally interfere with normal clicking.
