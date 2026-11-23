import XCTest
@testable import ProductiumCore

/// v1.3 Part M: a v1.2.2 state.json (schema 4, the `history` scenario saved by the app on the phone) decodes, migrates
/// and re-encodes with nothing lost.
final class MigrationTests: XCTestCase {
    static func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "state-1.2.2", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .sortedKeys; return e }
    func object(_ d: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any]) }

    func testSchema7FoldsRetiredButtonsAndAddsSubjectStudy() throws {
        let s = try decoder().decode(AppState.self, from: try Self.fixture())
        XCTAssertNil(s.quickStarts.live.first { $0.key == "walking" && $0.origin == .template })
        XCTAssertTrue(s.quickStarts.button(for: "Commute")?.keys.contains("walking") ?? false)
        let subjects = s.categories.children(CategoryTree.school).map(\.name)
        for name in subjects { XCTAssertNotNil(s.quickStarts.button(for: "\(name) study"), name) }
        XCTAssertTrue(s.entries.allSatisfy { $0.focus == nil })
    }

    func testFixtureIsSchema4() throws {
        XCTAssertEqual(Migrations.storedSchema(try Self.fixture()), 4)
    }

    func testNothingIsLost() throws {
        let data = try Self.fixture()
        let old = try object(data)
        let s = try decoder().decode(AppState.self, from: data)
        XCTAssertEqual(s.schema, AppState.schema)
        XCTAssertTrue(s.onboarded)
        let new = try object(try encoder().encode(s))
        // Every field but the migrated ones comes back exactly as stored.
        for (k, v) in old where !["schema", "quickStarts", "prefs", "categories"].contains(k) {
            XCTAssertEqual(new[k] as? NSObject, v as? NSObject, "\(k) changed in the migration")
        }
        let oldPrefs = try XCTUnwrap(old["prefs"] as? [String: Any]), newPrefs = try XCTUnwrap(new["prefs"] as? [String: Any])
        for (k, v) in oldPrefs { XCTAssertEqual(newPrefs[k] as? NSObject, v as? NSObject, "prefs.\(k)") }
        // Every tile the student had is still there, unchanged; the templates are added around them.
        let oldButtons = try XCTUnwrap((old["quickStarts"] as? [String: Any])?["buttons"] as? [[String: Any]])
        let newButtons = try XCTUnwrap((new["quickStarts"] as? [String: Any])?["buttons"] as? [[String: Any]])
        for b in oldButtons {
            let m = try XCTUnwrap(newButtons.first { $0["id"] as? String == b["id"] as? String }, "\(b["title"] ?? "")")
            for (k, v) in b { XCTAssertEqual(m[k] as? NSObject, v as? NSObject, "button \(b["title"] ?? "").\(k)") }
        }
        XCTAssertEqual(s.quickStarts.buttons.filter { $0.origin == .you }.count, oldButtons.count)
        XCTAssertGreaterThan(s.quickStarts.live.count, oldButtons.count)
        XCTAssertEqual(Set(s.quickStarts.buttons.map(\.key)).count, s.quickStarts.buttons.count, "no duplicate tiles")
        // The counts the screens show.
        XCTAssertEqual(s.entries.count, (old["entries"] as? [Any])?.count)
        XCTAssertEqual(s.items.count, (old["items"] as? [Any])?.count)
        XCTAssertEqual(s.goals.count, (old["goals"] as? [Any])?.count)
        // Schema 6: every category is still there (ids, names, parents); gray seeds got colours; two seeds were added.
        let oldNodes = try XCTUnwrap((old["categories"] as? [String: Any])?["nodes"] as? [[String: Any]])
        for n in oldNodes {
            let m = try XCTUnwrap(s.categories.node(try XCTUnwrap(n["id"] as? String)))
            XCTAssertEqual(m.name, n["name"] as? String)
            XCTAssertEqual(m.parentId, n["parentId"] as? String)
            if n["colour"] as? String != "gray" { XCTAssertEqual(m.colour, n["colour"] as? String) }
        }
        XCTAssertEqual(s.categories.nodes.count, oldNodes.count + 2)
        XCTAssertNotNil(s.categories.node(CategoryTree.transition))
        XCTAssertNotNil(s.categories.node(CategoryTree.messaging))
        XCTAssertEqual(s.categories.node(CategoryTree.school)?.colour, "orange")
    }

    func testMigratedStateIsStable() throws {
        let once = try decoder().decode(AppState.self, from: try Self.fixture())
        let twice = try decoder().decode(AppState.self, from: try encoder().encode(once))
        XCTAssertEqual(try encoder().encode(once), try encoder().encode(twice), "a migrated state isn't migrated again")
    }

    func testAlarmAndNotificationTogglesBecomeSeverities() throws {
        var old = try object(try Self.fixture())
        var prefs = try XCTUnwrap(old["prefs"] as? [String: Any])
        var nudges = try XCTUnwrap(prefs["nudges"] as? [String: Any])
        nudges["alarms"] = true
        nudges["deadlines"] = false
        nudges["daylight"] = false
        nudges["level"] = "persistent"
        prefs["nudges"] = nudges
        prefs["wakeAlarms"] = false
        old["prefs"] = prefs
        let s = try decoder().decode(AppState.self, from: try JSONSerialization.data(withJSONObject: old))
        let p = s.prefs.prompts
        XCTAssertEqual(p[.wake], .notification)
        XCTAssertEqual(p[.bedtime], .alarm)
        XCTAssertEqual(p[.leave], .alarm)
        XCTAssertEqual(p[.missedStart], .alarm)
        XCTAssertEqual(p[.deadline], .off)
        XCTAssertEqual(p[.daylight], .off)
        XCTAssertEqual(p[.movement], .notification)
        XCTAssertEqual(p[.untracked], .liveActivity)
        XCTAssertEqual(s.prefs.nudges.level, .persistent, "the notification level is kept")
        // The default 1.2.2 settings: the wake alarm on, the others notifications.
        let d = try decoder().decode(AppState.self, from: try Self.fixture()).prefs.prompts
        XCTAssertEqual(d[.wake], .alarm)
        XCTAssertEqual(d[.bedtime], .notification)
    }

    func testA122BackupRestoresInto13() throws {
        let state = try XCTUnwrap(String(data: try Self.fixture(), encoding: .utf8))
        let bundle = #"{"format":"productium-export","version":4,"exportedAt":"2026-11-21T20:37:00Z","device":{"timeZone":"America/Toronto"},"#
            + #""aboutMe":"","callLog":{"calls":[]},"sharedDefaults":{},"appDefaults":{},"files":{},"pendingNotifications":[],"#
            + #""deliveredNotifications":[],"permissions":{},"serverSnapshots":{},"diagnostics":{},"state":"# + state + "}"
        let b = try ExportBundle.read(Data(bundle.utf8))
        XCTAssertEqual(b.state.schema, AppState.schema)
        let plain = try decoder().decode(AppState.self, from: try Self.fixture())
        XCTAssertEqual(b.state.entries.count, plain.entries.count)
        XCTAssertGreaterThan(b.state.entries.count, 100)
        XCTAssertTrue(b.state.quickStarts.live.contains { $0.origin == .template })
    }

    func testABackupWithDamagedExtrasStillRestores() throws {
        let state = try XCTUnwrap(String(data: try Self.fixture(), encoding: .utf8))
        let bundle = #"{"format":"productium-export","version":4,"callLog":{"calls":[{"feature":"gone"}]},"#
            + #""pendingNotifications":[{"id":1}],"files":[],"state":"# + state + "}"
        let b = try ExportBundle.read(Data(bundle.utf8))
        XCTAssertGreaterThan(b.state.entries.count, 100)
        XCTAssertTrue(b.callLog.calls.isEmpty)
        XCTAssertThrowsError(try ExportBundle.read(Data(#"{"format":"productium-export","version":4}"#.utf8))) {
            guard case ExportBundle.ReadError.unreadable = $0 else { return XCTFail("\($0)") }
        }
    }

    func testOlderThan122StartsFresh() throws {
        let s = try decoder().decode(AppState.self, from: Data(#"{"schema":3,"onboarded":true,"entries":[]}"#.utf8))
        XCTAssertFalse(s.onboarded)
    }
}
