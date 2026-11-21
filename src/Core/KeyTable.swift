import Foundation

/// Virtual key codes (HIToolbox/Events.h, kVK_*) and CGEventFlags raw values.
/// Kept here as plain integers so Core stays free of CoreGraphics and is unit-testable.
public enum KeyTable {
    private static let keys: [String: UInt16] = [
        "leftArrow": 0x7B, "rightArrow": 0x7C, "downArrow": 0x7D, "upArrow": 0x7E,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17,
        "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19, "0": 0x1D,
        "leftBracket": 0x21, "rightBracket": 0x1E,
        "tab": 0x30, "space": 0x31, "escape": 0x35, "return": 0x24,
        "f3": 0x63, "f4": 0x76,
    ]

    // CGEventFlags raw values.
    public static let flagShift: UInt64 = 0x0002_0000
    public static let flagControl: UInt64 = 0x0004_0000
    public static let flagOption: UInt64 = 0x0008_0000
    public static let flagCommand: UInt64 = 0x0010_0000
    public static let flagNumericPad: UInt64 = 0x0020_0000
    public static let flagSecondaryFn: UInt64 = 0x0080_0000

    private static let modifiers: [String: UInt64] = [
        "shift": flagShift, "control": flagControl, "option": flagOption, "command": flagCommand,
    ]

    /// Keys that a real keyboard reports with the Fn + NumericPad flags set.
    /// The WindowServer symbolic-hotkey matcher (Spaces switching) compares these flags,
    /// so a synthesized Ctrl+Arrow WITHOUT them is silently ignored. See docs/ISSUES.md.
    private static let arrowKeys: Set<String> = ["leftArrow", "rightArrow", "downArrow", "upArrow"]
    private static let fnKeys: Set<String> = ["f3", "f4"]

    public static var knownKeys: [String] { keys.keys.sorted() }
    public static var knownModifiers: [String] { modifiers.keys.sorted() }

    public static func keyCode(for name: String) -> UInt16? { keys[name] }
    public static func modifierFlag(for name: String) -> UInt64? { modifiers[name.lowercased()] }

    /// Full flag set to put on the synthesized key events.
    public static func flags(for action: KeyAction) -> UInt64 {
        var f: UInt64 = 0
        for m in action.modifiers { f |= modifierFlag(for: m) ?? 0 }
        if arrowKeys.contains(action.key) { f |= flagSecondaryFn | flagNumericPad }
        if fnKeys.contains(action.key) { f |= flagSecondaryFn }
        return f
    }
}
