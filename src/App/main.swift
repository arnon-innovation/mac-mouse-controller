import Foundation
import AppKit
import CoreGraphics
import MouseControllerCore

let version = "1.0.0"

// MARK: - Argument parsing

struct Args {
    var command: String
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var positional: [String] = []

    init(_ argv: [String]) {
        command = argv.dropFirst().first ?? "help"
        var it = argv.dropFirst(2).makeIterator()
        while let a = it.next() {
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if ["config", "log", "vid", "pid", "timeout", "key", "mods"].contains(key), let v = it.next() {
                    options[key] = v
                } else {
                    flags.insert(key)
                }
            } else {
                positional.append(a)
            }
        }
    }

    var configPath: String {
        if let p = options["config"] { return (p as NSString).expandingTildeInPath }
        if let p = ProcessInfo.processInfo.environment["MOUSE_CONTROLLER_CONFIG"] { return (p as NSString).expandingTildeInPath }
        return ("~/mac-mouse-controller/config/config.json" as NSString).expandingTildeInPath
    }

    func int(_ key: String) -> Int? {
        guard let s = options[key] else { return nil }
        return s.hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : Int(s)
    }
}

let args = Args(CommandLine.arguments)
if let logPath = args.options["log"] { Log.openFile((logPath as NSString).expandingTildeInPath) }

func eventName(_ t: CGEventType) -> String {
    switch t {
    case .leftMouseDown: return "leftMouseDown"
    case .leftMouseUp: return "leftMouseUp"
    case .rightMouseDown: return "rightMouseDown"
    case .rightMouseUp: return "rightMouseUp"
    case .otherMouseDown: return "otherMouseDown"
    case .otherMouseUp: return "otherMouseUp"
    case .otherMouseDragged: return "otherMouseDragged"
    case .keyDown: return "keyDown"
    case .keyUp: return "keyUp"
    case .flagsChanged: return "flagsChanged"
    case .scrollWheel: return "scrollWheel"
    default: return t.rawValue == 14 ? "systemDefined" : "type\(t.rawValue)"
    }
}

func installSignalHandler(_ sig: Int32, _ body: @escaping () -> Void) -> DispatchSourceSignal {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler(handler: body)
    src.resume()
    return src
}

// MARK: - diagnose

