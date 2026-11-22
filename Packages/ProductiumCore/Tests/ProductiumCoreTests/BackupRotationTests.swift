import XCTest
@testable import ProductiumCore

/// v1.3 H1: daily backup files outside the app, the newest 3 kept.
final class BackupRotationTests: XCTestCase {
    let cal = Fx.cal

    func testNamesAndDays() {
        XCTAssertEqual(BackupFiles.name(for: Fx.mon(23, 59), calendar: cal), "Productium-2026-11-16.json")
        XCTAssertEqual(BackupFiles.day(of: "Productium-2026-11-16.json"), "2026-11-16")
        XCTAssertNil(BackupFiles.day(of: "Productium-notes.json"))
        XCTAssertNil(BackupFiles.day(of: "Productium-2026-11-16.json.tmp"))
    }

    func testKeepsExactlyTheNewestThree() {
        var folder = ["notes.txt", "Productium-backup-old.json"]
        for d in 0..<7 { folder.append(BackupFiles.name(for: Fx.mon(9, plusDays: d), calendar: cal)) }
        folder.shuffle()
        let gone = BackupFiles.toDelete(folder)
        let left = folder.filter { !gone.contains($0) }
        XCTAssertEqual(BackupFiles.ours(left), ["Productium-2026-11-22.json", "Productium-2026-11-21.json", "Productium-2026-11-20.json"])
        XCTAssertTrue(left.contains("notes.txt") && left.contains("Productium-backup-old.json"), "other files are never touched")
        XCTAssertTrue(BackupFiles.toDelete(Array(BackupFiles.ours(left))).isEmpty)
        XCTAssertTrue(BackupFiles.toDelete(["Productium-2026-11-16.json"]).isEmpty)
    }

    func testOnceADay() {
        XCTAssertTrue(BackupFiles.isDue(last: nil, now: Fx.mon(9)))
        XCTAssertFalse(BackupFiles.isDue(last: Fx.mon(9), now: Fx.mon(20)))
        XCTAssertTrue(BackupFiles.isDue(last: Fx.mon(9), now: Fx.mon(9, plusDays: 1)))
        XCTAssertTrue(BackupFiles.isDue(last: Fx.mon(9, plusDays: 3), now: Fx.mon(9)), "a clock that went back")
    }

    func testFailureShowsUntilTheNextGoodWrite() {
        var b = BackupState(folderName: "Backups", lastWrite: Fx.mon(9))
        XCTAssertFalse(b.failing)
        b.lastError = "The folder isn't reachable"
        b.lastErrorAt = Fx.mon(9, plusDays: 1)
        XCTAssertTrue(b.failing)
        b.lastWrite = Fx.mon(9, plusDays: 2)
        XCTAssertFalse(b.failing)
    }

    func testRestoreOffer() {
        var s = AppState()
        s.entries = (0..<3).map { Entry(title: "e\($0)", start: Fx.mon(9), end: Fx.mon(10), category: CategoryTree.other, source: .you) }
        let b = ExportBundle(exportedAt: Fx.mon(9, plusDays: 4), device: .init(timeZone: "America/Vancouver"), state: s)
        XCTAssertEqual(BackupFiles.offer(b, now: Fx.mon(12, plusDays: 6), calendar: cal), "Restore from Friday's backup (3 entries)")
        XCTAssertEqual(BackupFiles.offer(b, now: Fx.mon(12, plusDays: 4), calendar: cal), "Restore from today's backup (3 entries)")
    }
}
