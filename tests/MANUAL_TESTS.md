# Manual hardware tests

These tests need a person pressing real buttons on the GOOJODOQ M21. Record each result in the table at the bottom, with the date and connection type.

Preconditions:
- At least 3 Spaces exist. In Mission Control, click `+`.
- Mission Control shortcuts are enabled: System Settings > Keyboard > Keyboard Shortcuts > Mission Control > "Move left a space" / "Move right a space".

| ID | Test | Steps | Expected |
|---|---|---|---|
| H1 | Button detection | `scripts/diagnose.sh 45`, then press left, right, back ×3, forward ×3 | Summary shows two distinct `otherMouseDown buttonNumber=N` values, 3 each. No keyDown or systemDefined from the side buttons |
| H2 | Calibration | `scripts/calibrate.sh` | Writes `config/config.json` with `"verified": true` and the numbers from H1 |
| H3 | Previous Desktop | Controller running. Go to Space 2, press BACK | Moves to Space 1. One step only |
| H4 | Next Desktop | Press FORWARD | Moves to the next Space. One step only |
| H5 | No double trigger | Press BACK twice quickly (<300 ms) | One switch only. Log shows a single `-> Previous Desktop` |
| H6 | Browser not affected | In Safari/Chrome with history, press BACK | Space switches; the page does **not** navigate back (original event suppressed) |
| H7 | Normal clicks | Left-click, right-click, middle-click, drag-select text, scroll | All behave exactly as without the controller |
| H8 | Reload | Edit `debounceMs`, run `scripts/reload.sh` | Log shows `config reloaded`; buttons still work |
| H9 | Kill switch | `scripts/disable.sh`, press BACK | No Space switch; browser Back works again |
| H10 | Login start | `scripts/enable.sh`, log out and back in, press FORWARD | Switches Space with no manual start |
| H13 | Click 3 | Single-press buttonNumber 3 | Mission Control opens after ~0.25 s; Desktop does NOT switch. Log: `button 3 -> Mission Control` |
| H14 | Click 4 | Single-press buttonNumber 4 | App Exposé opens after ~0.25 s |
| H15 | Double-click 3 / 4 | Double-click buttonNumber 3, then 4 | 3 moves one Desktop left, 4 moves one Desktop right; Mission Control / App Exposé do NOT open |
| H11 | Bluetooth | Run H1, H3 and H4 over Bluetooth | Pass |
| H12 | 2.4 GHz dongle | Plug in the receiver, switch the mouse to 2.4G, repeat H1, H3, H4 | Pass, same button numbers (if they differ, see ISSUE-007) |

## Results

| Date | Connection | Tests | Result | Notes |
|---|---|---|---|---|
| 2026-11-21 | Bluetooth LE | H1 (detection) | PASS | buttonNumber 3 (HID 4) and 4 (HID 5) from M21-Mouse vid 0x32C2 pid 0x6621; no keyboard/consumer events |
| 2026-11-21 | Bluetooth LE | H2 (calibration) | PASS | previous=buttonNumber 4, next=buttonNumber 3; config.json verified=true |
| 2026-11-21 | Bluetooth LE | H3–H7 (previous/next switching, no double trigger, browser, normal clicks) | PASS (user-reported) | controller.log: 24 actions (14 next, 10 previous), 0 failures |
