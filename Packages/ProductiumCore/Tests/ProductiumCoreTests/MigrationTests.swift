import XCTest
@testable import ProductiumCore

/// v1.6 H: `state-1.6.json` (the `history` scenario, schema 8) decodes on every later schema with nothing lost, and
/// anything from before 1.6 is refused.
final class MigrationTests: XCTestCase {
    static func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "state-1.6", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .sortedKeys; return e }
    func object(_ d: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any]) }

    /// `WRITE_FIXTURE=<path> swift test --filter MigrationTests/testWriteFixture` saves a new fixture (only at a schema bump).
    func testWriteFixture() throws {
        guard let path = ProcessInfo.processInfo.environment["WRITE_FIXTURE"] else { return }
        let s = Scenarios.make(.history, now: Fx.mon(16, 40, plusDays: 2), calendar: Fx.cal)
        try encoder().encode(s).write(to: URL(fileURLWithPath: path))
    }

    /// `READ_EXPORT=<path> swift test --filter MigrationTests/testReadsAnExport` checks a real export decodes and plans.
    func testReadsAnExport() throws {
        guard let path = ProcessInfo.processInfo.environment["READ_EXPORT"] else { return }
        let b = try ExportBundle.read(try Data(contentsOf: URL(fileURLWithPath: path)))
        let s = b.state
        print("READ_EXPORT", b.summary, "schema", s.schema, "open tasks", s.items.filter(\.isOpen).map(\.title))
        let again = try ExportBundle.decoder().decode(ExportBundle.self, from: try ExportBundle.encoder().encode(b))
        XCTAssertEqual(again.state.entries.count, s.entries.count)
        var input = PlannerInput(now: b.exportedAt, calendar: .current, items: s.items, preferences: s.prefs, learned: s.learned,
                                 health: s.health, moods: s.moods, routines: [], horizonDays: 14, entries: s.entries, rules: s.rules)
        input.categories = s.categories
        let plan = Planner.plan(input)
        print("READ_EXPORT plan", plan.blocks.filter(\.isStudy).count, "study blocks;", plan.warnings.map(\.message))
    }

    func testFixtureIsTheBaseline() throws {
        XCTAssertEqual(Migrations.storedSchema(try Self.fixture()), Migrations.oldest)
    }

    func testNothingIsLost() throws {
        let data = try Self.fixture()
        let old = try object(data)
        let s = try decoder().decode(AppState.self, from: data)
        XCTAssertEqual(s.schema, AppState.schema)
        XCTAssertTrue(s.onboarded)
        let new = try object(try encoder().encode(s))
        XCTAssertEqual(Set(new.keys), Set(old.keys).union(new.keys), "no stored field disappears")
        for (k, v) in old where k != "schema" {
            XCTAssertEqual(new[k] as? NSObject, v as? NSObject, "\(k) changed")
        }
        XCTAssertGreaterThan(s.entries.count, 100)
        XCTAssertFalse(s.items.isEmpty)
    }

    func testDecodedStateIsStable() throws {
        let once = try decoder().decode(AppState.self, from: try Self.fixture())
        let twice = try decoder().decode(AppState.self, from: try encoder().encode(once))
        XCTAssertEqual(try encoder().encode(once), try encoder().encode(twice))
    }

    func testBackupRestores() throws {
        let state = try XCTUnwrap(String(data: try Self.fixture(), encoding: .utf8))
        let bundle = #"{"format":"productium-export","version":5,"exportedAt":"2026-11-25T20:37:00Z","device":{"timeZone":"America/Toronto"},"#
            + #""aboutMe":"","callLog":{"calls":[]},"files":{},"state":"# + state + "}"
        let b = try ExportBundle.read(Data(bundle.utf8))
        XCTAssertEqual(b.state.schema, AppState.schema)
        XCTAssertGreaterThan(b.state.entries.count, 100)
    }

    func testABackupWithDamagedExtrasStillRestores() throws {
        let state = try XCTUnwrap(String(data: try Self.fixture(), encoding: .utf8))
        let bundle = #"{"format":"productium-export","version":5,"callLog":{"calls":[{"feature":"gone"}]},"#
            + #""pendingNotifications":[{"id":1}],"files":[],"state":"# + state + "}"
        let b = try ExportBundle.read(Data(bundle.utf8))
        XCTAssertGreaterThan(b.state.entries.count, 100)
        XCTAssertTrue(b.callLog.calls.isEmpty)
        XCTAssertThrowsError(try ExportBundle.read(Data(#"{"format":"productium-export","version":5}"#.utf8))) {
            guard case ExportBundle.ReadError.unreadable = $0 else { return XCTFail("\($0)") }
        }
    }

    func testBefore16IsRefused() throws {
        XCTAssertThrowsError(try decoder().decode(AppState.self, from: Data(#"{"schema":7,"onboarded":true,"entries":[]}"#.utf8))) {
            XCTAssertTrue($0 is BeforeBaseline, "\($0)")
        }
        let old = #"{"format":"productium-export","version":4,"state":{"schema":7}}"#
        XCTAssertThrowsError(try ExportBundle.read(Data(old.utf8))) {
            guard case ExportBundle.ReadError.oldFormat = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual("\($0)", "This backup is from before 1.6. Restore it with 1.5, or start fresh.")
        }
        let mixed = #"{"format":"productium-export","version":5,"state":{"schema":7}}"#
        XCTAssertThrowsError(try ExportBundle.read(Data(mixed.utf8))) {
            guard case ExportBundle.ReadError.oldFormat = $0 else { return XCTFail("\($0)") }
        }
    }
}
