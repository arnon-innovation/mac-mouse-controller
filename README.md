# mac-mouse-controller

A free, dependency-free macOS controller for the **GOOJODOQ Triple Connectivity M21** mouse:

- **Back** side button → **Previous Desktop** (Space)
- **Forward** side button → **Next Desktop**

It is native Swift and uses only system frameworks: CGEventTap, IOKit HID and launchd. It does not need Hammerspoon or BetterTouchTool. Design rationale: [docs/adr/ADR-001](docs/adr/ADR-001-native-swift-event-tap.md).

## How it works

1. A CGEventTap listens **only** to extra-button events (`otherMouseDown/Up/Dragged`). Left and right clicks, pointer movement and scrolling are not in the tap mask, so the controller never sees them and cannot delay them.
2. When a mapped button goes down, the controller posts the keystroke you have configured. By default that is the macOS Mission Control shortcut: **Ctrl+←** for "Move left a space" and **Ctrl+→** for "Move right a space".
3. The button's own events are swallowed, so a browser won't also navigate Back. Set `suppressOriginalEvent: false` to let them through.

## Layout

```
config/      config.example.json (template, unverified); config.json is written by calibrate
src/Core/    pure logic: config + validation, engine (matching, debounce), key table
src/App/     macOS integration + CLI (diagnose, calibrate, run, send, ...)
scripts/     build, install, uninstall, diagnose, calibrate, reload, toggle, disable, enable, status
tests/       CoreTests (XCTest), integration.sh (no hardware), MANUAL_TESTS.md (hardware)
docs/        ADRs, ISSUES.md (issue log)
logs/        controller.log, diagnostic-*.log, calibrate-*.log
resources/   Info.plist for MouseController.app
```

## Requirements

- macOS 13 or later. Developed on macOS 27.2.1 (Apple silicon).
- Xcode or the Command Line Tools (Swift 6).
- Recommended: a code-signing certificate. A free "Apple Development" certificate is enough. Without one, permissions reset on every rebuild (ISSUE-004).
- In System Settings > Keyboard > Keyboard Shortcuts > Mission Control, enable **Move left a space** and **Move right a space**.
- More than one Space: open Mission Control and click `+`.

## 1. Diagnose: find your real button numbers

Nothing is hardcoded. First, see what the mouse actually sends:

```sh
cd ~/mac-mouse-controller
scripts/diagnose.sh 45        # 45-second listen-only session, nothing is remapped
```

While it runs:
1. Click left and right once each.
2. Press **Back** 3 times, slowly.
3. Press **Forward** 3 times, slowly.

The summary at the end counts `otherMouseDown buttonNumber=N` per button. The full log is in `logs/diagnostic-*.log`. Each event is logged with:
- the CGEvent type, `buttonNumber` and click state;
- the source PID;
- with Input Monitoring granted, also the raw HID usage per device, e.g. `M21-Mouse [Bluetooth Low Energy vid=0x32C2 pid=0x6621] page=Button usage=0x4 value=1`.

How to read the results:
- Two distinct `otherMouseDown` numbers (commonly 3 and 4): good, continue to step 2.
- Side buttons appear as `keyDown`, `systemDefined` or `page=Consumer`: the mouse sends keyboard or media codes on that connection, and the button mapping can't catch them. See ISSUE-006 in [docs/ISSUES.md](docs/ISSUES.md).

Repeat the diagnosis for **each connection mode** (Bluetooth, and 2.4 GHz with the USB receiver).

`diagnose.sh` and `calibrate.sh` run through `MouseController.app`. On the first run, macOS asks for **Input Monitoring** for MouseController. Enable it under System Settings > Privacy & Security > Input Monitoring, then run the script again.

If the summary says **"NO input events were received"**, even for left/right clicks, the problem is the permission, not the mouse (ISSUE-009).

## 2. Calibrate: write a verified config

```sh
scripts/calibrate.sh
```

No prompts need to be watched:
1. Press the side button you want for **Previous desktop** 2–3 times.
2. Then press the other side button (**Next desktop**) 2–3 times.

Normal clicks and repeated presses are ignored. It finishes as soon as each button has been pressed at least twice. It then writes `config/config.json` with `"verified": true` and the device and button numbers. Any existing config is backed up first.

If the direction turns out to be reversed, run `scripts/swap.sh`. It swaps the two buttons, keeps a backup, and reloads the running controller.

`run` refuses any config that is not verified.

## 3. Install: start at login

```sh
scripts/install.sh
```

This:
1. builds and signs `MouseController.app`;
2. copies it to `~/Applications`;
3. writes `~/Library/LaunchAgents/com.arnon.mouse-controller.plist` and starts it.

An existing app or plist is backed up first.

### Permissions