/// Listen-only: never modifies or blocks any event.
func runDiagnose() -> Int32 {
    let verbose = args.flags.contains("verbose")
    Log.say("""
    === GOOJODOQ M21 diagnostic mode (listen-only, nothing is remapped) ===
    1. Click LEFT once, RIGHT once (baseline).
    2. Press the BACK side button (closer to your wrist) 3 times, slowly.
    3. Press the FORWARD side button (closer to the front) 3 times, slowly.
    4. Optionally press the middle/wheel button and the DPI button.
    Every event is logged with its CGEvent button number and the raw HID usage.
    Press Ctrl+C to stop.
    """)
    Log.info("mouse-controller \(version) diagnose; macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    Log.info(Permissions.report().replacingOccurrences(of: "\n", with: " | "))

    if !CGPreflightListenEventAccess() {
        Log.warn("Input Monitoring is NOT granted to the responsible app. On macOS 27 the event tap is then created but receives NO events (ISSUE-009). Requesting permission now; grant it, then re-run.")
        Permissions.request(accessibility: false, inputMonitoring: true)
    }
    var eventCount = 0
    func summary() {
        if eventCount == 0 {
            if CGPreflightListenEventAccess() {
                Log.warn("No input events were received. Input Monitoring IS granted, so either nothing was clicked during the session, or the mouse is not sending to this Mac (check the connection).")
            } else {
                Log.error("NO input events were received (not even left/right clicks). This is a permission problem, not the mouse: grant Input Monitoring (System Settings > Privacy & Security > Input Monitoring) to the app that ran this, then run again.")
            }
        } else {
            Log.info("received \(eventCount) input event(s)")
        }
    }

    var types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                .otherMouseDown, .otherMouseUp, .keyDown, .keyUp,
                                CGEventType(rawValue: 14)!]
    if verbose { types.append(.scrollWheel) }

    let tap = EventTap { type, event in
        eventCount += 1
        let name = eventName(type)
        var line = "CGEVENT \(name)"
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            let btn = event.getIntegerValueField(.mouseEventButtonNumber)
            let clicks = event.getIntegerValueField(.mouseEventClickState)
            let sub = event.getIntegerValueField(.mouseEventSubtype)
            line += " buttonNumber=\(btn) (HID button \(btn + 1)) clickState=\(clicks) subtype=\(sub)"
        case .keyDown, .keyUp:
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            let rep = event.getIntegerValueField(.keyboardEventAutorepeat)
            line += String(format: " keycode=%lld autorepeat=%lld flags=0x%llX", kc, rep, event.flags.rawValue)
        case .scrollWheel:
            line += " dy=\(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) dx=\(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))"
        default:
            if let ns = NSEvent(cgEvent: event) {
                line += String(format: " subtype=%d data1=0x%lX data2=0x%lX", ns.subtype.rawValue, ns.data1, ns.data2)
            }
        }
        let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
        let synthetic = event.getIntegerValueField(.eventSourceUserData) == syntheticMarker
        line += " sourcePID=\(pid)\(synthetic ? " SYNTHETIC(mouse-controller)" : "")"
        Log.info(line)
        return Unmanaged.passUnretained(event)
    }
    if !tap.start(mask: EventTap.mask(types), listenOnly: true) {
        Log.error("Could not create the event tap. Grant Input Monitoring to your terminal app (System Settings > Privacy & Security > Input Monitoring), then quit and reopen the terminal.")
        Permissions.request(accessibility: false, inputMonitoring: true)
        return 2
    }
    Log.info("CGEvent tap active (listen-only).")

    let hid = HIDMonitor(verbose: verbose)
    let rc = hid.start(vendorID: args.int("vid"), productID: args.int("pid"))
    if rc == kIOReturnSuccess {
        Log.info("HID monitor active (mice\(args.int("vid").map { String(format: ", vid=0x%04X", $0) } ?? "")).")
    } else {
        Log.warn(String(format: "HID monitor unavailable (IOHIDManagerOpen=0x%08X). Raw HID layer needs Input Monitoring (so does the CGEvent layer on macOS 27, ISSUE-009).", rc))
    }

    let sigint = installSignalHandler(SIGINT) { Log.info("diagnose stopped"); summary(); exit(0) }
    let sigterm = installSignalHandler(SIGTERM) { summary(); exit(0) }
    if let t = args.int("timeout") {
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(t)) { Log.info("diagnose timeout reached"); summary(); exit(eventCount == 0 ? 5 : 0) }
    }
    withExtendedLifetime((tap, hid, sigint, sigterm)) { CFRunLoopRun() }
    return 0
}

// MARK: - calibrate

/// Writes `config` to `path` atomically, backing up any existing file first.
func writeConfig(_ config: ControllerConfig, to path: String) -> Bool {
    let problems = ConfigLoader.validate(config)
    guard problems.isEmpty else { Log.error("Refusing to write invalid config: \(problems)"); return false }
    let fm = FileManager.default
    if fm.fileExists(atPath: path) {
        let backup = path + ".bak-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        try? fm.copyItem(atPath: path, toPath: backup)
        Log.info("Backed up existing config to \(backup)")
    }
    do {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try ConfigLoader.encode(config).write(to: URL(fileURLWithPath: path), options: .atomic)
        return true
    } catch {
        Log.error("Could not write \(path): \(error)"); return false
    }
}

