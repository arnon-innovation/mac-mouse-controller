import Foundation

public enum ButtonPhase: Sendable {
    case down, up, dragged
}

public enum Decision: Equatable, Sendable {
    /// Not ours: deliver the event unchanged.
    case passThrough
    /// Ours, but no action now: swallow the event.
    case suppress
    /// Perform the mapping's action now. `suppressOriginal` says whether to swallow the source event.
    case fire(Mapping, suppressOriginal: Bool)
    /// Possible double-click: call `timerFired(token:)` after `after` seconds; if it returns a
    /// mapping, perform it then (the single action). A second press in time cancels it.
    case schedule(token: Int, after: TimeInterval, suppressOriginal: Bool)
}

/// Pure decision logic for mouse button events. Not thread-safe: call `handle` and
/// `timerFired` from one thread (the event-tap run loop).
public final class Engine {
    public private(set) var config: ControllerConfig
    private var singles: [Int: Mapping] = [:]
    private var doubles: [Int: Mapping] = [:]
    private var lastFire: [Int: TimeInterval] = [:]
    private var heldSince: [Int: TimeInterval] = [:]
    /// Button -> (token, time of first press) while waiting to see if a second press follows.
    private var pending: [Int: (token: Int, at: TimeInterval)] = [:]
    private var nextToken = 1

    /// A held button whose "up" we never saw (e.g. the tap was disabled mid-press)
    /// is considered released after this long, so it can never lock a mapping forever.
    public static let staleHoldSeconds: TimeInterval = 3.0

    public init(config: ControllerConfig) {
        self.config = config
        rebuildIndex()
    }

    /// Swap configuration at runtime (config reload). Clears press state and cancels pending timers.
    public func reload(_ newConfig: ControllerConfig) {
        config = newConfig
        lastFire.removeAll()
        heldSince.removeAll()
        pending.removeAll()
        rebuildIndex()
    }

    private func rebuildIndex() {
        singles = [:]; doubles = [:]
        for m in config.mappings {
            switch m.gesture {
            case .single: if singles[m.button] == nil { singles[m.button] = m }
            case .double: if doubles[m.button] == nil { doubles[m.button] = m }
            }
        }
    }

    public func handle(button: Int, phase: ButtonPhase, now: TimeInterval) -> Decision {
        // Hard safety rule independent of config validation: never touch left/right click.
        guard button >= 2, config.enabled, singles[button] != nil || doubles[button] != nil else {
            return .passThrough
        }
        let suppressOriginal = config.suppressOriginalEvent
        let swallow: Decision = suppressOriginal ? .suppress : .passThrough

        switch phase {
        case .up:
            heldSince[button] = nil
            return swallow
        case .dragged:
            return swallow
        case .down:
            if let since = heldSince[button], now - since < Engine.staleHoldSeconds {
                // Second "down" without an "up": hardware chatter / repeat. Don't re-fire.
                return swallow
            }
            heldSince[button] = now
        }

        // Button with a double-click mapping: wait-and-see.
        if let double = doubles[button] {
            let window = Double(config.doubleClickMs) / 1000
            if let last = lastFire[button], now - last <= window {
                // 3rd+ press of a fast burst right after a double-click: part of the same gesture.
                return swallow
            }
            if let p = pending[button], now - p.at <= window {
                pending[button] = nil          // cancels the scheduled single action
                lastFire[button] = now
                return .fire(double, suppressOriginal: suppressOriginal)
            }
            let token = nextToken
            nextToken += 1
            pending[button] = (token, now)
            return .schedule(token: token, after: window, suppressOriginal: suppressOriginal)
        }

        // Single-only button: fire immediately, with debounce.
        if let last = lastFire[button], (now - last) * 1000 < Double(config.debounceMs) {
            return swallow
        }
        lastFire[button] = now
        return .fire(singles[button]!, suppressOriginal: suppressOriginal)
    }

    /// Called when a `.schedule` delay elapses. Returns the single mapping to perform, or nil
    /// if a second press turned it into a double-click (or there is no single mapping / config reloaded).
    public func timerFired(token: Int) -> Mapping? {
        guard let (button, _) = pending.first(where: { $0.value.token == token }) else { return nil }
        pending[button] = nil
        return singles[button]
    }
}
