import XCTest
@testable import MouseControllerCore

private let prev = Mapping(name: "Previous Desktop", button: 3, action: KeyAction(key: "leftArrow", modifiers: ["control"]))
private let next = Mapping(name: "Next Desktop", button: 4, action: KeyAction(key: "rightArrow", modifiers: ["control"]))

private func makeConfig(enabled: Bool = true, suppress: Bool = true, debounce: Int = 300,
                        mappings: [Mapping] = [prev, next]) -> ControllerConfig {
    ControllerConfig(enabled: enabled, suppressOriginalEvent: suppress, debounceMs: debounce,
                     verified: true, mappings: mappings)
}

final class EngineTests: XCTestCase {
    func testMappedButtonDownFires() {
        let e = Engine(config: makeConfig())
        XCTAssertEqual(e.handle(button: 3, phase: .down, now: 10), .fire(prev, suppressOriginal: true))
        XCTAssertEqual(e.handle(button: 3, phase: .up, now: 10.05), .suppress)
        XCTAssertEqual(e.handle(button: 4, phase: .down, now: 11), .fire(next, suppressOriginal: true))
    }

    func testLeftRightAndMiddleClicksPassThrough() {
        // Even a config that (wrongly) maps 0/1 must never touch normal clicks.
        var c = makeConfig()
        c.mappings.append(Mapping(name: "evil", button: 0, action: prev.action))
        let e = Engine(config: c)
        for b in [0, 1, 2] {
            XCTAssertEqual(e.handle(button: b, phase: .down, now: 1), .passThrough, "button \(b)")
            XCTAssertEqual(e.handle(button: b, phase: .up, now: 1.1), .passThrough, "button \(b)")
        }
    }

    func testUnmappedExtraButtonPassesThrough() {
        let e = Engine(config: makeConfig())
        XCTAssertEqual(e.handle(button: 5, phase: .down, now: 1), .passThrough)
    }

    func testDebounceBlocksRapidRepeat() {
        let e = Engine(config: makeConfig(debounce: 300))
        XCTAssertEqual(e.handle(button: 3, phase: .down, now: 1.000), .fire(prev, suppressOriginal: true))
        XCTAssertEqual(e.handle(button: 3, phase: .up, now: 1.050), .suppress)
        XCTAssertEqual(e.handle(button: 3, phase: .down, now: 1.200), .suppress, "within 300ms")
        XCTAssertEqual(e.handle(button: 3, phase: .up, now: 1.250), .suppress)
        XCTAssertEqual(e.handle(button: 3, phase: .down, now: 1.400), .fire(prev, suppressOriginal: true), "after 300ms")
    }

    func testDebounceIsPerButton() {
        let e = Engine(config: makeConfig(debounce: 300))
        XCTAssertEqual(e.handle(button: 3, phase: .down, now: 1.0), .fire(prev, suppressOriginal: true))
        XCTAssertEqual(e.handle(button: 4, phase: .down, now: 1.05), .fire(next, suppressOriginal: true))
    }

    func testDuplicateDownWithoutUpDoesNotRefire() {
        let e = Engine(config: makeConfig(debounce: 0))
        XCTAssertEqual(e.handle(button: 3, phase: .down, now: 1.0), .fire(prev, suppressOriginal: true))
        XCTAssertEqual(e.handle(button: 3, phase: .down, now: 1.5), .suppress)
    }

    func testStaleHoldRecovers() {
        // Lost "up" (tap disabled mid-press) must not lock the button forever.
        let e = Engine(config: makeConfig(debounce: 0))
        XCTAssertEqual(e.handle(button: 3, phase: .down, now: 1.0), .fire(prev, suppressOriginal: true))
        XCTAssertEqual(e.handle(button: 3, phase: .down, now: 1.0 + Engine.staleHoldSeconds + 0.1),
                       .fire(prev, suppressOriginal: true))
    }

    func testDraggedIsSuppressedForMappedButton() {
        let e = Engine(config: makeConfig())
        _ = e.handle(button: 3, phase: .down, now: 1)
        XCTAssertEqual(e.handle(button: 3, phase: .dragged, now: 1.1), .suppress)
    }

    func testDisabledPassesEverything() {
        let e = Engine(config: makeConfig(enabled: false))
        XCTAssertEqual(e.handle(button: 3, phase: .down, now: 1), .passThrough)
        XCTAssertEqual(e.handle(button: 3, phase: .up, now: 1.1), .passThrough)
    }