| Permission | Who needs it | Where |
|---|---|---|
| **Accessibility** | the controller (`mouse-controller` / MouseController.app), to intercept the side buttons and post Ctrl+Arrow | System Settings > Privacy & Security > Accessibility |
| **Input Monitoring** | MouseController, for `diagnose` and `calibrate` (without it the tap receives nothing) | System Settings > Privacy & Security > Input Monitoring |
| Accessibility | your **terminal**, only if you use `send` or run `mouse-controller run` by hand | same |

On first start, macOS shows an Accessibility prompt for `mouse-controller`. Enable it, and the running agent notices within about 5 s; no restart is needed. If no prompt appears, add `~/Applications/MouseController.app` manually with the `+` button.

## Configuration

`config/config.json`:

```json
{
  "enabled": true,
  "suppressOriginalEvent": true,
  "debounceMs": 300,
  "verified": true,
  "verificationNote": "calibrated ... on M21-Mouse [...]: back=buttonNumber 3, forward=buttonNumber 4",
  "mappings": [
    { "name": "Previous Desktop", "button": 3, "action": { "key": "leftArrow",  "modifiers": ["control"] } },
    { "name": "Next Desktop",     "button": 4, "action": { "key": "rightArrow", "modifiers": ["control"] } }
  ]
}
```

- `button` is the CGEvent `buttonNumber`, the value reported by diagnose. Numbers 0 and 1 (left and right click) are rejected.
- `key` can be `leftArrow`, `rightArrow`, `upArrow`, `downArrow`, `0`–`9`, `leftBracket`, `rightBracket`, `tab`, `space`, `escape`, `return`, `f3` or `f4`.
- `modifiers` can be `control`, `option`, `command` or `shift`.
- Example: to use "Switch to Desktop 1" (Ctrl+1) instead, set `"key": "1"` after enabling that shortcut in Keyboard Shortcuts.
- `debounceMs` is the minimum gap between two triggers of the same button (0–5000). It prevents double switches from switch bounce or fast double presses.
- If you changed the Mission Control shortcuts, change `action` to match.

After editing, check the file and then apply it:

```sh
~/Applications/MouseController.app/Contents/MacOS/mouse-controller validate
scripts/reload.sh      # applies without restart; an invalid config is rejected and the old one stays active
```

## Disable / control

| Goal | Command |
|---|---|
| **Kill switch**: stop now and stay off, including at next login | `scripts/disable.sh` |
| Turn it back on | `scripts/enable.sh` |
| Pause or resume without stopping (not persisted) | `scripts/toggle.sh` |
| Reload the config | `scripts/reload.sh` |
| Previous/Next reversed | `scripts/swap.sh` |
| Status and recent log | `scripts/status.sh` |
| Remove completely (config and logs kept) | `scripts/uninstall.sh` |
| No terminal at hand | Activity Monitor → quit `mouse-controller` (launchd does not restart a clean quit) |

## Testing

```sh
swift test                     # unit tests (engine, debounce, config validation, key flags)
tests/integration.sh           # CLI and config behaviour, no hardware needed
tests/integration.sh --agent   # plus the installed agent: reload, pause/resume, crash restart
```

Hardware tests (real button presses, Space switching, clicks unaffected, Bluetooth vs 2.4 GHz) are in [tests/MANUAL_TESTS.md](tests/MANUAL_TESTS.md).

## Reliability features

- **Debounce:** per button, configurable.
- **No repeated triggers:** a second "down" without an "up" never re-fires, and a hold that has gone stale (over 3 s) is cleared.
- **Event-tap watchdog:** if macOS disables the tap (timeout or user input), it is re-enabled and logged.
- **Fast callback:** keystrokes are posted after the tap callback returns, so the callback stays fast.
- **Safe reload:** `SIGHUP` reloads; invalid or unverified configs are rejected and the previous config stays active.
- **launchd restarts:** after a crash it restarts the controller (10 s throttle). After a clean stop it does not.
- **Permission wait:** if Accessibility is missing at login, the controller waits rather than crash-looping.
- **Log rotation:** `logs/controller.log` rotates at 5 MB, keeping one older file.

## Known limitations

- There is no public macOS API for switching Spaces. The controller relies on the Mission Control keyboard shortcuts being enabled.
- Spaces switching moves one Space per press. macOS ignores the shortcut while the Spaces animation is still running, so very fast presses may be dropped by macOS itself.
- Mappings apply to **all** mice. If another mouse sends the same button numbers, it gets the same mapping.
- 2.4 GHz mode is untested (ISSUE-007). Logi Options+ coexistence has not been characterized (ISSUE-008).
- In secure input fields (password prompts), macOS may block synthetic keystrokes.
- `current-space` uses a private SkyLight call for diagnostics only. It may break in a future macOS release; the controller does not depend on it.
