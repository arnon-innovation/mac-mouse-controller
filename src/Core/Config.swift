import Foundation

/// A keystroke to synthesize, e.g. Control + Left Arrow.
public struct KeyAction: Codable, Equatable, Sendable {
    public var key: String
    public var modifiers: [String]

    public init(key: String, modifiers: [String]) {
        self.key = key
        self.modifiers = modifiers
    }
}

public enum Gesture: String, Codable, Sendable {
    case single, double
}

/// Maps one physical mouse button (CGEvent buttonNumber, 0-based) + gesture to an action.
public struct Mapping: Codable, Equatable, Sendable {
    public var name: String
    /// CGEvent `mouseEventButtonNumber`. 0 = left, 1 = right, 2 = middle, 3+ = extra buttons.
    public var button: Int
    /// `single` (default) or `double` (two presses within `doubleClickMs`).
    public var gesture: Gesture
    public var action: KeyAction

    public init(name: String, button: Int, gesture: Gesture = .single, action: KeyAction) {
        self.name = name
        self.button = button
        self.gesture = gesture
        self.action = action
    }

    enum CodingKeys: String, CodingKey { case name, button, gesture, action }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        button = try c.decode(Int.self, forKey: .button)
        gesture = try c.decodeIfPresent(Gesture.self, forKey: .gesture) ?? .single
        action = try c.decode(KeyAction.self, forKey: .action)
    }
}

public struct ControllerConfig: Codable, Equatable, Sendable {
    /// Master switch. false = every event passes through untouched.
    public var enabled: Bool
    /// When true, the mapped button's own down/up events are swallowed
    /// (prevents e.g. a browser also navigating Back).
    public var suppressOriginalEvent: Bool
    /// Minimum time between two triggers of the same mapping (buttons without a double mapping).
    public var debounceMs: Int
    /// Max gap between two presses to count as a double-click. Only buttons that have a
    /// `double` mapping wait this long before running their single action.
    public var doubleClickMs: Int
    /// Set to true only after the button numbers were confirmed on real hardware
    /// (written by `mouse-controller calibrate`). `run` refuses unverified configs.
    public var verified: Bool
    /// Free-text record of how/when the mapping was verified.
    public var verificationNote: String?
    public var mappings: [Mapping]

    public init(enabled: Bool = true,
                suppressOriginalEvent: Bool = true,
                debounceMs: Int = 300,
                doubleClickMs: Int = 250,
                verified: Bool = false,
                verificationNote: String? = nil,
                mappings: [Mapping]) {
        self.enabled = enabled
        self.suppressOriginalEvent = suppressOriginalEvent
        self.debounceMs = debounceMs
        self.doubleClickMs = doubleClickMs
        self.verified = verified
        self.verificationNote = verificationNote
        self.mappings = mappings
    }

    enum CodingKeys: String, CodingKey {
        case enabled, suppressOriginalEvent, debounceMs, doubleClickMs, verified, verificationNote, mappings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        suppressOriginalEvent = try c.decodeIfPresent(Bool.self, forKey: .suppressOriginalEvent) ?? true
        debounceMs = try c.decodeIfPresent(Int.self, forKey: .debounceMs) ?? 300
        doubleClickMs = try c.decodeIfPresent(Int.self, forKey: .doubleClickMs) ?? 250
        verified = try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        verificationNote = try c.decodeIfPresent(String.self, forKey: .verificationNote)
        mappings = try c.decode([Mapping].self, forKey: .mappings)
    }
}

public enum ConfigError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case malformed(String)
    case invalid([String])

    public var description: String {
        switch self {
        case .unreadable(let m): return "Cannot read config: \(m)"
        case .malformed(let m): return "Config is not valid JSON for this schema: \(m)"
        case .invalid(let problems): return "Config is invalid:\n  - " + problems.joined(separator: "\n  - ")
        }
    }
}

public enum ConfigLoader {
    public static func decode(_ data: Data) throws -> ControllerConfig {
        let config: ControllerConfig
        do {
            config = try JSONDecoder().decode(ControllerConfig.self, from: data)
        } catch {
            throw ConfigError.malformed(String(describing: error))
        }
        let problems = validate(config)
        if !problems.isEmpty { throw ConfigError.invalid(problems) }
        return config
    }

    public static func load(path: String) throws -> ControllerConfig {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ConfigError.unreadable(path)
        }
        return try decode(data)
    }

    public static func encode(_ config: ControllerConfig) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(config)
    }

    /// Returns human-readable problems; empty = valid.
    public static func validate(_ config: ControllerConfig) -> [String] {
        var problems: [String] = []
        if !(0...5000).contains(config.debounceMs) {
            problems.append("debounceMs must be between 0 and 5000 (got \(config.debounceMs))")
        }
        if !(100...1000).contains(config.doubleClickMs) {
            problems.append("doubleClickMs must be between 100 and 1000 (got \(config.doubleClickMs))")
        }
        var seen = Set<String>()
        for (i, m) in config.mappings.enumerated() {
            let label = "mappings[\(i)] (\(m.name))"
            // Buttons 0 and 1 are primary/secondary click. Never allow remapping them:
            // a bad config must not be able to break normal clicking.
            if m.button < 2 {
                problems.append("\(label): button \(m.button) is the left/right click and cannot be remapped")
            }
            if m.button > 31 {
                problems.append("\(label): button \(m.button) is out of range (2...31)")
            }
            if !seen.insert("\(m.button)/\(m.gesture.rawValue)").inserted {
                problems.append("\(label): button \(m.button) (\(m.gesture.rawValue)) is mapped more than once")
            }
            if KeyTable.keyCode(for: m.action.key) == nil {
                problems.append("\(label): unknown key '\(m.action.key)'. Known: \(KeyTable.knownKeys.joined(separator: ", "))")
            }
            for mod in m.action.modifiers where KeyTable.modifierFlag(for: mod) == nil {
                problems.append("\(label): unknown modifier '\(mod)'. Known: \(KeyTable.knownModifiers.joined(separator: ", "))")
            }
        }
        return problems
    }
}
