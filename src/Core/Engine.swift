import Foundation

public enum ButtonPhase: Sendable {
    case down, up, dragged
}

public enum Decision: Equatable, Sendable {
    /// Not ours: deliver the event unchanged.
    case passThrough
    /// Ours, but no action now: swallow the event.
    case suppress
    /// Perform the mapping's action. `suppressOriginal` says whether to swallow the source event.
    case fire(Mapping, suppressOriginal: Bool)
}

/// Pure decision logic for mouse button events. Not thread-safe: call from one thread
/// (the event-tap run loop).
public final class Engine {
    public private(set) var config: ControllerConfig
    private var byButton: [Int: Mapping] = [:]
    private var lastFire: [Int: TimeInterval] = [:]
    private var heldSince: [Int: TimeInterval] = [:]

    /// A held button whose "up" we never saw (e.g. the tap was disabled mid-press)
    /// is considered released after this long, so it can never lock a mapping forever.
    public static let staleHoldSeconds: TimeInterval = 3.0

    public init(config: ControllerConfig) {
        self.config = config
        rebuildIndex()
    }

    /// Swap configuration at runtime (config reload). Clears press state.
    public func reload(_ newConfig: ControllerConfig) {
        config = newConfig
        lastFire.removeAll()
        heldSince.removeAll()
        rebuildIndex()
    }

    private func rebuildIndex() {
        byButton = Dictionary(config.mappings.map { ($0.button, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// - Parameters:
    ///   - button: CGEvent mouseEventButtonNumber.
    ///   - phase: down / up / dragged.
    ///   - now: monotonic seconds.
    public func handle(button: Int, phase: ButtonPhase, now: TimeInterval) -> Decision {
        // Hard safety rule independent of config validation: never touch left/right click.
        guard button >= 2, config.enabled, let mapping = byButton[button] else {
            return .passThrough
        }
        let swallow: Decision = config.suppressOriginalEvent ? .suppress : .passThrough

        switch phase {
        case .down:
            if let since = heldSince[button], now - since < Engine.staleHoldSeconds {
                // Second "down" without an "up": hardware chatter / repeat. Don't re-fire.
                return swallow
            }
            heldSince[button] = now
            if let last = lastFire[button], (now - last) * 1000 < Double(config.debounceMs) {
                return swallow
            }
            lastFire[button] = now
            return .fire(mapping, suppressOriginal: config.suppressOriginalEvent)
        case .up:
            heldSince[button] = nil
            return swallow
        case .dragged:
            return swallow
        }
    }
}
