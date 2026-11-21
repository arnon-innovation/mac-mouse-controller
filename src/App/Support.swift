import Foundation
import CoreGraphics
import ApplicationServices
import IOKit.hid

// MARK: - Logging

enum Log {
    nonisolated(unsafe) static var fileHandle: FileHandle?
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Echo to stderr only when interactive (or no file): avoids duplicate lines under launchd.
    nonisolated(unsafe) static var echoToStderr = true
    static let maxLogBytes: UInt64 = 5 * 1024 * 1024

    static func openFile(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Simple rotation: keep one previous generation.
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? UInt64, size > maxLogBytes {
            try? fm.removeItem(atPath: path + ".1")
            try? fm.moveItem(atPath: path, toPath: path + ".1")
        }
        echoToStderr = isatty(STDERR_FILENO) != 0
        if !fm.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        fileHandle = FileHandle(forWritingAtPath: path)
        fileHandle?.seekToEndOfFile()
    }

    static func info(_ msg: String) { write("INFO ", msg) }
    static func warn(_ msg: String) { write("WARN ", msg) }
    static func error(_ msg: String) { write("ERROR", msg) }

    private static func write(_ level: String, _ msg: String) {
        let line = "\(formatter.string(from: Date())) \(level) \(msg)\n"
        if echoToStderr || fileHandle == nil { FileHandle.standardError.write(line.data(using: .utf8)!) }
        fileHandle?.write(line.data(using: .utf8)!)
    }

    /// Plain user-facing text (prompts), not timestamped.
    static func say(_ msg: String) {
        print(msg)
        fflush(stdout)
        let prefixed = msg.split(separator: "\n", omittingEmptySubsequences: false).map { "# " + $0 }.joined(separator: "\n")
        fileHandle?.write((prefixed + "\n").data(using: .utf8)!)
    }
}

// MARK: - Time

func monotonicNow() -> TimeInterval {
    TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
}

// MARK: - Permissions

enum Permissions {
    struct Status {
        let accessibility: Bool
        let inputMonitoring: Bool
        let postEvents: Bool
    }

    static func current() -> Status {
        Status(accessibility: AXIsProcessTrusted(),
               inputMonitoring: CGPreflightListenEventAccess(),
               postEvents: CGPreflightPostEventAccess())
    }

    /// Triggers the system prompts (once per binary identity). Non-blocking.
    static func request(accessibility: Bool, inputMonitoring: Bool) {
        if accessibility {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        if inputMonitoring { _ = CGRequestListenEventAccess() }
    }

    static func report() -> String {
        let s = current()
        func m(_ b: Bool) -> String { b ? "GRANTED" : "missing" }
        return """
        Accessibility (needed by `run` and `send`): \(m(s.accessibility))
        Post events (needed by `run` and `send`):   \(m(s.postEvents))
        Input Monitoring (needed by `diagnose`/`calibrate`): \(m(s.inputMonitoring))
        Binary: \(CommandLine.arguments[0])
        Permissions are granted to the *responsible app*: the terminal (e.g. Ghostty) when run
        by hand, MouseController.app when started via `open` or the LaunchAgent.
        """
    }
}

// MARK: - Event tap wrapper

/// Owns a CGEventTap on the current run loop. Re-enables itself if macOS disables it
/// (tapDisabledByTimeout / tapDisabledByUserInput) so the controller survives hiccups.
final class EventTap {
    typealias Handler = (CGEventType, CGEvent) -> Unmanaged<CGEvent>?
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private let handler: Handler
    private(set) var reenableCount = 0

    init(handler: @escaping Handler) { self.handler = handler }

    static func mask(_ types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }

    /// Returns false if the tap could not be created (permission missing).
    func start(mask: CGEventMask, listenOnly: Bool) -> Bool {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: listenOnly ? .listenOnly : .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let me = Unmanaged<EventTap>.fromOpaque(refcon!).takeUnretainedValue()
                return me.dispatch(type, event)
            },
            userInfo: refcon
        ) else { return false }
        self.port = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        port = nil
        source = nil
    }

    private func dispatch(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenableCount += 1
            Log.warn("event tap disabled by macOS (\(type == .tapDisabledByTimeout ? "timeout" : "user input")); re-enabling (#\(reenableCount))")
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        return handler(type, event)
    }
}