/// Non-interactive calibration (works even when the prompts are not visible live, e.g. Claude Code `!`):
/// the FIRST side button pressed becomes "Previous Desktop", the SECOND distinct one "Next Desktop".
/// Repeated presses / bursts are fine. Done as soon as both buttons were pressed >= 2 times.
func runCalibrate() -> Int32 {
    let path = args.configPath
    let timeoutS = args.int("timeout") ?? 60
    var order: [Int] = []            // distinct side buttons in first-press order
    var counts: [Int: Int] = [:]     // CGEvent presses per side button
    var hidUsages: [Int: Int] = [:]  // HID button usage -> presses (evidence / error messages)
    var lastHIDDevice = "unknown device"

    if !CGPreflightListenEventAccess() {
        Log.warn("Input Monitoring not granted to the responsible app: button presses will NOT be seen (ISSUE-009). Requesting it now.")
        Permissions.request(accessibility: false, inputMonitoring: true)
    }

    func finish() {
        let prevBtn = order[0], nextBtn = order[1]
        var config = (try? ConfigLoader.load(path: path)) ?? ControllerConfig(mappings: [])
        func action(_ name: String, default d: KeyAction) -> KeyAction {
            config.mappings.first { $0.name == name }?.action ?? d
        }
        let prev = action("Previous Desktop", default: KeyAction(key: "leftArrow", modifiers: ["control"]))
        let next = action("Next Desktop", default: KeyAction(key: "rightArrow", modifiers: ["control"]))
        config.mappings = [
            Mapping(name: "Previous Desktop", button: prevBtn, action: prev),
            Mapping(name: "Next Desktop", button: nextBtn, action: next),
        ]
        config.verified = true
        config.verificationNote = "calibrated \(ISO8601DateFormatter().string(from: Date())) on \(lastHIDDevice): previous=buttonNumber \(prevBtn) (\(counts[prevBtn]!)x), next=buttonNumber \(nextBtn) (\(counts[nextBtn]!)x)"
        guard writeConfig(config, to: path) else { exit(4) }
        Log.say("\nVerified: PREVIOUS = buttonNumber \(prevBtn), NEXT = buttonNumber \(nextBtn) (\(lastHIDDevice)).")
        Log.say("Wrote \(path). Wrong direction? run: scripts/swap.sh")
        exit(0)
    }

    let tap = EventTap { type, event in
        guard type == .otherMouseDown else { return Unmanaged.passUnretained(event) }
        let btn = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        guard btn >= 2 else { return Unmanaged.passUnretained(event) }
        DispatchQueue.main.async {
            if counts[btn] == nil { order.append(btn) }
            counts[btn, default: 0] += 1
            Log.info("captured otherMouseDown buttonNumber=\(btn) (press #\(counts[btn]!))")
            if order.count > 2 {
                Log.warn("more than two extra buttons pressed (\(order)); using the first two")
            }
            if order.count >= 2, counts[order[0]]! >= 2, counts[order[1]]! >= 2 { finish() }
        }
        return Unmanaged.passUnretained(event)
    }
    if !tap.start(mask: EventTap.mask([.otherMouseDown]), listenOnly: true) {
        Log.error("Could not create the event tap (permission). Run: mouse-controller check-permissions")
        return 2
    }
    let hid = HIDMonitor(verbose: false)
    hid.onValue = { dev, page, usage, value in
        if page == kHIDPage_Button && value == 1 {
            lastHIDDevice = dev
            hidUsages[usage, default: 0] += 1
        }
    }
    _ = hid.start(vendorID: nil, productID: nil)

    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeoutS)) {
        let clicks = hidUsages.filter { $0.key <= 3 }.values.reduce(0, +)
        let hidExtra = hidUsages.filter { $0.key > 3 }
        if order.count == 1 {
            Log.error("Only ONE side button was pressed (buttonNumber \(order[0]), \(counts[order[0]]!)x). Press BOTH side buttons, 2-3 times each. พบปุ่มข้างแค่ปุ่มเดียว ให้กดทั้งสองปุ่ม ปุ่มละ 2-3 ครั้ง")
        } else if order.count >= 2 {
            Log.error("Both side buttons seen (\(counts)) but not each >= 2 times. Press each 2-3 times. ให้กดแต่ละปุ่ม 2-3 ครั้ง")
        } else if !hidExtra.isEmpty {
            Log.error("HID saw side buttons \(hidExtra) but the event tap saw none: something (e.g. Logi Options+, ISSUE-008) may be consuming them.")
        } else if clicks > 0 {
            Log.error("Only normal clicks (\(clicks)) were seen, no side button. Press the thumb side buttons. พบแต่คลิกปกติ ให้กดปุ่มด้านข้าง (นิ้วโป้ง)")
        } else {
            Log.error("No mouse input at all within \(timeoutS)s. Check the mouse connection and Input Monitoring for MouseController.")
        }
        exit(3)
    }

    Log.say("""
    Calibration (listen-only, \(timeoutS)s). Normal clicks are ignored.
      1. Press the side button for PREVIOUS desktop 2-3 times.
      2. Then press the other side button (NEXT desktop) 2-3 times.
      กดปุ่มข้างที่จะใช้ไป Desktop ก่อนหน้า 2-3 ครั้ง แล้วกดอีกปุ่มที่จะใช้ไป Desktop ถัดไป 2-3 ครั้ง
    """)
    let sigint = installSignalHandler(SIGINT) { Log.say("\ncalibration cancelled; config unchanged"); exit(130) }
    withExtendedLifetime((tap, hid, sigint)) { CFRunLoopRun() }
    return 0
}

