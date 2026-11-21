# Issue log

Each entry is mirrored as a GitHub Issue with the same number (ISSUE-007 = #7): https://github.com/arnon-innovation/mac-mouse-controller/issues. Open problems are tracked on GitHub; this file keeps the full history in the repo. Each entry records reproduction steps, expected vs actual behaviour, root cause, resolution and verification. Commit references are filled in once the change is committed.

Status values:
- `OPEN`: not resolved.
- `RESOLVED`: fixed and verified.
- `MITIGATED`: handled, but the platform constraint remains.
- `PREVENTIVE`: a known platform pitfall that was designed around before it could happen here.

---

## ISSUE-001 — HID diagnostic layer fails without Input Monitoring: `MITIGATED`

- **Found:** 2026-11-21, first `diagnose` run from Ghostty.
- **Repro:** run `mouse-controller diagnose --timeout 3` from a terminal that lacks Input Monitoring.
- **Expected:** raw HID button values are logged.
- **Actual:** `IOHIDManagerOpen=0xE00002E2` (`kIOReturnNotPermitted`). The device-matching callbacks still fire (`M21-Mouse [Bluetooth Low Energy vid=0x32C2 pid=0x6621]`), but no input values arrive.
- **Root cause:** TCC `kTCCServiceListenEvent` gates opening HID devices for input. The responsible app is the terminal, not the binary.
- **Resolution:** diagnose logs a clear warning instead of failing.
- **Correction (2026-11-21):** the original note said the CGEvent layer still works without this permission. That was **wrong**: see ISSUE-009.

## ISSUE-002 — Synthetic Ctrl+Arrow may be ignored by Spaces without the Fn/NumericPad flags: `PREVENTIVE`

- **Background:** a physical arrow key carries `kCGEventFlagMaskSecondaryFn | kCGEventFlagMaskNumericPad` (0x800000 | 0x200000). The WindowServer symbolic-hotkey matcher for "Move left/right a space" compares the full flag set. A synthetic Ctrl+Arrow with only the Control flag is widely reported to be ignored.
- **Resolution:** `KeyTable.flags(for:)` always adds Fn and NumericPad to the arrow keys. The flags sent for Ctrl+→ are `0xA40000`.
- **Prevention:** the `KeyTableTests.testControlLeftArrowFlags` regression test.
- **Verification:** end-to-end switching is to be confirmed by H3/H4 and `send next` once Accessibility is granted (see ISSUE-003).

## ISSUE-003 — Posted keystrokes are silently dropped without Accessibility: `MITIGATED`

- **Found:** 2026-11-21.
- **Repro:** run `mouse-controller send next` from Ghostty while it lacks Accessibility.
- **Expected:** the Space switches.
- **Actual:** the Space is unchanged (`space: 90 -> 90`). `CGEvent.post` returned with no error.
- **Root cause:** macOS drops synthetic events from processes without post-event access (Accessibility) and reports nothing to the poster.
- **Resolution:**
  - `send` and `run` check `CGPreflightPostEventAccess()` and warn.
  - Under launchd, `run` triggers the Accessibility prompt once and then polls every 5 s rather than crash-looping. Once the grant is given, it starts without a restart.
  - `check-permissions` reports all three permissions.
- **Verification:** the warning was observed in the output above.

## ISSUE-004 — TCC grants are lost on every rebuild with ad-hoc signing: `RESOLVED`

- **Background:** TCC stores a grant together with the code's designated requirement. For an ad-hoc signature that requirement is the cdhash, which changes on every build. The permission then silently stops applying and the event tap fails to start.
- **Resolution:** `scripts/build.sh` signs the `.app` with the first available Apple Development or Developer ID identity, using the fixed identifier `com.arnon.mouse-controller`. It falls back to ad-hoc only with a loud warning.
- **Verification:** the designated requirement is `identifier "com.arnon.mouse-controller" and anchor apple generic and certificate leaf[...]`, which is stable across builds. This is covered by the integration test "stable (certificate-based) designated requirement".
- **Verified on hardware (2026-11-21):** Input Monitoring was granted to MouseController, then the app was rebuilt (new cdhash). The next run still showed `HID monitor active` and received events, so the grant survived the rebuild.

## ISSUE-005 — Integration test false negative caused by `pipefail`: `RESOLVED`

- **Found:** 2026-11-21, first run of `tests/integration.sh`.
- **Repro:** `cmd_that_exits_1 | grep -q pattern && ok || bad` with `set -o pipefail`.
- **Expected:** PASS when the pattern is present.
- **Actual:** "FAIL left-click rejection message", even though the message was correct.
- **Root cause:** with `pipefail`, the pipeline's status is the producer's intentional non-zero exit, not grep's.
- **Resolution:** capture the output first (`out="$(...)"`), then run `grep -q ... <<<"$out"`. All 5 piped checks were converted.
- **Verification:** `tests/integration.sh` gives passed=14 failed=0.

## ISSUE-006 — Side-button numbers not yet verified on hardware: `RESOLVED` (Bluetooth LE)

- **Status:** the report descriptor allows HID buttons 1–8 (CGEvent `buttonNumber` 0–7) **or** consumer usages through report ID 3. The convention would be buttonNumber 3/4, but nothing is hardcoded until physical presses confirm it.
- **Next step:** the user runs `scripts/diagnose.sh` and then `scripts/calibrate.sh`.
- **Close when:** H1 and H2 in `tests/MANUAL_TESTS.md` pass.
- **Progress, 2026-11-21 (Bluetooth LE):** H1 passed. Both side buttons arrive as **real mouse buttons** from `M21-Mouse [Bluetooth Low Energy vid=0x32C2 pid=0x6621]`:
  - HID Button usage 0x4 → CGEvent `buttonNumber=3` (3 presses);
  - HID Button usage 0x5 → CGEvent `buttonNumber=4` (4 presses).
  - They do not appear as keyDown or Consumer events. Each press is accompanied by macOS's own `systemDefined subtype=7` (aux mouse-button state: data1 0x8 = button 3, 0x10 = button 4).
  - Still open: which *physical* button (Back or Forward) is 3 or 4. `calibrate` records that.
- **Resolved, 2026-11-21 16:41:** the user ran `calibrate` (new flow, ISSUE-011). It recorded **Previous Desktop = buttonNumber 4** (HID usage 0x5, 10 presses) and **Next Desktop = buttonNumber 3** (HID usage 0x4, 2 presses) on `M21-Mouse [Bluetooth Low Energy vid=0x32C2 pid=0x6621]`. The direction is the user's own choice, the reverse of the usual HID convention (button 4 = Back). If it feels wrong when used, `scripts/swap.sh` reverses it.

## ISSUE-007 — 2.4 GHz receiver mode not tested: `OPEN`

- **Status:** only Bluetooth LE was connected during development. The dongle may enumerate with a different VID/PID and possibly a different report descriptor.
- **Next step:** run H12. If the button numbers differ between connections, either re-calibrate when switching or add per-device mappings (the engine would need the source device, which means moving to an IOHIDManager-sourced trigger).

## ISSUE-008 — Possible interference from Logi Options+: `OPEN` (watch)

- **Status:** `logioptionsplus.app` is installed (for the paired MX Master 3S). Options+ normally only hooks Logitech devices, but it also installs an event tap.
- **Next step:** if side buttons behave inconsistently, quit Options+ and repeat H3/H4. Record the result here.

## ISSUE-009 — Listen-only event tap receives zero events without Input Monitoring: `RESOLVED`

- **Found:** 2026-11-21, first hardware diagnostic by the user (`logs/diagnostic-20261121-232651.log`).
- **Repro:** run `scripts/diagnose.sh 45` from Ghostty, which lacks Input Monitoring. Click left and right, press both side buttons.
- **Expected:** mouse events are logged.
- **Actual:** "CGEvent tap active (listen-only)", then **0 events**, including the left/right baseline clicks. No error is returned.
- **Root cause (probable):** on macOS 27, `CGEvent.tapCreate` succeeds without Input Monitoring, but the WindowServer delivers no events to the tap. The earlier assumption, that mouse-only listen taps need no permission, was wrong. It was never verified with real input; only the tap creation had been tested.
- **Resolution:**
  - `diagnose` and `calibrate` check `CGPreflightListenEventAccess()` at start, warn, and call `CGRequestListenEventAccess()`.
  - `diagnose` reports "NO input events were received ... permission problem, not the mouse" and exits with code 5.
  - `scripts/diagnose.sh` and `scripts/calibrate.sh` now launch through `open MouseController.app` (`run_as_app`), so TCC attributes the request to the signed app instead of the terminal. That avoids restarting Ghostty, and the grant survives rebuilds (ISSUE-004).
- **Verification:**
  - 2026-11-21: the `open` path started, showed the warning and permission request, and printed the zero-event error (5 s run).
  - 2026-11-21 16:31: the user granted Input Monitoring to MouseController. The next run showed `HID monitor active (mice)` and 26 events were received (`logs/diagnostic-*.log`). This confirms the root cause: same code, same terminal, and the only change was the grant.
  - Follow-up fix: a zero-event result is now reported according to whether the permission is granted. "Grant permission" appears only when it is missing; otherwise the message is "nothing was clicked / mouse not connected".
- **Prevention:** never conclude that a tap "works" because it was created. Assert that at least one baseline event arrives.

## ISSUE-010 — Calibrate timeout message blamed the device when only normal clicks arrived: `RESOLVED`

- **Found:** 2026-11-21 16:36, first `calibrate.sh` run by the user.
- **Repro:** start calibrate and, during step 1, click only the left button for 60 s.
- **Expected:** a message saying that only normal clicks were seen and the side buttons should be pressed.
- **Actual:** "If diagnose shows the side buttons only as keyDown/systemDefined/Consumer events, they are not mouse buttons…". That suggests a device problem, but the HID log showed 11 left clicks (usage 0x1) and the M21 working normally. Earlier runs had already confirmed the side buttons as buttonNumber 3/4.
- **Root cause:** the timeout handler did not use the HID evidence it was already collecting. The prompts were English only.
- **Resolution:** calibrate counts HID button presses per step, and the timeout message now distinguishes three cases:
  - only normal clicks: "press the side (thumb) buttons";
  - no input at all: check the connection or permission;
  - HID extra buttons but no CGEvent: another tap is consuming them (ISSUE-008).
- The prompts are now bilingual (English and Thai).
- **Verification:** builds cleanly and `tests/integration.sh` gives 14/14. The new message path still needs a hardware confirmation on the next calibrate run.

## ISSUE-011 — Interactive calibrate unusable from Claude Code `!` and reset by repeated presses: `RESOLVED`

- **Found:** 2026-11-21 16:37–16:39, second `calibrate.sh` run by the user (`logs/calibrate-*.log`).
- **Repro:** run `! scripts/calibrate.sh` inside Claude Code and press each side button several times in quick succession (~0.2 s apart).
- **Expected:** the config is written.
- **Actual:**
  - Over 100 side-button presses were captured, both buttonNumber 3 and 4, but the state machine kept restarting: "Mismatch: expected 4, got 3. Restarting."
  - It ended with the misleading message "HID saw extra buttons [5: 10] but no matching otherMouseDown CGEvent", even though CGEvents had been received.
  - No config was written.
- **Root cause:**
  1. Claude Code `!` commands show their output only after they finish. The user could not see the step prompts, so a step-by-step dialog is the wrong design for this environment.
  2. The confirm steps accepted the very next press. A burst of the FORWARD button was therefore read as "confirm BACK", a mismatch, and a full reset.
  3. The timeout branch introduced by ISSUE-010 tested "HID saw extra buttons" without checking whether CGEvents had arrived.
- **Resolution:** calibrate was rewritten as a **non-interactive, burst-tolerant** capture:
  - the first distinct side button pressed is Previous, the second is Next;
  - the run finishes as soon as each has been pressed at least twice;
  - bursts and repeats are harmless.
  - Timeout messages are now based on what was actually captured: one button only, both but too few presses, HID but no CGEvent, only clicks, or nothing.
  - New `swap` command and `scripts/swap.sh` fix a reversed direction without recalibrating. They back up the config and reload the running controller.
- **Verification:** `tests/integration.sh` gives 19/19, with new tests for a reversible swap, a backup on swap, and calibrate timing out with exit 3 and writing no config. Hardware confirmation of the new calibrate is still to come from the user's next run.
- **Prevention:** interactive CLI flows must not depend on live output being visible. Prefer "do X, then Y" captures that tolerate repetition.

## ISSUE-012 — A process that receives Accessibility while running cannot post keystrokes until it restarts: `RESOLVED`

- **Found:** 2026-11-21 16:42, first install.
- **Repro:** install while Accessibility is missing. The agent waits; then enable MouseController in System Settings > Privacy & Security > Accessibility (on macOS 27 this pane is titled "Device Control and…").
- **Expected:** the agent works fully.
- **Actual:** the event tap became active about 15 s later, but the log showed "Post-event access not reported as granted; keystrokes may be dropped". After a launchd restart (pid 41916 → 42293) the warning was gone.
- **Root cause:** `CGPreflightPostEventAccess` / post-event authorization is evaluated per process and not refreshed after a live grant, whereas creating the event tap is re-checked each time.
- **Resolution:** when `run` obtained the tap only after waiting for the permission and post-event access is still not reported, it logs the reason and exits with code 75. LaunchAgent `KeepAlive.SuccessfulExit=false` restarts it immediately, and the fresh process has full access.
- **Verification:** the restart observed in `tests/integration.sh --agent` (crash → restart) showed a clean start with no warning. The automatic exit-75 path runs only on a first-time grant; it is covered by code review, not by an automated test.

## ISSUE-013 — End-to-end Space switching by mouse not yet confirmed on hardware: `RESOLVED`

- **Status (2026-11-21):** the installed controller is running with Accessibility. The event tap is active, the config is verified, and `tests/integration.sh --agent` gives 26/26. However, `logs/controller.log` has no `button N -> Previous/Next Desktop` line yet, so no real side-button press has gone through the installed controller.
- **Next step:** run manual tests H3–H7 in `tests/MANUAL_TESTS.md`: previous and next switching, no double trigger, the browser does not navigate Back, and normal clicks are unaffected.
- **Close when:** H3–H7 pass and the log shows one `->` line per press.
- **Resolved, 2026-11-21 16:44–16:45 (Bluetooth LE):** the user tested and reported that everything works. `logs/controller.log` shows 24 actions from pid 42513: 14 × `button 3 -> Next Desktop` and 10 × `button 4 -> Previous Desktop`. There were no `FAILED` lines and no tap re-enables. The shortest gap between actions was about 0.31 s, consistent with the 300 ms debounce. H3–H7 passed according to the user's report.

## ISSUE-014 — Feature: double-click gestures (3 = Mission Control, 4 = App Exposé): `OPEN` (implemented, awaiting hardware test)

- **Requested:** 2026-11-22 by the user. GitHub #14.
- **Before:** a second press within `debounceMs` (300 ms) was swallowed, so a double-click acted as one single click.
- **Design (option A, wait-and-see; recommended and applied, since the user did not pick between A and B):**
  - `Mapping.gesture` is `single` (the default) or `double`, and `doubleClickMs` defaults to 250.
  - When a button has a double mapping, the engine returns `.schedule(token, after)` instead of firing. A second press within the window fires the double action and cancels the single action; otherwise `timerFired(token)` returns the single action.
  - A third press inside the window is swallowed.
  - Buttons without a double mapping keep firing instantly, with debounce.
  - `calibrate` preserves double mappings.
- **Bug found during implementation:** a fast triple press would have started a new cycle and switched Desktop after Mission Control. Guarded, and covered by `testTriplePressDoesNotSwitchDesktopAfterDouble`.
- **Test bug found:** `testDoubleOnlyButtonSinglePressDoesNothing` first fired the timer and then sent a "second press" earlier in virtual time, an impossible ordering. The engine was right; the test timeline was fixed.
- **Verification:**
  - `swift test` gives 35/35 (14 new tests for double-click and config).
  - Installed v1.1.0. The log shows `buttonNumber 3 double -> Mission Control` and `buttonNumber 4 double -> App Expose` loaded and the tap active.
  - Hardware tests H13–H15 are pending.

## ISSUE-015 — Scripts matched JSON with a fixed whitespace format: `RESOLVED`

- **Found:** 2026-11-22, `tests/integration.sh` after the config files were rewritten by a JSON tool that writes `"key": value` instead of Swift's `"key" : value`.
- **Repro:** edit `config/config.json` with any editor or tool that writes `"verified": true`, then run `scripts/calibrate.sh`.
- **Expected:** "OK: … written".
- **Actual:** "Config not written". In tests, `sed 's/"button" : 3/…/'` stopped matching, so "mapping left click rejected" failed (exit 0, wanted 1).
- **Root cause:** the shell scripts parsed JSON assuming the exact whitespace produced by `JSONEncoder.prettyPrinted`.
- **Resolution:** all greps and seds now use `"key" *: *value` (`grep -E`, `sed -E`). `install.sh` was already tolerant.
- **Verification:** `tests/integration.sh --agent` gives 26/26.
- **Prevention:** never match JSON with literal whitespace in shell. Prefer the binary's `validate` command, or tolerant regexes.