// MARK: - Synthetic keystrokes

/// Marker written into eventSourceUserData of every event we post, so our own
/// events are recognizable in logs and can never be re-processed.
let syntheticMarker: Int64 = 0x4D32_314D_4F55 // "M21MOU"

enum KeySender {
    static func send(keyCode: UInt16, flags: UInt64) -> Bool {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        for e in [down, up] {
            e.flags = CGEventFlags(rawValue: flags)
            e.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

// MARK: - Spaces introspection (diagnostic only)

/// Reads the active Space ID through the private SkyLight `CGSGetActiveSpace`.
/// Used ONLY by `current-space` / tests to verify that a switch happened; the
/// controller itself relies solely on public APIs + the user's keyboard shortcut.
enum SpaceProbe {
    private typealias ConnFn = @convention(c) () -> Int32
    private typealias SpaceFn = @convention(c) (Int32) -> UInt64

    static func activeSpaceID() -> UInt64? {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let c = dlsym(h, "CGSMainConnectionID"),
              let s = dlsym(h, "CGSGetActiveSpace") else { return nil }
        let conn = unsafeBitCast(c, to: ConnFn.self)()
        return unsafeBitCast(s, to: SpaceFn.self)(conn)
    }
}

// MARK: - HID monitor (diagnostic only)

/// Logs raw HID button / consumer-control values per device. This is the ground truth
/// for "which device sent what", below the CGEvent layer.
final class HIDMonitor {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    var onValue: ((String, Int, Int, Int) -> Void)?
    let verbose: Bool

    init(verbose: Bool) { self.verbose = verbose }

    static func describe(_ device: IOHIDDevice) -> String {
        func prop(_ k: String) -> Any? { IOHIDDeviceGetProperty(device, k as CFString) }
        let name = prop(kIOHIDProductKey) as? String ?? "?"
        let transport = prop(kIOHIDTransportKey) as? String ?? "?"
        let vid = prop(kIOHIDVendorIDKey) as? Int ?? 0
        let pid = prop(kIOHIDProductIDKey) as? Int ?? 0
        return String(format: "%@ [%@ vid=0x%04X pid=0x%04X]", name, transport, vid, pid)
    }

    /// Returns the IOReturn of IOHIDManagerOpen (kIOReturnSuccess = 0).
    func start(vendorID: Int?, productID: Int?) -> IOReturn {
        var match: [String: Any] = [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                                    kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse]
        if let vendorID { match[kIOHIDVendorIDKey] = vendorID }
        if let productID { match[kIOHIDProductIDKey] = productID }
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            Log.info("HID device attached: \(HIDMonitor.describe(device))")
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            Log.info("HID device removed: \(HIDMonitor.describe(device))")
        }, ctx)
        IOHIDManagerRegisterInputValueCallback(manager, { ctx, _, _, value in
            let me = Unmanaged<HIDMonitor>.fromOpaque(ctx!).takeUnretainedValue()
            me.handle(value)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        return IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let v = IOHIDValueGetIntegerValue(value)
        let device = IOHIDElementGetDevice(element)
        // Motion / wheel / pan are noise for button detection.
        let isMotion = page == kHIDPage_GenericDesktop || (page == kHIDPage_Consumer && usage == 0x238)
        if isMotion && !verbose { return }
        // Consumer arrays report usage 0 / value 0 on release-of-all; keep them, they matter.
        let pageName: String
        switch page {
        case kHIDPage_Button: pageName = "Button"
        case kHIDPage_Consumer: pageName = "Consumer"
        case kHIDPage_GenericDesktop: pageName = "GenericDesktop"
        default: pageName = String(format: "0x%02X", page)
        }
        Log.info(String(format: "HID   %@ page=%@ usage=0x%X value=%ld", HIDMonitor.describe(device), pageName, usage, v))
        onValue?(HIDMonitor.describe(device), page, usage, v)
    }
}