    func testNoSuppressModePassesOriginal() {
        let e = Engine(config: makeConfig(suppress: false))
        XCTAssertEqual(e.handle(button: 3, phase: .down, now: 1), .fire(prev, suppressOriginal: false))
        XCTAssertEqual(e.handle(button: 3, phase: .up, now: 1.1), .passThrough)
    }

    func testReloadAppliesNewMappingAndResetsState() {
        let e = Engine(config: makeConfig(debounce: 5000))
        XCTAssertEqual(e.handle(button: 3, phase: .down, now: 1), .fire(prev, suppressOriginal: true))
        let swapped = [Mapping(name: "Previous Desktop", button: 4, action: prev.action),
                       Mapping(name: "Next Desktop", button: 3, action: next.action)]
        e.reload(makeConfig(debounce: 5000, mappings: swapped))
        XCTAssertEqual(e.handle(button: 3, phase: .down, now: 1.1), .fire(swapped[1], suppressOriginal: true),
                       "debounce/held state cleared and new mapping used")
    }
}

final class ConfigTests: XCTestCase {
    func testValidConfigRoundTrips() throws {
        let c = makeConfig()
        let decoded = try ConfigLoader.decode(try ConfigLoader.encode(c))
        XCTAssertEqual(decoded, c)
    }

    func testDefaultsAppliedForMissingFields() throws {
        let json = #"{"mappings":[{"name":"P","button":3,"action":{"key":"leftArrow","modifiers":["control"]}}]}"#
        let c = try ConfigLoader.decode(Data(json.utf8))
        XCTAssertTrue(c.enabled)
        XCTAssertTrue(c.suppressOriginalEvent)
        XCTAssertEqual(c.debounceMs, 300)
        XCTAssertFalse(c.verified, "unverified unless calibrate says so")
    }

    func testRejectsLeftRightClickMapping() {
        let c = makeConfig(mappings: [Mapping(name: "x", button: 1, action: prev.action)])
        XCTAssertTrue(ConfigLoader.validate(c).contains { $0.contains("left/right click") })
    }

    func testRejectsDuplicateButtons() {
        let c = makeConfig(mappings: [prev, Mapping(name: "dup", button: 3, action: next.action)])
        XCTAssertTrue(ConfigLoader.validate(c).contains { $0.contains("more than once") })
    }

    func testRejectsUnknownKeyAndModifier() {
        let c = makeConfig(mappings: [Mapping(name: "x", button: 3, action: KeyAction(key: "nope", modifiers: ["hyper"]))])
        let p = ConfigLoader.validate(c)
        XCTAssertTrue(p.contains { $0.contains("unknown key") })
        XCTAssertTrue(p.contains { $0.contains("unknown modifier") })
    }

    func testRejectsBadDebounce() {
        XCTAssertFalse(ConfigLoader.validate(makeConfig(debounce: -1)).isEmpty)
        XCTAssertFalse(ConfigLoader.validate(makeConfig(debounce: 99999)).isEmpty)
    }

    func testMalformedJSONIsReported() {
        XCTAssertThrowsError(try ConfigLoader.decode(Data("{".utf8))) { err in
            guard case ConfigError.malformed = err else { return XCTFail("\(err)") }
        }
    }

    func testShippedExampleConfigIsValid() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../config/config.example.json").standardized
        let c = try ConfigLoader.load(path: url.path)
        XCTAssertFalse(c.verified, "the example must never claim hardware verification")
        XCTAssertEqual(c.mappings.count, 2)
    }
}

final class KeyTableTests: XCTestCase {
    func testControlLeftArrowFlags() {
        let f = KeyTable.flags(for: KeyAction(key: "leftArrow", modifiers: ["control"]))
        XCTAssertEqual(KeyTable.keyCode(for: "leftArrow"), 123)
        XCTAssertEqual(KeyTable.keyCode(for: "rightArrow"), 124)
        XCTAssertNotEqual(f & KeyTable.flagControl, 0)
        // Regression guard (ISSUE-002): Spaces ignores Ctrl+Arrow without Fn+NumericPad.
        XCTAssertNotEqual(f & KeyTable.flagSecondaryFn, 0)
        XCTAssertNotEqual(f & KeyTable.flagNumericPad, 0)
    }

    func testDigitKeyHasNoFnFlag() {
        let f = KeyTable.flags(for: KeyAction(key: "1", modifiers: ["control"]))
        XCTAssertEqual(f, KeyTable.flagControl)
    }
}