/// Swap the buttons of "Previous Desktop" and "Next Desktop" (wrong direction after calibrate).
func runSwap() -> Int32 {
    let path = args.configPath
    guard var config = try? ConfigLoader.load(path: path),
          let i = config.mappings.firstIndex(where: { $0.name == "Previous Desktop" }),
          let j = config.mappings.firstIndex(where: { $0.name == "Next Desktop" }) else {
        Log.error("\(path) must contain 'Previous Desktop' and 'Next Desktop' mappings")
        return 1
    }
    let tmp = config.mappings[i].button
    config.mappings[i].button = config.mappings[j].button
    config.mappings[j].button = tmp
    config.verificationNote = (config.verificationNote ?? "") + "; swapped \(ISO8601DateFormatter().string(from: Date()))"
    guard writeConfig(config, to: path) else { return 4 }
    print("Previous Desktop = buttonNumber \(config.mappings[i].button), Next Desktop = buttonNumber \(config.mappings[j].button)")
    return 0
}

// MARK: - run

func runController() -> Int32 {
    let path = args.configPath
    let config: ControllerConfig
    do { config = try ConfigLoader.load(path: path) } catch {
        Log.error("\(error)\nCreate one with: mouse-controller calibrate --config \(path)")
        return 1
    }
    if !config.verified && !args.flags.contains("allow-unverified") {
        Log.error("Config \(path) has \"verified\": false. Button numbers must be confirmed on the real mouse first: run `mouse-controller calibrate`. (Override: --allow-unverified)")
        return 1
    }
    let engine = Engine(config: config)
    Log.info("mouse-controller \(version) starting; config=\(path) enabled=\(config.enabled) debounceMs=\(config.debounceMs) suppressOriginal=\(config.suppressOriginalEvent)")
    for m in config.mappings {
        Log.info("  mapping: buttonNumber \(m.button) -> \(m.name) (\(m.action.modifiers.joined(separator: "+"))+\(m.action.key))")
    }

    // Only extra-button events are tapped. Left/right clicks, movement and scrolling are
    // never delivered to this process, so they cannot be delayed or altered.
    let mask = EventTap.mask([.otherMouseDown, .otherMouseUp, .otherMouseDragged])
    let tap = EventTap { type, event in
        let btn = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        let phase: ButtonPhase = type == .otherMouseDown ? .down : (type == .otherMouseUp ? .up : .dragged)
        switch engine.handle(button: btn, phase: phase, now: monotonicNow()) {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .suppress:
            return nil
        case .fire(let mapping, let suppressOriginal):
            // Post after returning from the callback: keeps the tap fast (macOS disables slow taps).
            DispatchQueue.main.async {
                let ok = KeySender.send(keyCode: KeyTable.keyCode(for: mapping.action.key)!,
                                        flags: KeyTable.flags(for: mapping.action))
                Log.info("button \(btn) -> \(mapping.name)\(ok ? "" : " FAILED to create key event")")
            }
            return suppressOriginal ? nil : Unmanaged.passUnretained(event)
        }
    }

    // Under launchd the permission may not be granted yet: wait instead of crash-looping.
    var prompted = false
    while !tap.start(mask: mask, listenOnly: false) {
        if !prompted {
            Log.error("Cannot create event tap: Accessibility permission missing for this binary. Waiting... (System Settings > Privacy & Security > Accessibility)")
            Permissions.request(accessibility: true, inputMonitoring: false)
            prompted = true
        }
        Thread.sleep(forTimeInterval: 5)
    }
    if !CGPreflightPostEventAccess() {
        if prompted {
            // Permission was granted while this process was waiting: the tap works, but macOS keeps
            // reporting post-event access as missing for this process, so keystrokes could be dropped
            // (ISSUE-012). Exit non-zero; launchd (KeepAlive SuccessfulExit=false) starts a fresh process.
            Log.warn("Accessibility granted while running; restarting so synthetic keystrokes are allowed (ISSUE-012).")
            tap.stop()
            exit(75)
        }
        Log.warn("Post-event access not reported as granted; keystrokes may be dropped. Check Accessibility.")
    }
    Log.info("event tap active. SIGHUP = reload config, SIGUSR1 = toggle enabled, SIGTERM = quit.")

    let hup = installSignalHandler(SIGHUP) {
        do {
            let fresh = try ConfigLoader.load(path: path)
            if !fresh.verified && !args.flags.contains("allow-unverified") {
                Log.error("reload rejected: new config is not verified; keeping previous config")
                return
            }
            engine.reload(fresh)
            Log.info("config reloaded: enabled=\(fresh.enabled) mappings=\(fresh.mappings.map { "\($0.button)->\($0.name)" })")
        } catch {
            Log.error("reload failed, keeping previous config: \(error)")
        }
    }
    let usr1 = installSignalHandler(SIGUSR1) {
        var c = engine.config
        c.enabled.toggle()
        engine.reload(c)
        Log.info("controller \(c.enabled ? "ENABLED" : "DISABLED") (runtime toggle; config file unchanged)")
    }
    let term = installSignalHandler(SIGTERM) { tap.stop(); Log.info("stopping (SIGTERM)"); exit(0) }
    let int = installSignalHandler(SIGINT) { tap.stop(); Log.info("stopping (SIGINT)"); exit(0) }
    withExtendedLifetime((tap, hup, usr1, term, int)) { CFRunLoopRun() }
    return 0
}

// MARK: - send / current-space / check-permissions

func runSend() -> Int32 {
    let action: KeyAction
    if let key = args.options["key"] {
        action = KeyAction(key: key, modifiers: (args.options["mods"] ?? "").split(separator: ",").map(String.init))
    } else if let which = args.positional.first {
        let defaults = ["previous": KeyAction(key: "leftArrow", modifiers: ["control"]),
                        "next": KeyAction(key: "rightArrow", modifiers: ["control"])]
        let fromConfig = (try? ConfigLoader.load(path: args.configPath))?.mappings
            .first { $0.name.lowercased().hasPrefix(which.lowercased()) }?.action
        guard let a = fromConfig ?? defaults[which.lowercased()] else {
            Log.error("usage: mouse-controller send previous|next | --key leftArrow --mods control"); return 1
        }
        action = a
    } else {
        Log.error("usage: mouse-controller send previous|next | --key leftArrow --mods control"); return 1
    }
    guard let code = KeyTable.keyCode(for: action.key) else { Log.error("unknown key \(action.key)"); return 1 }
    if !CGPreflightPostEventAccess() {
        Log.warn("Post-event access missing for the responsible app; macOS will silently drop the keystroke.")
    }
    let before = SpaceProbe.activeSpaceID()
    _ = KeySender.send(keyCode: code, flags: KeyTable.flags(for: action))
    Thread.sleep(forTimeInterval: 1.0) // Spaces animation
    let after = SpaceProbe.activeSpaceID()
    print("sent \(action.modifiers.joined(separator: "+"))+\(action.key) flags=0x\(String(KeyTable.flags(for: action), radix: 16)) space: \(before.map(String.init) ?? "?") -> \(after.map(String.init) ?? "?")")
    return 0
}

func usage() -> String {
    """
    mouse-controller \(version) — side buttons -> macOS Spaces

    Commands:
      diagnose [--verbose] [--vid 0x32C2 --pid 0x6621] [--log FILE] [--timeout S]
                          Listen-only logging of every mouse button / key / HID value.
      calibrate [--config FILE] [--timeout S]
                          Press the PREVIOUS side button 2-3x, then the NEXT one 2-3x; writes a verified config.
      swap [--config FILE]  Swap the Previous/Next buttons (wrong direction).
      run [--config FILE] [--log FILE] [--allow-unverified]
                          Start the controller (needs Accessibility).
      send previous|next | --key KEY --mods control,shift
                          Post the configured keystroke once (tests Spaces switching).
      current-space       Print the active Space ID (diagnostic).
      check-permissions [--prompt]
      validate [--config FILE]
      version
    Config default: ~/mac-mouse-controller/config/config.json (or $MOUSE_CONTROLLER_CONFIG)
    """
}

let code: Int32
switch args.command {
case "diagnose": code = runDiagnose()
case "calibrate": code = runCalibrate()
case "swap": code = runSwap()
case "run": code = runController()
case "send": code = runSend()
case "current-space":
    if let id = SpaceProbe.activeSpaceID() { print(id); code = 0 } else { print("unavailable"); code = 1 }
case "check-permissions":
    print(Permissions.report())
    if args.flags.contains("prompt") { Permissions.request(accessibility: true, inputMonitoring: true) }
    code = 0
case "validate":
    do {
        let c = try ConfigLoader.load(path: args.configPath)
        print("OK: \(c.mappings.count) mapping(s), verified=\(c.verified), enabled=\(c.enabled)")
        code = 0
    } catch { print(error); code = 1 }
case "version", "--version": print(version); code = 0
default: print(usage()); code = args.command == "help" || args.command == "--help" ? 0 : 1
}
exit(code)
